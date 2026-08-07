import Foundation

/// Whether the mutation was written to source at all, and what it looked
/// like if so.
public enum SourceApplicationOutcome: Codable, Sendable {
    case applied(MutationEvidence)
    /// The anchor no longer matched — the file moved on since planning.
    case notApplied(diagnosis: String)
}

/// What a build attempt produced.
public struct BuildObservation: Codable, Sendable {
    public enum Outcome: Codable, Sendable {
        case succeeded(buildProductHash: String?, command: CommandRecord?)
        case failed(kind: BuildFailureKind, diagnosis: String, command: CommandRecord?)
        case infrastructureFailure(diagnosis: String)
        case timedOut(diagnosis: String)
    }

    public let outcome: Outcome
    public let durationSeconds: Double?

    public init(outcome: Outcome, durationSeconds: Double? = nil) {
        self.outcome = outcome
        self.durationSeconds = durationSeconds
    }
}

/// One test run, with whatever activation proof applies to it.
public struct SingleTestObservation: Codable, Sendable {
    public let run: TestRunResult
    /// Isolated mode's whole-binary hash comparison (sound on its own), or
    /// schemata mode's raw, unproven `SchemataExecutionObservation` — the
    /// verifier is the only place either one is turned into "proven"; see
    /// `MutationApplicationEvidence`'s own doc comment.
    public let applicationEvidence: MutationApplicationEvidence?

    public init(run: TestRunResult, applicationEvidence: MutationApplicationEvidence?) {
        self.run = run
        self.applicationEvidence = applicationEvidence
    }
}

/// A confirmation retry — a second, independent observation gathered
/// because `Configuration.execution.retestKilledMutants`/
/// `confirmCrashKills`/`confirmTimedOutMutants` is on and the primary run
/// looked like a kill/crash/timeout. Which kind of confirmation this is
/// determines which fields the verifier actually reads: `originalFailingTests`
/// only matters for `.kill`, `wasBatchAttributed` only for `.timeout`.
public struct ConfirmationObservation: Codable, Sendable {
    public enum Kind: Codable, Sendable { case kill, crash, timeout }

    public let kind: Kind
    public let run: TestRunResult
    /// The confirming run's own activation proof — only consulted for
    /// `.timeout` (a batch-attributed timeout's confirming run may pass,
    /// needing the same activation check any passing run needs). Isolated
    /// mode only; mutually exclusive with `schemataObservation`.
    public let activation: ActivationEvidence?
    /// The confirming run's own raw schemata observation — a genuinely
    /// independent `SchemataExecutionObservation`, with its own `RunID`,
    /// transcript, and expectation, never the primary run's. Mutually
    /// exclusive with `activation`. `MutationVerdictVerifier.confirm`
    /// verifies this confirmation's own STARTUP -> HIT chain exactly as it
    /// verifies the primary observation's — a confirmation is never
    /// credited on the strength of the run it is confirming.
    public let schemataObservation: SchemataExecutionObservation?
    /// The confirming rebuild's own build product hash — only consulted
    /// for `.timeout`, alongside `activation`. The primary path's evidence
    /// is cross-checked against an independently-observed `BuildObservation`
    /// (see `MutationVerdictVerifier.executionEvidenceProblem`); without an
    /// equivalent here, `activation` would be trusted on its own
    /// self-consistency alone (non-empty, distinct hashes) but never tied
    /// to a real build this confirmation actually produced — a forged
    /// `activation` naming hashes that never came from any build could
    /// still read as proven. `nil` only for a confirmation that never
    /// reached a successful build (an infrastructure failure, a build
    /// failure) — `activation` is `nil` in exactly the same cases.
    public let confirmingBuildProductHash: String?
    /// Only meaningful for `.timeout`.
    public let wasBatchAttributed: Bool
    /// The primary run's own failing-test list — only consulted for
    /// `.kill`'s exact-set comparison.
    public let originalFailingTests: [String]?
    /// The primary run's own diagnosis text — only consulted for `.crash`'s
    /// signature comparison.
    public let originalDiagnosis: String

    public init(
        kind: Kind,
        run: TestRunResult,
        activation: ActivationEvidence? = nil,
        schemataObservation: SchemataExecutionObservation? = nil,
        confirmingBuildProductHash: String? = nil,
        wasBatchAttributed: Bool = false,
        originalFailingTests: [String]? = nil,
        originalDiagnosis: String = ""
    ) {
        self.kind = kind
        self.run = run
        self.activation = activation
        self.schemataObservation = schemataObservation
        self.confirmingBuildProductHash = confirmingBuildProductHash
        self.wasBatchAttributed = wasBatchAttributed
        self.originalFailingTests = originalFailingTests
        self.originalDiagnosis = originalDiagnosis
    }

    /// `activation`/`schemataObservation` folded into the same
    /// `MutationApplicationEvidence` shape the primary observation uses —
    /// so `MutationVerdictVerifier` never needs a second, confirmation-only
    /// code path to ask "was this proven."
    var applicationEvidence: MutationApplicationEvidence? {
        if let activation { return .isolated(activation) }
        if let schemataObservation { return .schemata(schemataObservation) }
        return nil
    }
}

/// Everything observed about one mutation attempt — the sole input to
/// `MutationVerdictVerifier.verify`. Nothing about *what happened* is
/// decided before this reaches the verifier; deciding *whether to gather
/// more of it* (running a confirmation retry) is an orchestration decision
/// a runner still makes, but always from raw fields already present here
/// (`build`/`test`'s own status), never from a pre-computed outcome —
/// ADR-0006 Stage 1 removes `candidateOutcome` for exactly this reason.
public struct MutationObservations: Codable, Sendable {
    public let plannedMutation: PlannedMutationRef
    public let sourceApplication: SourceApplicationOutcome?
    public let build: BuildObservation?
    public let coverage: CoverageObservation?
    public let test: SingleTestObservation?
    /// In the order they were actually gathered. Usually zero or one, but
    /// a genuine cascade is real and representable: a batch-attributed
    /// timeout's confirming rebuild can itself turn out to be a kill or a
    /// crash, which — per `Configuration.execution.retestKilledMutants`/
    /// `confirmCrashKills` — needs its *own* confirmation before it is
    /// trusted, the same as any other first-observed kill/crash. Each
    /// entry's `kind` says which confirm rule applies to it; the verifier
    /// folds them in order, feeding each round's resulting classification
    /// into the next.
    public let confirmations: [ConfirmationObservation]
    /// Set only for a failure before source application was even
    /// attempted (sandbox creation, an unreadable/unwritable file) — no
    /// more specific observation exists to attach.
    public let infrastructureFailureDiagnosis: String?

    public init(
        plannedMutation: PlannedMutationRef,
        sourceApplication: SourceApplicationOutcome? = nil,
        build: BuildObservation? = nil,
        coverage: CoverageObservation? = nil,
        test: SingleTestObservation? = nil,
        confirmations: [ConfirmationObservation] = [],
        infrastructureFailureDiagnosis: String? = nil
    ) {
        self.plannedMutation = plannedMutation
        self.sourceApplication = sourceApplication
        self.build = build
        self.coverage = coverage
        self.test = test
        self.confirmations = confirmations
        self.infrastructureFailureDiagnosis = infrastructureFailureDiagnosis
    }
}
