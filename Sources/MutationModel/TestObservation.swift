import Foundation

// Moved here from `MutationExecution` (the authoritative verdict pipeline): `MutationVerdictVerifier`
// is the only place a mutation's outcome may be decided, and it lives in
// `MutationModel` (so its exclusive-construction guarantee on
// `VerifiedMutationRecord` holds across every caller). It therefore needs
// to inspect these observation types directly, not a lossy re-encoding of
// them — `MutationModel` cannot depend on `MutationExecution`, so the
// types move down instead.

// MARK: - Build

/// Why a build failed, distinguishing "the mutant is not valid Swift" from
/// "this machine cannot build anything".
public enum BuildFailureKind: Codable, Sendable {
    /// The mutated source does not compile. A legitimate `unviable` mutant.
    case compilationError
    /// The compiler itself crashed on the mutated source, and an independent rebuild of the same
    /// mutation in a fresh sandbox crashed it again while the unmutated baseline builds. The mutant
    /// cannot be built into anything testable, so it is `unviable` like a compilation error, but it is
    /// a different build fact: a single crash is never this (see `BuildFailure.isCompilerCrashCandidate`).
    case confirmedCompilerCrash
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
    /// The output shows a Swift compiler process crashing (crash banner, stack dump with compiler frames
    /// and a signal frame) with no compiler diagnostic and no environment failure. Only a candidate: one
    /// crash cannot tell a mutant that crashes the compiler from a broken or overloaded machine, so the
    /// kind stays `.infrastructure` until the executor reproduces it in an independent rebuild.
    public let isCompilerCrashCandidate: Bool
    /// What identifies the crash of a candidate, when its output carries enough to tell it from another
    /// crash. A rebuild only confirms a crash that has the same signature as the first; a candidate
    /// without one cannot be confirmed.
    public let compilerCrashSignature: CompilerCrashSignature?

    public init(
        kind: BuildFailureKind, diagnosis: String, command: CommandRecord, output: String,
        isCompilerCrashCandidate: Bool = false, compilerCrashSignature: CompilerCrashSignature? = nil
    ) {
        self.kind = kind
        self.diagnosis = diagnosis
        self.command = command
        self.output = output
        self.isCompilerCrashCandidate = isCompilerCrashCandidate
        self.compilerCrashSignature = compilerCrashSignature
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
    /// Present only when `status == .crashed` was inferred from a fixed diagnostic line the test
    /// runner itself printed, because the structured outputs (exit status, xunit) could not record the
    /// crash. It is an observation, never a verdict: a crash that carries it must be independently
    /// confirmed (`MutationVerdictVerifier`), and without that confirmation it is not a kill.
    public let crashProvenance: CrashProvenance?

    public init(
        status: TestRunStatus,
        summary: TestOutcomeSummary?,
        command: CommandRecord,
        resultArtifactPath: URL?,
        diagnosis: String,
        isBatchAttributedTimeout: Bool = false,
        crashProvenance: CrashProvenance? = nil
    ) {
        self.crashProvenance = crashProvenance
        self.status = status
        self.summary = summary
        self.command = command
        self.resultArtifactPath = resultArtifactPath
        self.diagnosis = diagnosis
        self.isBatchAttributedTimeout = isBatchAttributedTimeout
    }
}

/// Why a test run was called a crash without a structured record of one: the exact diagnostic line, who
/// printed it, and the raw output it came from, so the claim can be re-examined offline.
public struct CrashProvenance: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable, Hashable {
        /// SwiftPM's `error: Process '<cmd>' exited with unexpected signal code <N>`, printed by
        /// `swift test` when its test helper process is killed by a signal.
        case swiftPMTestHelperSignalDiagnostic
    }

    public let source: Source
    public let matchedLine: String
    public let signal: Int32
    /// Bounded, redacted tails of the raw streams (the evidence the line was read from).
    public let standardErrorTail: String
    public let standardOutputTail: String

    public init(source: Source, matchedLine: String, signal: Int32, standardErrorTail: String, standardOutputTail: String) {
        self.source = source
        self.matchedLine = matchedLine
        self.signal = signal
        self.standardErrorTail = standardErrorTail
        self.standardOutputTail = standardOutputTail
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
