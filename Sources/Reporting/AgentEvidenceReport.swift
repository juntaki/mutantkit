import MutationModel

/// A single mutant's full record, curated for a coding agent to consume
/// directly — `mutantkit inspect <id> --json`'s output shape.
///
/// This report deliberately favors richer primary evidence over
/// `kill_hint`-style inference. Every field here is read straight off data
/// this tool already
/// computed and verified elsewhere (`MutationPoint`, `MutationResult`,
/// `MutationEvidence`) — nothing is reconstructed or guessed from a raw
/// command line or a heuristic. Where the real data does not exist yet (a
/// mutant with no result, an unproven activation, a source file that has
/// since changed), the corresponding field is `nil`, never a fabricated or
/// best-effort value — the same fail-closed convention this tool already
/// applies everywhere else (see `JSONReporter`'s own doc comment: "no fail-
/// closed special case is needed... a consumer that wants a number must
/// handle its absence").
public struct AgentEvidenceReport: Codable, Sendable {
    public struct SourceInfo: Codable, Sendable {
        public let file: String
        public let line: Int
        public let column: Int
        public let original: String
        public let replacement: String
        /// A few lines of source around the mutation, or `nil` — never a
        /// stale/best-effort read. Only populated when the file currently
        /// on disk still hashes to `sourceFileHash` below; a file that has
        /// since changed makes any line-numbered excerpt a claim about code
        /// that no longer exists, so this omits the field entirely rather
        /// than risk showing an agent the wrong lines with high confidence.
        public let context: [String]?
        public let sourceFileHash: String

        public init(
            file: String, line: Int, column: Int, original: String, replacement: String, context: [String]?, sourceFileHash: String
        ) {
            self.file = file
            self.line = line
            self.column = column
            self.original = original
            self.replacement = replacement
            self.context = context
            self.sourceFileHash = sourceFileHash
        }
    }

    public struct OperatorInfo: Codable, Sendable {
        public let id: String
        public let version: Int
        public let category: String
        public let summary: String
        public let confidence: String

        public init(id: String, version: Int, category: String, summary: String, confidence: String) {
            self.id = id
            self.version = version
            self.category = category
            self.summary = summary
            self.confidence = confidence
        }
    }

    public struct TestsInfo: Codable, Sendable {
        public let total: Int
        public let passed: Int
        public let failed: Int
        /// Identifiers of the tests that actually caught this mutant — real
        /// evidence, not an inferred "kill hint". Empty, not absent, when
        /// the mutant survived or the adapter reported no per-test
        /// breakdown (see `TestOutcomeSummary.failingTests`'s own doc
        /// comment).
        public let caughtBy: [String]

        public init(total: Int, passed: Int, failed: Int, caughtBy: [String]) {
            self.total = total
            self.passed = passed
            self.failed = failed
            self.caughtBy = caughtBy
        }
    }

    public struct ExecutionInfo: Codable, Sendable {
        public let mode: String
        /// The exact, real command MutantKit ran — `[executable] +
        /// arguments`, verbatim, never a reconstructed or summarized
        /// "selected tests" list. A command line already names every test
        /// filter/argument it was actually invoked with; re-deriving a
        /// separate "selectedTests" array from it would be exactly the
        /// kind of inference this report is designed to avoid.
        public let buildCommand: [String]?
        public let testCommand: [String]?
        /// From this run's own `ToolchainFingerprint`
        /// (`buildSDKIdentity`/`destinationRuntimeIdentity`) — `nil` when no report
        /// has been loaded yet, or the run predates those fields.
        public let buildSDKIdentity: String?
        public let destinationRuntimeIdentity: String?

        public init(
            mode: String, buildCommand: [String]?, testCommand: [String]?, buildSDKIdentity: String?, destinationRuntimeIdentity: String?
        ) {
            self.mode = mode
            self.buildCommand = buildCommand
            self.testCommand = testCommand
            self.buildSDKIdentity = buildSDKIdentity
            self.destinationRuntimeIdentity = destinationRuntimeIdentity
        }
    }

    public struct EvidenceInfo: Codable, Sendable {
        /// `"isolated"`, `"schemata"`, or `"none"` (evidence exists —
        /// this mutant reached `.executed`/`.noCoverage` — but carries no
        /// application-evidence variant, e.g. a build failure).
        public let kind: String
        /// Whether the mutation was proven to actually reach the build
        /// product under test — `nil` when there is no application
        /// evidence to judge at all (`kind == "none"`). This is the same
        /// activation proof `MutationVerdictVerifier.classifyPassing`
        /// itself requires before ever reporting `.survived`/`.killed*` —
        /// see that function's own doc comment.
        public let activationProven: Bool?
        public let sourceBeforeHash: String
        public let sourceAfterHash: String
        public let buildProductHash: String?
        public let diff: String

        public init(
            kind: String, activationProven: Bool?, sourceBeforeHash: String, sourceAfterHash: String,
            buildProductHash: String?, diff: String
        ) {
            self.kind = kind
            self.activationProven = activationProven
            self.sourceBeforeHash = sourceBeforeHash
            self.sourceAfterHash = sourceAfterHash
            self.buildProductHash = buildProductHash
            self.diff = diff
        }
    }

    /// A static, always-true piece of advice, not a per-mutant inference —
    /// included as a structured hint rather than prose specifically so an
    /// agent does not have to parse English to find it. MutantKit's own
    /// operator catalog already documents this
    /// principle (`OperatorDescriptor.faultEvidence`'s framing throughout):
    /// a suite that only asserts the mutated line's own literal behavior,
    /// rather than an observable effect a caller can see, will not
    /// distinguish a real regression from a semantically-equivalent
    /// rewrite.
    public struct GuidanceInfo: Codable, Sendable {
        public let testBehaviorNotMutation: Bool

        public init() {
            testBehaviorNotMutation = true
        }
    }

    /// Set internally to `SchemaVersion.agentEvidenceReport`, never a caller-
    /// supplied parameter — the same discipline `MutationPlan`/`RunReport`
    /// already follow for their own `schemaVersion`, so nothing that builds
    /// this report can accidentally stamp it with the wrong version.
    public let schemaVersion: Int
    public let mutantId: String
    public let mutantOperator: OperatorInfo
    public let source: SourceInfo
    /// `nil` when no report has been loaded (a plan-only `inspect`) or this
    /// mutant was skipped at planning time — see `verdictUnavailableReason`.
    public let verdict: String?
    public let verdictUnavailableReason: String?
    public let diagnosis: String?
    /// `MutationResult.origin.rawValue` — `"fresh"`, `"checkpoint"`, or
    /// `"crossRunCache"` — so an agent can tell a freshly-executed verdict
    /// from one reused via the cross-run cache without re-deriving it.
    public let origin: String?
    public let durationSeconds: Double?
    public let tests: TestsInfo?
    public let execution: ExecutionInfo?
    public let evidence: EvidenceInfo?
    public let reproduceCommand: String
    public let guidance: GuidanceInfo

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mutantId
        case mutantOperator = "operator"
        case source, verdict, verdictUnavailableReason, diagnosis, origin, durationSeconds, tests, execution, evidence
        case reproduceCommand = "reproduce"
        case guidance
    }

    public init(
        mutantId: String, mutantOperator: OperatorInfo, source: SourceInfo, verdict: String?, verdictUnavailableReason: String?,
        diagnosis: String?, origin: String?, durationSeconds: Double?, tests: TestsInfo?, execution: ExecutionInfo?,
        evidence: EvidenceInfo?, reproduceCommand: String, guidance: GuidanceInfo
    ) {
        schemaVersion = SchemaVersion.agentEvidenceReport
        self.mutantId = mutantId
        self.mutantOperator = mutantOperator
        self.source = source
        self.verdict = verdict
        self.verdictUnavailableReason = verdictUnavailableReason
        self.diagnosis = diagnosis
        self.origin = origin
        self.durationSeconds = durationSeconds
        self.tests = tests
        self.execution = execution
        self.evidence = evidence
        self.reproduceCommand = reproduceCommand
        self.guidance = guidance
    }
}
