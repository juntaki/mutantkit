/// Proof that a mutation actually reached the running code.
///
/// In isolated mode the mutation is compiled into the binary, so a mutant build
/// product that is byte-identical to the baseline's means the edit did not
/// affect what ran — the mutant is a phantom no matter what the source diff
/// says. That check is the difference between "we edited a file" and "we tested
/// a mutation".
public enum ActivationEvidence: Codable, Sendable, Hashable {
    /// The mutant's build product differs from the baseline's. The edit is in
    /// the binary under test.
    case buildProductDiffersFromBaseline(mutantHash: String, baselineHash: String)
    /// The product is identical to baseline. Not proof of activation — proof of
    /// its absence. Either the operator produced a no-op or the code was
    /// optimized away.
    case buildProductIdenticalToBaseline(hash: String)

    /// Never `true` on a self-contradictory value: `.buildProductDiffersFromBaseline`
    /// only proves anything when its two hashes are both present and
    /// actually differ. Nothing in isolated mode's construction path can
    /// produce an empty or matching pair under this case — the runner only
    /// ever builds it from two real, distinct content hashes — but
    /// `ActivationEvidence` is decoded as untrusted input by the
    /// cache/checkpoint reverify path, where a hand-edited entry could claim
    /// "differs from baseline" while supplying hashes that don't actually
    /// differ (or are empty). Trusting the case tag alone there would let a
    /// forged pair read as proven activation.
    public var provesActivation: Bool {
        switch self {
        case let .buildProductDiffersFromBaseline(mutantHash, baselineHash):
            !mutantHash.isEmpty && !baselineHash.isEmpty && mutantHash != baselineHash
        case .buildProductIdenticalToBaseline:
            false
        }
    }
}

/// What a `killedByCrash` verdict's confirmation rebuild found.
///
/// Present only when `Configuration.execution.confirmCrashKills` is on and
/// the mutant's first run crashed — see
/// `Configuration.execution.confirmCrashKills`'s doc comment for why a crash
/// gets a fresh, independent rebuild rather than the same-artifact retest
/// `retestKilledMutants` uses for assertion kills. A `killedByCrash` verdict
/// in a finished report always has `crashedAgain: true` here; a
/// confirmation that did not reproduce reclassifies the result to `.flaky`
/// before it is ever reported, so this is exactly the evidence `mutantkit
/// inspect` needs to answer "was this crash actually confirmed, or did
/// nobody check twice."
public struct CrashConfirmation: Codable, Sendable, Hashable {
    /// The confirmation's own build, in a sandbox independent of the one the
    /// original crash was observed in — its `workingDirectory` names that
    /// sandbox, so "was this the same sandbox as the first attempt" is
    /// answerable by comparing this against `MutationEvidence.buildCommand`.
    public let confirmingBuildCommand: CommandRecord?
    /// The confirmation's own test invocation — its `arguments` carry the
    /// simulator destination (by UDID) the confirmation ran against, again
    /// comparable against the original `testCommand` to see whether the
    /// confirmation used the same device.
    public let confirmingTestCommand: CommandRecord?
    /// Whether the fresh rebuild crashed the same way.
    public let crashedAgain: Bool
    public let diagnosis: String

    public init(
        confirmingBuildCommand: CommandRecord?,
        confirmingTestCommand: CommandRecord?,
        crashedAgain: Bool,
        diagnosis: String
    ) {
        self.confirmingBuildCommand = confirmingBuildCommand
        self.confirmingTestCommand = confirmingTestCommand
        self.crashedAgain = crashedAgain
        self.diagnosis = diagnosis
    }
}

/// What a `.timedOut` verdict's confirmation rebuild found.
///
/// Present only when `Configuration.execution.confirmTimedOutMutants` is on
/// and the mutant's first run timed out — the timeout twin of
/// `CrashConfirmation`, for the same reason: a mutant's crash-vs-hang
/// manifestation was found, empirically, to differ between an identical
/// mutant's two evaluations (even across different machines, even holding
/// execution context fixed), while whether the suite caught it at all did
/// not. A `.verifiedTimeout` verdict in a finished report always has
/// `timedOutAgain: true` here; a confirmation that did not reproduce the
/// timeout reclassifies the result before it is ever reported (see
/// `ResultClassifier.confirmTimeout`).
public struct TimeoutConfirmation: Codable, Sendable, Hashable {
    /// The confirmation's own build, in a sandbox independent of the one the
    /// original timeout was observed in.
    public let confirmingBuildCommand: CommandRecord?
    /// The confirmation's own test invocation, run under the same timeout
    /// limit as the original attempt — confirming a timeout with a longer
    /// limit would prove nothing about whether the *original* limit was
    /// legitimately exceeded again.
    public let confirmingTestCommand: CommandRecord?
    /// Whether the fresh rebuild timed out the same way.
    public let timedOutAgain: Bool
    public let diagnosis: String

    public init(
        confirmingBuildCommand: CommandRecord?,
        confirmingTestCommand: CommandRecord?,
        timedOutAgain: Bool,
        diagnosis: String
    ) {
        self.confirmingBuildCommand = confirmingBuildCommand
        self.confirmingTestCommand = confirmingTestCommand
        self.timedOutAgain = timedOutAgain
        self.diagnosis = diagnosis
    }
}

/// One test invocation this mutant went through on its way to a final
/// verdict.
///
/// A mutant tested in a single invocation — isolated execution, or ordinary
/// (non-wave) batching — already has that one attempt fully described by
/// `MutationEvidence`'s own `testCommand`/`resultArtifact`/`testSummary`, so
/// this list stays empty there. It exists for wave-based early kill, where a
/// mutant can be tested across several waves, each running a different
/// single covering test, before reaching `killed`/`survived`/`timedOut`:
/// without it, only the LAST wave's command/artifact/summary survived,
/// silently dropping every earlier wave's evidence even though those earlier
/// waves are exactly what "this mutant passed test A, then failed test B"
/// means.
///
/// `selectedTests`/`status` are plain strings rather than
/// `MutationExecution`'s own `TestIdentifier`/`TestRunStatus` types:
/// `MutationModel` is the lower-level module `MutationExecution` depends on,
/// not the other way around, so it cannot reference those types without a
/// circular dependency. The conversion (`TestIdentifier.onlyTestingArgument`,
/// `TestRunStatus.rawValue`) happens once, at the call site that already has
/// both types in scope — the same boundary convention
/// `TestOutcomeSummary.failingTests: [String]` already uses.
public struct TestAttemptEvidence: Codable, Sendable, Hashable {
    /// `-only-testing:`-style identifiers this attempt ran, or `nil` when it
    /// ran the mutant's full configured test list.
    public let selectedTests: [String]?
    /// This attempt's raw `TestRunStatus.rawValue` (`"passed"`, `"failed"`,
    /// `"crashed"`, `"timedOut"`, `"infrastructureFailure"`).
    public let status: String
    public let summary: TestOutcomeSummary?
    public let command: CommandRecord?
    /// Path to this attempt's own `.xcresult` or equivalent, relative to the
    /// run directory — independent of `MutationEvidence.resultArtifact`,
    /// which is always the *final* attempt's.
    public let resultArtifact: String?
    /// Which wave (0-based) this attempt belongs to; `nil` outside wave-based
    /// execution.
    public let waveIndex: Int?

    public init(
        selectedTests: [String]?,
        status: String,
        summary: TestOutcomeSummary?,
        command: CommandRecord?,
        resultArtifact: String?,
        waveIndex: Int?
    ) {
        self.selectedTests = selectedTests
        self.status = status
        self.summary = summary
        self.command = command
        self.resultArtifact = resultArtifact
        self.waveIndex = waveIndex
    }
}

/// The per-mutant record that has to exist before a mutant may appear in a report.
///
/// The design's rule — "if we cannot prove it, we do not score it" — is enforced
/// by requiring this struct to be populated and self-consistent. A mutant with
/// no source diff is a phantom and fails the whole run.
public struct MutationEvidence: Codable, Sendable, Hashable {
    /// Hash of the file before the edit. Must equal the plan's `sourceFileHash`.
    public let sourceBeforeHash: String
    /// Hash after the edit. Must differ from `sourceBeforeHash`.
    public let sourceAfterHash: String
    /// Unified diff of the single edit. Human-checkable, and the thing a
    /// reviewer is actually shown.
    public let sourceDiff: String
    public let buildProductHash: String?
    /// What was actually observed about whether the mutation reached the
    /// running code — `.isolated` for the isolated backend (a whole-binary
    /// hash comparison, sound on its own) or `.schemata` for the schemata
    /// backend, whose `SchemataExecutionObservation` is raw and unproven
    /// (see `MutationApplicationEvidence`'s own doc comment): this field is
    /// attached whenever the mutation reached the point of gathering
    /// observations at all, proven or not — only
    /// `MutationVerdictVerifier.verifySchemataChain` decides whether it
    /// actually proves anything, and only at classification time.
    public let applicationEvidence: MutationApplicationEvidence?
    public let buildCommand: CommandRecord?
    public let testCommand: CommandRecord?
    /// Path to the `.xcresult` or equivalent, relative to the run directory.
    public let resultArtifact: String?
    /// Present only for a `killedByCrash` verdict that was confirmed with an
    /// independent rebuild. See `CrashConfirmation`.
    public let crashConfirmation: CrashConfirmation?
    /// Present only for a `.verifiedTimeout` verdict that was confirmed with
    /// an independent rebuild. See `TimeoutConfirmation`.
    public let timeoutConfirmation: TimeoutConfirmation?
    /// Every test invocation this mutant went through before its final
    /// verdict. Empty outside wave-based early kill — see
    /// `TestAttemptEvidence`.
    public let testAttempts: [TestAttemptEvidence]

    public init(
        sourceBeforeHash: String,
        sourceAfterHash: String,
        sourceDiff: String,
        buildProductHash: String? = nil,
        applicationEvidence: MutationApplicationEvidence? = nil,
        buildCommand: CommandRecord? = nil,
        testCommand: CommandRecord? = nil,
        resultArtifact: String? = nil,
        crashConfirmation: CrashConfirmation? = nil,
        timeoutConfirmation: TimeoutConfirmation? = nil,
        testAttempts: [TestAttemptEvidence] = []
    ) {
        self.sourceBeforeHash = sourceBeforeHash
        self.sourceAfterHash = sourceAfterHash
        self.sourceDiff = sourceDiff
        self.buildProductHash = buildProductHash
        self.applicationEvidence = applicationEvidence
        self.buildCommand = buildCommand
        self.testCommand = testCommand
        self.resultArtifact = resultArtifact
        self.crashConfirmation = crashConfirmation
        self.timeoutConfirmation = timeoutConfirmation
        self.testAttempts = testAttempts
    }

    enum CodingKeys: String, CodingKey {
        case sourceBeforeHash, sourceAfterHash, sourceDiff, buildProductHash, applicationEvidence
        case buildCommand, testCommand, resultArtifact, crashConfirmation, timeoutConfirmation, testAttempts
        /// Pre-schemata reports/checkpoints wrote a bare `ActivationEvidence`
        /// under this key. Not in `applicationEvidence`'s own coding path —
        /// only ever consulted as a fallback, see `init(from:)`.
        case legacyActivationEvidence = "activationEvidence"
    }

    /// `testAttempts` postdates this type: an archived report or checkpoint
    /// line written before it existed has no key for it. Decoded with
    /// `decodeIfPresent` so that JSON yields `[]` rather than failing, the
    /// same convention `MutationResult`'s own custom decoder uses for its
    /// fields that postdate it.
    ///
    /// `applicationEvidence` reads the same way: a report written before
    /// the schemata backend existed has `activationEvidence: ActivationEvidence`
    /// under the old key, never `applicationEvidence`. Decoding tries the
    /// new key first; only when it is entirely absent does it fall back to
    /// the legacy key and wrap the result in `.isolated(...)` — a report
    /// that already has the new key (however it got there) is never
    /// second-guessed by the legacy fallback.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceBeforeHash = try container.decode(String.self, forKey: .sourceBeforeHash)
        sourceAfterHash = try container.decode(String.self, forKey: .sourceAfterHash)
        sourceDiff = try container.decode(String.self, forKey: .sourceDiff)
        buildProductHash = try container.decodeIfPresent(String.self, forKey: .buildProductHash)
        if let current = try container.decodeIfPresent(MutationApplicationEvidence.self, forKey: .applicationEvidence) {
            applicationEvidence = current
        } else if let legacy = try container.decodeIfPresent(ActivationEvidence.self, forKey: .legacyActivationEvidence) {
            applicationEvidence = .isolated(legacy)
        } else {
            applicationEvidence = nil
        }
        buildCommand = try container.decodeIfPresent(CommandRecord.self, forKey: .buildCommand)
        testCommand = try container.decodeIfPresent(CommandRecord.self, forKey: .testCommand)
        resultArtifact = try container.decodeIfPresent(String.self, forKey: .resultArtifact)
        crashConfirmation = try container.decodeIfPresent(CrashConfirmation.self, forKey: .crashConfirmation)
        timeoutConfirmation = try container.decodeIfPresent(TimeoutConfirmation.self, forKey: .timeoutConfirmation)
        testAttempts = try container.decodeIfPresent([TestAttemptEvidence].self, forKey: .testAttempts) ?? []
    }

    /// Explicit `Encodable` conformance is needed now that `init(from:)` is
    /// hand-written and reads a key (`legacyActivationEvidence`) that has no
    /// matching stored property to synthesize an encoder from — every
    /// current report is written under `applicationEvidence`, never the
    /// legacy key, so encoding only ever needs the non-legacy `CodingKeys`
    /// cases.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceBeforeHash, forKey: .sourceBeforeHash)
        try container.encode(sourceAfterHash, forKey: .sourceAfterHash)
        try container.encode(sourceDiff, forKey: .sourceDiff)
        try container.encodeIfPresent(buildProductHash, forKey: .buildProductHash)
        try container.encodeIfPresent(applicationEvidence, forKey: .applicationEvidence)
        try container.encodeIfPresent(buildCommand, forKey: .buildCommand)
        try container.encodeIfPresent(testCommand, forKey: .testCommand)
        try container.encodeIfPresent(resultArtifact, forKey: .resultArtifact)
        try container.encodeIfPresent(crashConfirmation, forKey: .crashConfirmation)
        try container.encodeIfPresent(timeoutConfirmation, forKey: .timeoutConfirmation)
        try container.encode(testAttempts, forKey: .testAttempts)
    }

    /// The minimum bar for "this mutation was really applied to the source".
    public var provesSourceApplication: Bool {
        sourceBeforeHash != sourceAfterHash && !sourceDiff.isEmpty
    }
}
