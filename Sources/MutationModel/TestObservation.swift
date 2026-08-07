import Foundation

/// Moved here from `MutationExecution` (ADR-0006 Stage 1): `MutationVerdictVerifier`
/// is the only place a mutation's outcome may be decided, and it lives in
/// `MutationModel` (so its exclusive-construction guarantee on
/// `VerifiedMutationRecord` holds across every caller). It therefore needs
/// to inspect these observation types directly, not a lossy re-encoding of
/// them — `MutationModel` cannot depend on `MutationExecution`, so the
/// types move down instead.

// MARK: - Build

/// Why a build failed, distinguishing "the mutant is not valid Swift" from
/// "this machine cannot build anything".
public enum BuildFailureKind: Codable, Sendable {
    /// The mutated source does not compile. A legitimate `unviable` mutant.
    case compilationError
    /// Toolchain, simulator, signing or disk problem. Never a mutant's fault.
    case infrastructure
    case timedOut
}

public struct BuildFailure: Error, Sendable {
    public let kind: BuildFailureKind
    public let diagnosis: String
    public let command: CommandRecord
    /// Truncated and redacted compiler output.
    public let output: String

    public init(kind: BuildFailureKind, diagnosis: String, command: CommandRecord, output: String) {
        self.kind = kind
        self.diagnosis = diagnosis
        self.command = command
        self.output = output
    }
}

// MARK: - Test

/// What a test run did, taken from structured output.
public enum TestRunStatus: String, Codable, Sendable {
    case passed
    /// At least one test assertion failed.
    case failed
    /// The runner died: trap, fatalError, signal.
    case crashed
    case timedOut
    /// Simulator boot failure, missing `.xctestrun`, toolchain error.
    case infrastructureFailure
}

public struct TestRunResult: Codable, Sendable {
    public let status: TestRunStatus
    /// `nil` when the runner produced no structured record of *which* tests ran.
    ///
    /// Optional rather than an empty summary, because those are different facts
    /// and only one of them is true. SwiftPM, for instance, writes no XCTest
    /// counts unless tests run in parallel — substituting a zeroed summary there
    /// would report "0 of 0 tests failed" for a suite that ran and caught the
    /// mutant, which is a fabricated measurement wearing the shape of a real
    /// one. `status` is independent of this and always known, so an absent
    /// summary costs detail, never correctness.
    public let summary: TestOutcomeSummary?
    public let command: CommandRecord
    /// Path to the `.xcresult` bundle, when the adapter produced one.
    public let resultArtifactPath: URL?
    /// One sentence explaining the status, from structured data — not a regex over stdout.
    public let diagnosis: String
    /// `true` only when `status == .timedOut` and that `.timedOut` came from
    /// a *batch-wide* timeout — the killed batch process's per-configuration
    /// results are all unattributed, so every mutant sharing that batch is
    /// reported `.timedOut` whether or not it individually hung (see
    /// `XcodeBuildAdapter.runBatchOnDestination`). `false` (the default) for
    /// every other status, and for a `.timedOut` observed against a single
    /// mutant on its own (`testBatchSize` of 1, or a non-batching adapter) —
    /// that *is* a real, specific observation of this mutant, unlike a
    /// batch-wide placeholder. `MutationVerdictVerifier` reads this to
    /// decide whether a confirming rebuild's disagreement is proof the
    /// mutant never really timed out (batch-attributed case) or the
    /// pipeline disagreeing with itself about a real observation (the
    /// genuine-timeout case, where the conservative `.flaky`
    /// reclassification still applies).
    public let isBatchAttributedTimeout: Bool

    public init(
        status: TestRunStatus,
        summary: TestOutcomeSummary?,
        command: CommandRecord,
        resultArtifactPath: URL?,
        diagnosis: String,
        isBatchAttributedTimeout: Bool = false
    ) {
        self.status = status
        self.summary = summary
        self.command = command
        self.resultArtifactPath = resultArtifactPath
        self.diagnosis = diagnosis
        self.isBatchAttributedTimeout = isBatchAttributedTimeout
    }
}

/// Whether the mutated code was executed by the suite.
public struct CoverageObservation: Codable, Sendable, Hashable {
    public let mutatedLineWasExecuted: Bool
    /// Where the claim came from, so a wrong one can be traced back.
    public let source: String

    public init(mutatedLineWasExecuted: Bool, source: String) {
        self.mutatedLineWasExecuted = mutatedLineWasExecuted
        self.source = source
    }
}
