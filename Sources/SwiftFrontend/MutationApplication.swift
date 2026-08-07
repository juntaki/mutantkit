import Foundation
import MutationModel

public enum ApplicationError: Error, CustomStringConvertible {
    case anchorRejected(AnchorVerification)
    case unreadableFile(path: String, underlying: String)
    case unwritableFile(path: String, underlying: String)

    public var description: String {
        switch self {
        case let .anchorRejected(verification): verification.diagnosis
        case let .unreadableFile(path, underlying): "Could not read \(path): \(underlying)"
        case let .unwritableFile(path, underlying): "Could not write \(path): \(underlying)"
        }
    }

    /// A rejected anchor is a normal, expected outcome — the file moved on. It
    /// becomes `notApplied`, never `survived`.
    public var verification: AnchorVerification? {
        if case let .anchorRejected(verification) = self { return verification }
        return nil
    }
}

/// The result of applying one mutation, with the proof it happened.
public struct AppliedMutation: Sendable {
    public let point: MutationPoint
    public let mutatedSource: Data
    public let evidence: MutationEvidence

    public init(point: MutationPoint, mutatedSource: Data, evidence: MutationEvidence) {
        self.point = point
        self.mutatedSource = mutatedSource
        self.evidence = evidence
    }
}

/// Applies a mutation as a byte splice.
///
/// No `SyntaxRewriter`, no node lookup, no tree edit. The plan says "replace
/// bytes [a,b) with this text", and that is the entire operation — which is why
/// the applied result cannot drift from what the plan promised, and why the
/// resulting diff is always exactly one contiguous hunk.
public enum MutationApplication {
    /// Verifies the anchor, then splices. Throws rather than guessing.
    public static func apply(
        _ point: MutationPoint,
        to original: Data,
        depth: SourceAnchorVerifier.Depth = .full
    ) throws -> AppliedMutation {
        let verification = SourceAnchorVerifier.verify(point, against: original, depth: depth)
        guard verification.isValid else {
            throw ApplicationError.anchorRejected(verification)
        }

        var bytes = [UInt8](original)
        bytes.replaceSubrange(point.utf8Range.range, with: Array(point.replacementText.utf8))
        let mutated = Data(bytes)

        let beforeHash = ContentHash.of(original)
        let afterHash = ContentHash.of(mutated)

        let evidence = MutationEvidence(
            sourceBeforeHash: beforeHash,
            sourceAfterHash: afterHash,
            sourceDiff: SourceDiff.unified(
                before: original,
                after: mutated,
                changedRange: point.utf8Range,
                path: point.file
            )
        )

        return AppliedMutation(point: point, mutatedSource: mutated, evidence: evidence)
    }

    /// Reads, applies, and writes the file in place, returning the proof.
    ///
    /// `url` must already be inside a sandbox — nothing here checks that,
    /// because the workspace layer owns that guarantee.
    @discardableResult
    public static func applyInPlace(_ point: MutationPoint, fileAt url: URL) throws -> AppliedMutation {
        let original: Data
        do {
            original = try Data(contentsOf: url)
        } catch {
            throw ApplicationError.unreadableFile(path: url.path, underlying: error.localizedDescription)
        }

        let applied = try apply(point, to: original)

        do {
            try applied.mutatedSource.write(to: url, options: .atomic)
        } catch {
            throw ApplicationError.unwritableFile(path: url.path, underlying: error.localizedDescription)
        }

        return applied
    }
}
