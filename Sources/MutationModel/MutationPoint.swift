
/// One mutation, fully described, independent of any syntax tree.
///
/// A `MutationPoint` is self-contained on purpose: given the plan file and the
/// original sources, the tool can verify the anchor, apply the edit, and explain
/// itself — with no AST alive and no memory of the discovery pass. That is what
/// lets discovery drop every tree it parses (bounded memory on large trees)
/// without the "reported but never applied" phantom mutants that node-identity
/// mapping produced.
public struct MutationPoint: Codable, Sendable, Hashable, Identifiable {
    // MARK: Identity

    public let id: MutationID
    /// Repository-relative, `/`-separated. Never absolute — plans move between machines.
    public let file: String
    public let enclosingDeclaration: DeclarationIdentity
    public let operatorID: String
    public let operatorVersion: Int
    /// Index among same-operator, same-original-text candidates in this declaration.
    public let occurrenceIndex: Int

    // MARK: The edit

    public let utf8Range: ByteRange
    public let originalText: String
    public let replacementText: String

    // MARK: Anchors

    /// Fingerprints of the tokens immediately before/after the edit. These let a
    /// changed file produce a precise `notApplied` diagnosis instead of a silent
    /// misapply at a shifted offset.
    public let prefixTokenFingerprint: String
    public let suffixTokenFingerprint: String
    /// Hash of the whole file as it was at discovery time.
    public let sourceFileHash: String
    /// Syntax kind the operator expects at `utf8Range`, re-checked before applying.
    public let expectedSyntaxKind: String

    // MARK: Classification

    public let confidence: MutationConfidence
    public let executionMode: ExecutionMode

    // MARK: Display

    /// 1-based, for human output only. Never an anchor: line numbers shift.
    public let line: Int
    public let column: Int

    public init(
        id: MutationID,
        file: String,
        enclosingDeclaration: DeclarationIdentity,
        operatorID: String,
        operatorVersion: Int,
        occurrenceIndex: Int,
        utf8Range: ByteRange,
        originalText: String,
        replacementText: String,
        prefixTokenFingerprint: String,
        suffixTokenFingerprint: String,
        sourceFileHash: String,
        expectedSyntaxKind: String,
        confidence: MutationConfidence,
        executionMode: ExecutionMode,
        line: Int,
        column: Int
    ) {
        self.id = id
        self.file = file
        self.enclosingDeclaration = enclosingDeclaration
        self.operatorID = operatorID
        self.operatorVersion = operatorVersion
        self.occurrenceIndex = occurrenceIndex
        self.utf8Range = utf8Range
        self.originalText = originalText
        self.replacementText = replacementText
        self.prefixTokenFingerprint = prefixTokenFingerprint
        self.suffixTokenFingerprint = suffixTokenFingerprint
        self.sourceFileHash = sourceFileHash
        self.expectedSyntaxKind = expectedSyntaxKind
        self.confidence = confidence
        self.executionMode = executionMode
        self.line = line
        self.column = column
    }

    /// Recomputes the ID from this point's own components.
    ///
    /// `verify` compares this against `id`; a mismatch means the plan was
    /// hand-edited or written by an incompatible version, and the run must stop
    /// rather than report a score against IDs that do not reproduce.
    public var recomputedID: MutationID {
        MutationID.compute(
            filePath: file,
            declaration: enclosingDeclaration,
            operatorID: operatorID,
            operatorVersion: operatorVersion,
            originalTokenFingerprint: ContentHash.shortDigest(of: originalText),
            occurrenceIndex: occurrenceIndex
        )
    }

    public var displayLocation: String { "\(file):\(line):\(column)" }
}
