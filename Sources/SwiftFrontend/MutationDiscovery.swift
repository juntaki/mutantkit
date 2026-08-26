import Foundation
import MutationModel
import SwiftParser
import SwiftSyntax

public enum DiscoveryError: Error, CustomStringConvertible {
    case unreadableFile(path: String, underlying: String)

    public var description: String {
        switch self {
        case let .unreadableFile(path, underlying):
            "Could not read \(path): \(underlying)"
        }
    }
}

/// Turns operator candidates into fully-anchored `MutationPoint`s.
///
/// This is the boundary where the syntax tree stops mattering. Everything a
/// mutation needs — byte range, original text, fingerprints, declaration, hash —
/// is copied out into plain values here, and the tree is released when this
/// function returns. That is what lets a 2,000-file project be planned without
/// holding 2,000 ASTs, *and* what makes re-parsing at apply time harmless:
/// nothing downstream ever refers to a node again.
public struct MutationDiscovery {
    private let operators: [any MutationOperator]
    private let excludedCallNames: Set<String>

    public init(operators: [any MutationOperator], excludedCallNames: Set<String> = []) {
        self.operators = operators
        self.excludedCallNames = excludedCallNames
    }

    /// Discovers every mutation in one file. The tree does not outlive the call.
    public func discover(fileAt url: URL, relativePath: String) throws -> [MutationPoint] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DiscoveryError.unreadableFile(path: relativePath, underlying: error.localizedDescription)
        }
        return try discover(source: data, relativePath: relativePath)
    }

    /// Testable entry point that takes bytes directly.
    public func discover(source data: Data, relativePath: String) throws -> [MutationPoint] {
        let bytes = [UInt8](data)
        let sourceFileHash = ContentHash.of(data)
        let sourceText = String(decoding: bytes, as: UTF8.self)

        let sourceFile = Parser.parse(source: sourceText)
        let converter = SourceLocationConverter(fileName: relativePath, tree: sourceFile)

        let context = MutationContext(
            relativePath: relativePath,
            sourceFile: sourceFile,
            sourceBytes: bytes,
            sourceFileHash: sourceFileHash,
            locationConverter: converter,
            excludedCallNames: excludedCallNames
        )

        var drafts: [Draft] = []
        for mutationOperator in operators {
            let descriptor = type(of: mutationOperator).descriptor
            for candidate in try mutationOperator.discover(in: context) {
                if let draft = draft(from: candidate, descriptor: descriptor, context: context) {
                    drafts.append(draft)
                }
            }
        }

        return finalize(drafts, context: context)
    }

    // MARK: - Draft

    /// A candidate with its derived facts, still missing an occurrence index
    /// (which needs the whole file's drafts to compute).
    private struct Draft {
        let descriptor: OperatorDescriptor
        let declaration: DeclarationIdentity
        let range: ByteRange
        let originalText: String
        let replacementText: String
        let prefixFingerprint: String
        let suffixFingerprint: String
        let syntaxKind: String
        let confidence: MutationConfidence
        let line: Int
        let column: Int
    }

    private func draft(
        from candidate: MutationCandidate,
        descriptor: OperatorDescriptor,
        context: MutationContext
    ) -> Draft? {
        let node = candidate.node

        // Trivia is excluded: the anchor must cover the tokens the operator
        // matched, not the whitespace and comments that happen to precede them.
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = node.endPositionBeforeTrailingTrivia.utf8Offset

        guard start < end, end <= context.sourceBytes.count else { return nil }

        let originalText = String(decoding: context.sourceBytes[start ..< end], as: UTF8.self)

        // A replacement identical to the original would compile to the same
        // binary and be reported as a mutant that never mutated anything. That
        // is a phantom by definition, so it never enters the plan.
        guard originalText != candidate.replacementText else { return nil }

        let location = context.locationConverter.location(for: node.positionAfterSkippingLeadingTrivia)

        // An override may only lower confidence. An operator that could promote
        // its own sites past the profile gate would make `--profile conservative`
        // meaningless.
        let confidence = candidate.confidenceOverride.map { min($0, descriptor.confidence) }
            ?? descriptor.confidence

        return Draft(
            descriptor: descriptor,
            declaration: DeclarationIdentityResolver.identity(for: node),
            range: ByteRange(start: start, end: end),
            originalText: originalText,
            replacementText: candidate.replacementText,
            prefixFingerprint: TokenFingerprint.prefix(of: node),
            suffixFingerprint: TokenFingerprint.suffix(of: node),
            syntaxKind: String(describing: node.kind),
            confidence: confidence,
            line: location.line,
            column: location.column
        )
    }

    // MARK: - Identity assignment

    /// Assigns occurrence indices and builds the final points.
    ///
    /// The index is scoped to (operator, declaration, original text) and ordered
    /// by byte offset. Scoping it that narrowly is what keeps IDs stable: adding
    /// a line to an unrelated function cannot renumber this function's mutants,
    /// which a file-wide counter would.
    private func finalize(_ drafts: [Draft], context: MutationContext) -> [MutationPoint] {
        var counters: [String: Int] = [:]

        // The sort must be total. One operator may legitimately propose several
        // mutations at one site (`<` becomes both `<=` and `>=`), and those
        // share offset, operator and original text — so replacement text is the
        // final tiebreak. Without it the occurrence indices, and therefore the
        // IDs, would depend on candidate emission order.
        let ordered = drafts.sorted { lhs, rhs in
            if lhs.range.start != rhs.range.start { return lhs.range.start < rhs.range.start }
            if lhs.descriptor.id != rhs.descriptor.id { return lhs.descriptor.id < rhs.descriptor.id }
            return lhs.replacementText < rhs.replacementText
        }

        return ordered.map { draft in
            let key = [
                draft.descriptor.id,
                draft.declaration.description,
                draft.originalText
            ].joined(separator: "\u{1F}")

            let occurrenceIndex = counters[key, default: 0]
            counters[key] = occurrenceIndex + 1

            let id = MutationID.compute(
                filePath: context.relativePath,
                declaration: draft.declaration,
                operatorID: draft.descriptor.id,
                operatorVersion: draft.descriptor.version,
                originalTokenFingerprint: TokenFingerprint.ofOriginalText(draft.originalText),
                occurrenceIndex: occurrenceIndex
            )

            return MutationPoint(
                id: id,
                file: context.relativePath,
                enclosingDeclaration: draft.declaration,
                operatorID: draft.descriptor.id,
                operatorVersion: draft.descriptor.version,
                occurrenceIndex: occurrenceIndex,
                utf8Range: draft.range,
                originalText: draft.originalText,
                replacementText: draft.replacementText,
                prefixTokenFingerprint: draft.prefixFingerprint,
                suffixTokenFingerprint: draft.suffixFingerprint,
                sourceFileHash: context.sourceFileHash,
                expectedSyntaxKind: draft.syntaxKind,
                confidence: draft.confidence,
                executionMode: .isolated,
                line: draft.line,
                column: draft.column
            )
        }
    }
}
