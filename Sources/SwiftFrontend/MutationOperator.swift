import MutationModel
import SwiftSyntax

/// Everything an operator is given about one source file.
///
/// Read-only on purpose. Operators do not save files, do not build, do not run
/// tests, and cannot see the plan — they answer exactly one question ("what
/// could be mutated here?") and nothing else in the system depends on how they
/// answer it.
public struct MutationContext {
    /// Repository-relative, `/`-separated.
    public let relativePath: String
    public let sourceFile: SourceFileSyntax
    /// Raw UTF-8 of the file, exactly as read from disk.
    public let sourceBytes: [UInt8]
    public let sourceFileHash: String
    /// For line/column in human output only — never used as an anchor.
    public let locationConverter: SourceLocationConverter
    /// Called-function base names `swift.core.side-effect-call-removal`
    /// must never propose removing, from
    /// `OperatorSettings.sideEffectCallRemoval.excludeCalls`
    /// (`Configuration.operators`). Empty for every other operator and
    /// every call site that predates this field — a project-wide, generic
    /// context field rather than a per-operator parameter to `discover`,
    /// because `MutationRegistry.builtIn` constructs every operator as a
    /// parameterless value at static-init time, before any configuration
    /// exists to give it; this is the one seam where a resolved run's
    /// configuration can still reach an operator's `discover(in:)` without
    /// changing that registration model. No other operator reads it today.
    public let excludedCallNames: Set<String>

    public init(
        relativePath: String,
        sourceFile: SourceFileSyntax,
        sourceBytes: [UInt8],
        sourceFileHash: String,
        locationConverter: SourceLocationConverter,
        excludedCallNames: Set<String> = []
    ) {
        self.relativePath = relativePath
        self.sourceFile = sourceFile
        self.sourceBytes = sourceBytes
        self.sourceFileHash = sourceFileHash
        self.locationConverter = locationConverter
        self.excludedCallNames = excludedCallNames
    }
}

/// A proposed mutation, before it is given an identity.
///
/// Operators deliberately cannot set the Mutation ID, the fingerprints or the
/// byte range. Those are derived by `MutationDiscovery` from the node itself, so
/// that no operator can accidentally invent an unstable ID — the exact class of
/// bug this design is built to rule out.
public struct MutationCandidate {
    /// The node whose source text will be replaced. Its range is taken
    /// *excluding* trivia.
    public let node: Syntax
    public let replacementText: String
    /// Narrows the operator's declared confidence for this specific site.
    /// Never widens it — see `MutationDiscovery`.
    public let confidenceOverride: MutationConfidence?
    /// One line explaining why this site was chosen. Shown by `inspect`.
    public let note: String?

    public init(
        node: some SyntaxProtocol,
        replacementText: String,
        confidenceOverride: MutationConfidence? = nil,
        note: String? = nil
    ) {
        self.node = Syntax(node)
        self.replacementText = replacementText
        self.confidenceOverride = confidenceOverride
        self.note = note
    }
}

/// A mutation operator: a pure function from syntax to candidate mutations.
public protocol MutationOperator: Sendable {
    static var descriptor: OperatorDescriptor { get }

    func discover(in context: MutationContext) throws -> [MutationCandidate]
}

public extension MutationOperator {
    var descriptor: OperatorDescriptor { Self.descriptor }
}

/// Convenience base for operators implemented as a `SyntaxVisitor`.
open class MutationCandidateVisitor: SyntaxVisitor {
    public private(set) var candidates: [MutationCandidate] = []

    public func record(_ candidate: MutationCandidate) {
        candidates.append(candidate)
    }

    public func collect(from context: MutationContext) -> [MutationCandidate] {
        candidates.removeAll()
        walk(context.sourceFile)
        return candidates
    }
}
