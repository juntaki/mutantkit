import Foundation

/// Which tests ran, and which of them failed, taken from structured output.
///
/// Populated from `.xcresult` or the Swift Testing / XCTest structured stream —
/// never from scraping stdout with regexes, which is how Muter came to classify
/// a Swift Testing output change as a runtime error.
public struct TestOutcomeSummary: Codable, Sendable, Hashable {
    public let total: Int
    public let passed: Int
    public let failed: Int
    /// Identifiers of failing tests. These are what `inspect` shows as "the
    /// tests that caught this mutant".
    public let failingTests: [String]
    public let durationSeconds: Double?

    public init(total: Int, passed: Int, failed: Int, failingTests: [String], durationSeconds: Double?) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.failingTests = failingTests
        self.durationSeconds = durationSeconds
    }
}

/// Where a `MutationResult` came from in *this* run.
///
/// A finished report mixes freshly-evaluated mutants with ones that were
/// reused without re-running them. Those three sources must stay separable
/// because they answer different questions:
///
/// - `.fresh`: the run built and tested this mutant itself. The result is the
///   evidence of *this* run.
/// - `.checkpoint`: the result was loaded from this run's own checkpoint — a
///   same-run resume of an interrupted attempt against an identical context.
/// - `.crossRunCache`: the result was loaded from the cross-run result cache —
///   a verdict a *prior* run stored and this one reused without rebuilding.
///
/// The previous design collapsed the last two into a single
/// `wasResumedFromCheckpoint` boolean, so a cross-run cache hit was recorded
/// as a checkpoint resume: "how do I know this wasn't reused against a
/// different source" got two different correct answers recorded as one, and
/// `PerformanceSummary.resumedMutants` could not tell a cheap cache reuse
/// from an interrupted-and-resumed run. `origin` keeps them apart.
public enum ResultOrigin: String, Codable, Sendable, Hashable {
    case fresh
    case checkpoint
    case crossRunCache
}

/// The outcome of one mutant, with the proof that backs it.
///
/// ADR-0006 Stage 1: this is a **verified projection**, not a value any
/// pipeline stage constructs from scratch. It has no public initializer —
/// the only way to build a fresh one is `MutationResult.projected(from:point:...)`,
/// which reads outcome/evidence/testSummary/diagnosis straight off a
/// `VerifiedMutationRecord` and carries that record's own `mutationRef`
/// forward. Because of that, `MutationResult` itself is safe to use as a
/// `ResultLedger` entry directly (see `MutationLedgerEntry` conformance
/// below) — nothing downstream needs to keep a separate `VerifiedMutationRecord`
/// alive alongside it just to get a trustworthy, intrinsic ledger key; the
/// projection carries its own.
public struct MutationResult: Codable, Sendable, Identifiable {
    public var id: MutationID { point.id }

    /// The verified record's own identity — set from `record.mutationRef`
    /// at projection time, so `MutationResult` can serve as a
    /// `ResultLedger` entry directly, with no separate `VerifiedMutationRecord`
    /// kept alive alongside it. A `MutationResult` decoded from a
    /// `report.json` written before this field existed gets a placeholder
    /// (`PlannedMutationRef.forPoint(point, planID: "legacy-report",
    /// workUnitID: "legacy-report")`, computed from real point content but
    /// a fabricated plan identity) — harmless, since a legacy-decoded
    /// result is read only for display (`inspect`/`history`), never
    /// reinserted into a ledger or re-entered into scoring.
    public let mutationRef: PlannedMutationRef
    /// The verifier version that produced this result — read directly off
    /// the record at projection time, never passed in by a caller. Lets
    /// `MutationResultCache`/`CheckpointStore` (ADR-0006 Stage 1) validate
    /// a stored result's freshness from the result itself, the same way
    /// `mutationRef` lets them validate its identity. `0` for a legacy-
    /// decoded `MutationResult` (see `mutationRef`'s doc comment) — always
    /// stale against any real `MutationVerdictVerifier.currentVersion`,
    /// which starts at `1`.
    public let verificationVersion: Int
    public let point: MutationPoint
    public let outcome: MutationOutcome
    public let evidence: MutationEvidence?
    public let testSummary: TestOutcomeSummary?
    /// Why this outcome, in one sentence, for humans.
    public let diagnosis: String
    public let durationSeconds: Double
    /// Wall time inside `BuildAdapter.buildMutant`, when a build was
    /// attempted. `nil` for a result reached before any build ran (a
    /// mutation application error, the `.noCoverage` fast path) — absence
    /// means "no build ran", not "unknown".
    public let buildDurationSeconds: Double?
    /// Wall time of this mutant's first test run. For a batched mutant this
    /// is the whole batch invocation's duration — every mutant sharing that
    /// batch records the same value, since they ran together in one
    /// `xcodebuild` invocation and there's no finer-grained truth to report.
    public let testDurationSeconds: Double?
    /// Wall time spent in whichever confirmation retest ran (`confirmKill` /
    /// `confirmCrashKill` / `confirmTimeout`), if any; `nil` when none
    /// applied.
    public let confirmationDurationSeconds: Double?
    /// Where this result came from in this run — freshly evaluated, loaded
    /// from this run's checkpoint, or reused from the cross-run result
    /// cache. See `ResultOrigin` for why the distinction is recorded rather
    /// than collapsed. Safe by construction now that a checkpoint's file
    /// name is scoped to a `RunContextFingerprint`, but still recorded:
    /// "how do I know this wasn't reused against a different source" is
    /// exactly the question a surprising result deserves an answer to, not
    /// just a guarantee.
    public let origin: ResultOrigin

    /// Not public: only `projected(from:point:...)` (and the legacy
    /// `Decodable` path, for reading an already-written `report.json` back
    /// for display — never re-entering scoring/caching) construct one.
    init(
        mutationRef: PlannedMutationRef,
        verificationVersion: Int,
        point: MutationPoint,
        outcome: MutationOutcome,
        evidence: MutationEvidence?,
        testSummary: TestOutcomeSummary?,
        diagnosis: String,
        durationSeconds: Double,
        buildDurationSeconds: Double? = nil,
        testDurationSeconds: Double? = nil,
        confirmationDurationSeconds: Double? = nil,
        origin: ResultOrigin = .fresh
    ) {
        self.mutationRef = mutationRef
        self.verificationVersion = verificationVersion
        self.point = point
        self.outcome = outcome
        self.evidence = evidence
        self.testSummary = testSummary
        self.diagnosis = diagnosis
        self.durationSeconds = durationSeconds
        self.buildDurationSeconds = buildDurationSeconds
        self.testDurationSeconds = testDurationSeconds
        self.confirmationDurationSeconds = confirmationDurationSeconds
        self.origin = origin
    }

    /// The only real construction path: reads outcome/evidence/testSummary/
    /// diagnosis straight off `record.proof` — see `VerdictProof`'s own
    /// accessors. `point` comes from the caller (the plan already has it;
    /// `PlannedMutationRef` only carries a content digest, not the full
    /// point), and durations are operational timing facts the verifier
    /// never sees, not judgment facts.
    public enum ProjectionError: Error, Equatable, CustomStringConvertible {
        /// `point` does not recompute the identical `PlannedMutationRef`
        /// `record` was actually verified against — either a different
        /// mutation's point was passed by mistake, or `point`'s content
        /// disagrees with what `record` was verified from (a changed
        /// replacement text, a different source-file hash, ...). Combining
        /// them anyway would silently attach one mutation's proof to
        /// another's display facts.
        case mutationRefMismatch(expected: PlannedMutationRef, computed: PlannedMutationRef)

        public var description: String {
            switch self {
            case let .mutationRefMismatch(expected, computed):
                "MutationResult.projected(from:point:...): point recomputes to \(computed), but the record was verified against \(expected) — refusing to combine them"
            }
        }
    }

    /// The only real construction path. `point` must recompute the exact
    /// `PlannedMutationRef` `record.mutationRef` already carries — checked
    /// here, not trusted, so a caller cannot accidentally (or maliciously)
    /// combine one mutation's verified proof with a different mutation's
    /// display facts. `planID`/`workUnitID` come from the caller's own
    /// plan (the same values used to verify `record` in the first place —
    /// see `PlannedMutationRef.forPoint`), not read off `record` itself,
    /// since trusting `record`'s own claim about which plan it belongs to
    /// would defeat the check.
    public static func projected(
        from record: VerifiedMutationRecord,
        point: MutationPoint,
        planID: String,
        workUnitID: String,
        durationSeconds: Double,
        buildDurationSeconds: Double? = nil,
        testDurationSeconds: Double? = nil,
        confirmationDurationSeconds: Double? = nil,
        origin: ResultOrigin = .fresh
    ) throws -> MutationResult {
        let computedRef = PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID)
        guard computedRef == record.mutationRef else {
            throw ProjectionError.mutationRefMismatch(expected: record.mutationRef, computed: computedRef)
        }
        return MutationResult(
            mutationRef: record.mutationRef,
            verificationVersion: record.verificationVersion,
            point: point,
            outcome: record.outcome,
            evidence: record.proof.evidence,
            testSummary: record.proof.testSummary,
            diagnosis: record.proof.diagnosis,
            durationSeconds: durationSeconds,
            buildDurationSeconds: buildDurationSeconds,
            testDurationSeconds: testDurationSeconds,
            confirmationDurationSeconds: confirmationDurationSeconds,
            origin: origin
        )
    }

    /// Re-anchors a verified record to the *current* run's plan identity,
    /// for a cross-run result cache: unlike `projected`, this does not
    /// require `record.mutationRef.planID`/`workUnitID` to match the
    /// caller's — `MutationResultCache` is keyed by mutation identity plus
    /// an explicit context digest, not by plan, so a record verified during
    /// a *different* run's plan is the expected, legitimate case here, not
    /// an error. What must still match is the mutation's own *content*
    /// identity: `mutationID` and `pointDigest`, both recomputed from
    /// `point` and compared against what `record` was actually verified
    /// against. A cache entry whose point has since changed shape (a
    /// different replacement text, a shifted byte range, an edited source
    /// file) fails this the same way `projected` fails a mismatched one —
    /// this is `MutationResultCache.load`'s "validate the current context"
    /// step (ADR-0006 Stage 1), not a relaxed version of it.
    public static func reanchored(
        from record: VerifiedMutationRecord,
        point: MutationPoint,
        planID: String,
        workUnitID: String,
        durationSeconds: Double,
        buildDurationSeconds: Double? = nil,
        testDurationSeconds: Double? = nil,
        confirmationDurationSeconds: Double? = nil,
        origin: ResultOrigin = .fresh
    ) throws -> MutationResult {
        guard record.mutationRef.mutationID == point.id,
              record.mutationRef.pointDigest == PlannedMutationRef.pointDigest(for: point)
        else {
            throw ProjectionError.mutationRefMismatch(
                expected: record.mutationRef,
                computed: PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID)
            )
        }
        return MutationResult(
            mutationRef: PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID),
            verificationVersion: record.verificationVersion,
            point: point,
            outcome: record.outcome,
            evidence: record.proof.evidence,
            testSummary: record.proof.testSummary,
            diagnosis: record.proof.diagnosis,
            durationSeconds: durationSeconds,
            buildDurationSeconds: buildDurationSeconds,
            testDurationSeconds: testDurationSeconds,
            confirmationDurationSeconds: confirmationDurationSeconds,
            origin: origin
        )
    }

    /// A copy of this result, marked as loaded from this run's checkpoint
    /// rather than freshly computed in this run.
    public func markedAsCheckpointResume() -> MutationResult {
        withOrigin(.checkpoint)
    }

    /// A copy of this result, marked as reused from the cross-run result
    /// cache — a verdict a prior run stored and this one served without
    /// rebuilding or retesting.
    public func markedAsCrossRunCacheHit() -> MutationResult {
        withOrigin(.crossRunCache)
    }

    private func withOrigin(_ newOrigin: ResultOrigin) -> MutationResult {
        MutationResult(
            mutationRef: mutationRef,
            verificationVersion: verificationVersion,
            point: point,
            outcome: outcome,
            evidence: evidence,
            testSummary: testSummary,
            diagnosis: diagnosis,
            durationSeconds: durationSeconds,
            buildDurationSeconds: buildDurationSeconds,
            testDurationSeconds: testDurationSeconds,
            confirmationDurationSeconds: confirmationDurationSeconds,
            origin: newOrigin
        )
    }

    enum CodingKeys: String, CodingKey {
        case mutationRef, verificationVersion, point, outcome, evidence, testSummary, diagnosis, durationSeconds
        case buildDurationSeconds, testDurationSeconds, confirmationDurationSeconds
        case origin
    }

    /// Key written by builds before `origin` existed. Kept only for decoding:
    /// a record from that era carries `wasResumedFromCheckpoint: Bool`
    /// instead. It is never written by this build.
    private enum LegacyOriginKey: String, CodingKey {
        case wasResumedFromCheckpoint
    }

    // `origin` postdates this type: a JSON record written before it existed —
    // an archived report, a checkpoint line from an older build — has no key
    // for it. Such a record may instead carry the legacy
    // `wasResumedFromCheckpoint` boolean, in which case `true` (the old
    // "loaded, not freshly computed") maps to `.checkpoint` and everything
    // else to `.fresh`. The old field could not separate a cache hit from a
    // checkpoint resume, so the legacy value cannot tell us which it really
    // was; `.checkpoint` is the conservative choice for a `true`.
    //
    // `buildDurationSeconds`/`testDurationSeconds`/`confirmationDurationSeconds`
    // postdate this type the same way — decoded with `decodeIfPresent`
    // so older JSON without these keys yields `nil` rather than failing.
    // `mutationRef` postdates this type too — see its own doc comment for
    // why a legacy-decoded value gets a placeholder rather than failing to
    // decode at all: a report.json this old predates real result-level
    // trust chains entirely, and reading it back is display-only.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        point = try container.decode(MutationPoint.self, forKey: .point)
        outcome = try container.decode(MutationOutcome.self, forKey: .outcome)
        evidence = try container.decodeIfPresent(MutationEvidence.self, forKey: .evidence)
        testSummary = try container.decodeIfPresent(TestOutcomeSummary.self, forKey: .testSummary)
        diagnosis = try container.decode(String.self, forKey: .diagnosis)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        buildDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .buildDurationSeconds)
        testDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .testDurationSeconds)
        confirmationDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .confirmationDurationSeconds)
        if let stored = try container.decodeIfPresent(PlannedMutationRef.self, forKey: .mutationRef) {
            mutationRef = stored
        } else {
            mutationRef = PlannedMutationRef.forPoint(point, planID: "legacy-report", workUnitID: "legacy-report")
        }
        verificationVersion = try container.decodeIfPresent(Int.self, forKey: .verificationVersion) ?? 0
        if let stored = try container.decodeIfPresent(ResultOrigin.self, forKey: .origin) {
            origin = stored
        } else {
            let legacy = try decoder.container(keyedBy: LegacyOriginKey.self)
            let wasResumed = try legacy.decodeIfPresent(Bool.self, forKey: .wasResumedFromCheckpoint) ?? false
            origin = wasResumed ? .checkpoint : .fresh
        }
    }

    /// A result may only be reported if we can prove the mutation was applied.
    /// Outcomes that never touched the source (`skipped`, `notApplied`) are
    /// exempt because for them the absence of a diff *is* the honest record.
    public var isReportable: Bool {
        switch outcome {
        case .skipped, .notApplied:
            true
        default:
            evidence?.provesSourceApplication == true
        }
    }
}

/// The baseline run: what the suite does with no mutations at all.
///
/// Everything downstream is measured against this. If the baseline is not green
/// and stable, a "survived" mutant means nothing, so the run stops here.
public struct BaselineRecord: Codable, Sendable {
    public let passed: Bool
    /// `nil` when the runner reported no per-test counts.
    ///
    /// `passed` is the load-bearing field and is always known; this is detail.
    /// Optional so that "the runner told us nothing" cannot be written down as
    /// "0 of 0 tests passed" — a baseline that really ran a suite would then be
    /// reported as having run nothing, which is a fabricated measurement and
    /// reads as a much more alarming fact than the truth.
    public let testSummary: TestOutcomeSummary?
    public let durationSeconds: Double
    public let buildProductHash: String?
    public let buildCommand: CommandRecord?
    public let testCommand: CommandRecord?
    /// Wall time of `BuildAdapter.buildBaseline`, when the baseline reached
    /// a completed test run (pass or fail — but NOT when the build itself
    /// failed or the test couldn't even start). `nil` otherwise.
    public let buildDurationSeconds: Double?
    /// Wall time of `TestAdapter.runBaseline`, under the same condition as
    /// `buildDurationSeconds`.
    public let testDurationSeconds: Double?
    /// Wall time spent measuring baseline coverage (`measurePerTestCoverage`
    /// and/or `readCoverage`), when either was attempted; `nil` when neither
    /// `selectCoveringTests` nor `measureCoverage` is configured, or the
    /// baseline never got that far.
    public let profilingDurationSeconds: Double?

    public init(
        passed: Bool,
        testSummary: TestOutcomeSummary?,
        durationSeconds: Double,
        buildProductHash: String?,
        buildCommand: CommandRecord?,
        testCommand: CommandRecord?,
        buildDurationSeconds: Double? = nil,
        testDurationSeconds: Double? = nil,
        profilingDurationSeconds: Double? = nil
    ) {
        self.passed = passed
        self.testSummary = testSummary
        self.durationSeconds = durationSeconds
        self.buildProductHash = buildProductHash
        self.buildCommand = buildCommand
        self.testCommand = testCommand
        self.buildDurationSeconds = buildDurationSeconds
        self.testDurationSeconds = testDurationSeconds
        self.profilingDurationSeconds = profilingDurationSeconds
    }
}

/// How the batched test phase was actually shaped, when batching ran at
/// all. `nil` on `RunReport.batchExecution` means no batch was ever
/// formed — either `execution.testBatchSize` was not configured, or
/// `evaluateIncrementally`/the plain per-mutant path ran instead. A
/// non-nil summary with `batchCount == 0` means batching WAS configured
/// but every mutant finished before reaching the test phase (e.g. every
/// mutant hit `.noCoverage` or a build failure) — a real, honest zero,
/// not "unknown".
public struct BatchExecutionSummary: Codable, Sendable {
    public let batchCount: Int
    public let totalConfigurations: Int
    public let averageConfigurationsPerBatch: Double
    /// The real wall-clock duration of each genuine batch test invocation,
    /// one entry per chunk that actually reached `BatchTestable.runBatch`
    /// (see `MutationRunner.testAndFinish`) — recorded once per chunk, not
    /// once per mutant in it.
    ///
    /// This exists because `MutationResult.testDurationSeconds` records the
    /// *same* value on every mutant that shared a batch invocation — correct
    /// for "how long did testing this mutant's batch take", but naively
    /// summing it across those mutants would multiply one real invocation's
    /// duration by however many mutants shared it. `batchDurations` is the
    /// one-entry-per-invocation ground truth `PerformanceSummary` sums
    /// instead, so it never has to guess which per-mutant values are
    /// duplicates of each other.
    ///
    /// May have fewer entries than `batchCount`: a chunk that never got a
    /// batch sandbox (see the `catch` in `testAndFinish`) is still counted
    /// in `batchCount` — every mutant in it still needs a result — but never
    /// ran `runBatch`, so there is no real duration to record for it.
    public let batchDurations: [Double]

    public init(batchCount: Int, totalConfigurations: Int, batchDurations: [Double] = []) {
        self.batchCount = batchCount
        self.totalConfigurations = totalConfigurations
        self.averageConfigurationsPerBatch = batchCount == 0 ? 0 : Double(totalConfigurations) / Double(batchCount)
        self.batchDurations = batchDurations
    }

    enum CodingKeys: String, CodingKey {
        case batchCount, totalConfigurations, averageConfigurationsPerBatch, batchDurations
    }

    /// `batchDurations` postdates this type the same way the per-mutant
    /// stage timings postdate `MutationResult`: an archived report written
    /// before it existed has no key for it, so it decodes to `[]` — "not
    /// recorded", not a fabricated zero-duration batch.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batchCount = try container.decode(Int.self, forKey: .batchCount)
        totalConfigurations = try container.decode(Int.self, forKey: .totalConfigurations)
        averageConfigurationsPerBatch = try container.decode(Double.self, forKey: .averageConfigurationsPerBatch)
        batchDurations = try container.decodeIfPresent([Double].self, forKey: .batchDurations) ?? []
    }
}

/// What execution strategy a run actually used, next to what was requested.
/// See `RunReport.executionStrategy`'s doc comment for why this exists.
public struct ExecutionStrategyReport: Codable, Sendable, Hashable {
    public let requested: ExecutionMode
    /// How many planned mutations were actually embedded and scored through
    /// the requested strategy's own path (schemata's own build/verify, not
    /// isolated fallback).
    public let effectiveCount: Int
    /// How many planned mutations ran through isolated fallback instead —
    /// unsupported operator, multi-target conflict, or (when the whole run
    /// degraded) every mutation.
    public let fallbackCount: Int
    /// Set only when the *entire* run degraded to fallback before any
    /// per-mutation classification (target resolution or chunk planning
    /// failed) — `nil` for the ordinary case where some mutations are
    /// individually routed to fallback by `SchemataChunkPlanner`'s own
    /// per-mutation eligibility rules, which is not a degradation.
    public let degradationReason: String?

    public init(requested: ExecutionMode, effectiveCount: Int, fallbackCount: Int, degradationReason: String? = nil) {
        self.requested = requested
        self.effectiveCount = effectiveCount
        self.fallbackCount = fallbackCount
        self.degradationReason = degradationReason
    }
}

/// Everything one run produced. The input to every reporter.
public struct RunReport: Codable, Sendable {
    public let schemaVersion: Int
    public let planID: String
    public let startedAt: Date
    public let finishedAt: Date
    public let projectRoot: String
    public let toolchain: ToolchainFingerprint
    public let baseline: BaselineRecord
    public let results: [MutationResult]
    public let integrity: IntegrityReport
    /// `nil` when integrity failed. A score is a claim, and we do not make
    /// claims we cannot back.
    public let score: MutationScore?
    /// How the batched test phase was actually shaped, when batching ran at
    /// all. See `BatchExecutionSummary`'s doc comment for what `nil` versus
    /// a zero-count summary means.
    public let batchExecution: BatchExecutionSummary?
    /// `nil` for a plain `.isolated` run, where "requested" and "effective"
    /// are trivially the same thing and recording it would say nothing. Set
    /// only by `SchemataRunOrchestration` (ADR-0006 Stage 1): a requested
    /// `.schemata` run's *effective* execution — how many mutations were
    /// actually embedded versus routed to isolated fallback, and why, when
    /// the whole run degraded — is otherwise only ever printed to the
    /// console, never recorded anywhere a report reader (or another tool
    /// consuming `report.json`) can see it. No silent fallback: a mixed or
    /// fully-degraded schemata run must say so in the one artifact that
    /// outlives the run.
    public let executionStrategy: ExecutionStrategyReport?
    /// Best-effort infrastructure problems that never affected score or
    /// integrity but would otherwise be silent — checkpoint write failures,
    /// for now. Decoded as `[]` for report JSON written before this field
    /// existed; see `init(from:)` below.
    public let operationalIssues: [OperationalIssue]

    /// The only real construction path (ADR-0006 Stage 1, second review
    /// round): `ledger`, not a plain `[MutationResult]`, so a caller cannot
    /// hand this the same mutation's result twice — `ResultLedger.insert`
    /// already refused that at the moment each entry was added, which a
    /// bare array-accepting initializer could not enforce and every
    /// current caller (`MutationRunner.run()`, `SchemataRunOrchestration
    /// .merge`, `PlanSharding.merge`) already builds one before reaching
    /// here anyway. `results` is `ledger.entries`, sorted for a
    /// deterministic report — a display projection derived from the
    /// ledger, not independent authoritative state.
    public init(
        planID: String,
        startedAt: Date,
        finishedAt: Date,
        projectRoot: String,
        toolchain: ToolchainFingerprint,
        baseline: BaselineRecord,
        ledger: ResultLedger<MutationResult>,
        integrity: IntegrityReport,
        batchExecution: BatchExecutionSummary? = nil,
        executionStrategy: ExecutionStrategyReport? = nil,
        operationalIssues: [OperationalIssue] = []
    ) {
        schemaVersion = SchemaVersion.result
        self.planID = planID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.projectRoot = projectRoot
        self.toolchain = toolchain
        self.baseline = baseline
        let sorted = ledger.entries.sorted { $0.id < $1.id }
        results = sorted
        self.integrity = integrity
        score = integrity.passed ? MutationScore.tally(sorted.map(\.outcome)) : nil
        self.batchExecution = batchExecution
        self.executionStrategy = executionStrategy
        self.operationalIssues = operationalIssues
    }

    public func encoded() throws -> Data {
        try MutationPlan.encoder().encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, planID, startedAt, finishedAt, projectRoot, toolchain, baseline, results, integrity, score,
             batchExecution, executionStrategy, operationalIssues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        planID = try container.decode(String.self, forKey: .planID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        projectRoot = try container.decode(String.self, forKey: .projectRoot)
        toolchain = try container.decode(ToolchainFingerprint.self, forKey: .toolchain)
        baseline = try container.decode(BaselineRecord.self, forKey: .baseline)
        results = try container.decode([MutationResult].self, forKey: .results)
        integrity = try container.decode(IntegrityReport.self, forKey: .integrity)
        score = try container.decodeIfPresent(MutationScore.self, forKey: .score)
        batchExecution = try container.decodeIfPresent(BatchExecutionSummary.self, forKey: .batchExecution)
        executionStrategy = try container.decodeIfPresent(ExecutionStrategyReport.self, forKey: .executionStrategy)
        // Absent from report JSON written before this field existed —
        // treated as "no operational issues recorded", not an error.
        operationalIssues = try container.decodeIfPresent([OperationalIssue].self, forKey: .operationalIssues) ?? []
    }
}
