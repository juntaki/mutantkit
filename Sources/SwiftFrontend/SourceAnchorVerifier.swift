import Foundation
import MutationModel
import SwiftParser
import SwiftSyntax

/// Why an anchor did not match. Each case names something a human can act on.
public enum AnchorFailure: Equatable, Sendable, CustomStringConvertible {
    case fileHashMismatch(expected: String, actual: String)
    case rangeOutOfBounds(range: ByteRange, fileLength: Int)
    case originalTextMismatch(expected: String, found: String)
    case noNodeAtRange(range: ByteRange)
    case syntaxKindMismatch(expected: String, found: [String])
    case prefixFingerprintMismatch(expected: String, actual: String)
    case suffixFingerprintMismatch(expected: String, actual: String)
    case declarationMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case let .fileHashMismatch(expected, actual):
            "the file changed since planning (expected \(expected), found \(actual))"
        case let .rangeOutOfBounds(range, fileLength):
            "byte range \(range) lies outside the \(fileLength)-byte file"
        case let .originalTextMismatch(expected, found):
            "expected \(String(reflecting: expected)) at the anchor but found \(String(reflecting: found))"
        case let .noNodeAtRange(range):
            "no syntax node spans exactly \(range) any more"
        case let .syntaxKindMismatch(expected, found):
            "expected a \(expected) at the anchor, found \(found.joined(separator: ", "))"
        case let .prefixFingerprintMismatch(expected, actual):
            "the code before the anchor changed (expected \(expected), found \(actual))"
        case let .suffixFingerprintMismatch(expected, actual):
            "the code after the anchor changed (expected \(expected), found \(actual))"
        case let .declarationMismatch(expected, actual):
            "the anchor now sits in \(actual), not \(expected)"
        }
    }
}

public struct AnchorVerification: Sendable {
    public let failures: [AnchorFailure]
    public var isValid: Bool { failures.isEmpty }

    /// One sentence, suitable for a `notApplied` result's diagnosis.
    public var diagnosis: String {
        failures.isEmpty
            ? "anchor verified"
            : "Anchor rejected: " + failures.map(\.description).joined(separator: "; ") + "."
    }
}

/// Re-checks every anchor on a `MutationPoint` against the file on disk.
///
/// This runs before every single application. It is the mechanism behind the
/// design's rule that a mismatch becomes `notApplied` and is *never* relocated
/// by guesswork to a nearby offset — guessing is precisely how a tool ends up
/// generating invalid Swift or mutating the wrong expression.
///
/// Re-parsing here is safe in a way that Muter's re-parse was not: nothing is
/// matched by node identity. The tree is used only to re-derive content-based
/// facts, so a fresh parse of identical bytes necessarily agrees with discovery.
public enum SourceAnchorVerifier {
    public enum Depth {
        /// Hash and exact original text. Sufficient on its own — an identical
        /// file hash means the tokens are identical too.
        case content
        /// Additionally re-parses and re-checks kind, fingerprints and
        /// declaration. Used by `verify` and by anything that wants the anchor
        /// checked independently of the hash.
        case full
    }

    public static func verify(
        _ point: MutationPoint,
        against data: Data,
        depth: Depth = .full
    ) -> AnchorVerification {
        var failures: [AnchorFailure] = []
        let bytes = [UInt8](data)

        let actualHash = ContentHash.of(data)
        if actualHash != point.sourceFileHash {
            failures.append(.fileHashMismatch(expected: point.sourceFileHash, actual: actualHash))
        }

        let range = point.utf8Range
        guard range.end <= bytes.count else {
            failures.append(.rangeOutOfBounds(range: range, fileLength: bytes.count))
            return AnchorVerification(failures: failures)
        }

        let found = String(decoding: bytes[range.range], as: UTF8.self)
        if found != point.originalText {
            failures.append(.originalTextMismatch(expected: point.originalText, found: found))
        }

        guard depth == .full else { return AnchorVerification(failures: failures) }

        // A file that no longer parses cannot be anchored into; the content
        // failures above already explain why. Folded (see `SyntaxFolding`)
        // so a mutation discovered against a folded tree (a ternary, say)
        // re-verifies against the same tree shape discovery saw, not the
        // raw, unfolded one a plain re-parse would produce.
        let sourceFile = Parser.parse(source: String(decoding: bytes, as: UTF8.self))
        let matches = nodes(in: SyntaxFolding.fold(sourceFile), exactlySpanning: range)

        guard !matches.isEmpty else {
            failures.append(.noNodeAtRange(range: range))
            return AnchorVerification(failures: failures)
        }

        // Several nodes legitimately share one range — a boolean literal
        // expression and the `true` token inside it span the same bytes. The
        // anchor holds if any of them is the kind the operator matched.
        let kinds = matches.map { String(describing: $0.kind) }
        guard let node = matches.first(where: { String(describing: $0.kind) == point.expectedSyntaxKind }) else {
            failures.append(.syntaxKindMismatch(expected: point.expectedSyntaxKind, found: kinds))
            return AnchorVerification(failures: failures)
        }

        let prefix = TokenFingerprint.prefix(of: node)
        if prefix != point.prefixTokenFingerprint {
            failures.append(.prefixFingerprintMismatch(expected: point.prefixTokenFingerprint, actual: prefix))
        }

        let suffix = TokenFingerprint.suffix(of: node)
        if suffix != point.suffixTokenFingerprint {
            failures.append(.suffixFingerprintMismatch(expected: point.suffixTokenFingerprint, actual: suffix))
        }

        let declaration = DeclarationIdentityResolver.identity(for: node)
        if declaration != point.enclosingDeclaration {
            failures.append(.declarationMismatch(
                expected: point.enclosingDeclaration.description,
                actual: declaration.description
            ))
        }

        return AnchorVerification(failures: failures)
    }

    /// Re-parses `data` and returns the syntax node `point.utf8Range` and
    /// `point.expectedSyntaxKind` resolve to — `nil` if the anchor does not
    /// hold. For callers that need the tree itself (schemata eligibility
    /// analysis, say, checking for an enclosing result-builder body), not
    /// just `verify`'s pass/fail verdict. Never contradicts `verify`: it
    /// re-derives the identical match from the identical rule (trivia-
    /// excluded range plus expected kind), so a caller that first confirms
    /// `verify(...).isValid` and then calls this can trust the node it gets
    /// back is the one `verify` itself agreed on.
    public static func matchedNode(for point: MutationPoint, in data: Data) -> Syntax? {
        let bytes = [UInt8](data)
        guard point.utf8Range.end <= bytes.count else { return nil }
        let sourceFile = Parser.parse(source: String(decoding: bytes, as: UTF8.self))
        let matches = nodes(in: SyntaxFolding.fold(sourceFile), exactlySpanning: point.utf8Range)
        return matches.first { String(describing: $0.kind) == point.expectedSyntaxKind }
    }

    /// All nodes whose trivia-excluded range is exactly `range`.
    private static func nodes(in tree: Syntax, exactlySpanning range: ByteRange) -> [Syntax] {
        var matches: [Syntax] = []

        func descend(_ node: Syntax) {
            // Prune on the trivia-inclusive span: a node that does not contain
            // the range cannot have a descendant that does.
            guard node.position.utf8Offset <= range.start,
                  range.end <= node.endPosition.utf8Offset
            else { return }

            if node.positionAfterSkippingLeadingTrivia.utf8Offset == range.start,
               node.endPositionBeforeTrailingTrivia.utf8Offset == range.end {
                matches.append(node)
            }

            for child in node.children(viewMode: .sourceAccurate) {
                descend(child)
            }
        }

        descend(tree)
        return matches
    }
}
