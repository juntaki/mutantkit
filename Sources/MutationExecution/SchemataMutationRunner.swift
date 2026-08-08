import Foundation
import MutationModel
import SwiftFrontend

/// The schemata-backend orchestration loop — sibling to `MutationRunner`,
/// not a replacement for it. `MutationRunner` is never touched or called
/// from here; the two are combined by the CLI layer (`SchemataRunOrchestration`),
/// not by either engine type itself.
///
/// One sandbox and one build per chunk, one fresh test process per embedded
/// mutation — see the plan this was built from (ADR-0004's schemata
/// production-integration effort) for why: `swift test` leaves a
/// `swiftpm-testing-helper` descendant outside the launched process's own
/// group, so the harness can never know the real test process's PID in
/// advance. Every run therefore goes through the same nonce-primary
/// evidence protocol `SchemataEvidenceCollector` already provides for the
/// Xcode case — not Xcode-specific plumbing reused opportunistically, but
/// the one mechanism both backends need.
///
/// Sequential only in v1: no parallel workers, no checkpointing, no
/// cross-run cache participation. Correctness first.
///
/// `public` (ADR-0006 Stage 3): schemata scoring is re-enabled, so
/// `SchemataRunOrchestration` (`CLI`) constructs and calls one directly
/// for whatever `SchemataChunkPlanner` embeds — everything else still
/// routes to isolated fallback.
public struct SchemataMutationRunner: Sendable {
    /// What one full run produced. Raw pieces, not a `RunReport` — the CLI
    /// layer combines this with isolated-fallback results before building
    /// one report.
    public struct Outcome: Sendable {
        public let baseline: BaselineRecord
        /// One aggregate `MutationResult` per mutation, for display and
        /// for feeding a `RunReport` the same way isolated mode's results
        /// do. For a mutation embedded into more than one target, this is
        /// `multiTargetVerdicts`'s own aggregation policy's winner (kill
        /// in any target wins) — never a value computed separately from
        /// it, so `results` and `multiTargetVerdicts` can never disagree
        /// about which outcome won.
        public let results: [MutationResult]
        /// Every target's own verdict for every mutation, preserved in
        /// full (ADR-0006 Stage 1) — nothing about a losing target's
        /// evidence is discarded here, unlike ADR-0005 PR F's
        /// `mergeMultiTargetResults`, which this replaces.
        public let multiTargetVerdicts: [MultiTargetVerdict]
        /// Every mutation this run attempted through schemata but could not
        /// score from schemata evidence alone (`MutationVerdictVerifier
        /// .schemataIsolatedFallbackReason` — a passing test with no proof
        /// the mutation was ever selected/hit) and therefore excluded
        /// entirely from `results`/`multiTargetVerdicts`: no schemata
        /// `TargetRecord` for this `MutationID`, for *any* of its target
        /// placements, was kept (`groupByMutation`'s own all-or-nothing
        /// rule — see `run()`). `SchemataRunOrchestration` re-runs each of
        /// these through isolated `MutationRunner` instead; this runner
        /// never scores them itself.
        public let isolatedFallbacks: [DynamicFallback]
    }

    /// One mutation this run could not prove activation for from schemata
    /// evidence alone, and therefore never scored — see `Outcome
    /// .isolatedFallbacks`'s own doc comment.
    public struct DynamicFallback: Sendable, Hashable {
        public let mutationID: MutationID
        public let reason: MutationVerdictVerifier.SchemataIsolatedFallbackReason

        public init(mutationID: MutationID, reason: MutationVerdictVerifier.SchemataIsolatedFallbackReason) {
            self.mutationID = mutationID
            self.reason = reason
        }
    }

    public enum RunError: Error, CustomStringConvertible {
        case baselineDidNotPass(diagnosis: String)

        public var description: String {
            switch self {
            case let .baselineDidNotPass(diagnosis):
                "the schemata baseline did not pass, so no mutant can be scored against it: \(diagnosis)"
            }
        }
    }

    private let planID: String
    /// A real per-shard identity — see `MutationRunner`'s own equivalent
    /// fix (ADR-0006 Stage 1): `planID` alone cannot distinguish two
    /// shards of the same plan.
    private let workUnitID: String
    private let programs: [SchemataProgram]
    private let points: [MutationID: MutationPoint]
    /// Pristine, pre-lowering file content keyed by `MutationPoint.file` —
    /// the same `sources` map `SchemataChunkPlanner.plan(...)` was given.
    /// Needed to compute honest, non-fabricated source-level evidence
    /// (`MutationEvidence.sourceDiff` and friends) for each embedded
    /// mutation, since `SchemataProgram.loweredSources` only carries the
    /// final, already-rewritten chunk content.
    private let originalSources: [String: Data]
    private let build: any SchemataBuildable
    private let test: any SchemataTestable
    private let workspaces: WorkspaceManager
    private let timeoutSeconds: Double
    /// The real toolchain/build-argument identity this run's plan was
    /// validated against (`ExecutableSchemataPlan.toolchainHash`/
    /// `buildArgumentsHash`) — hashed once into the `SHA256Digest` shape
    /// `SchemataBuildReceipt` requires. A genuine content hash of the
    /// plan's own already-validated identity strings, not a placeholder.
    private let toolchainHash: SHA256Digest
    private let buildArgumentsHash: SHA256Digest
    /// The same `VerdictVerificationPolicy` an isolated `MutationRunner`
    /// would be constructed with for this run — the one source of truth
    /// both backends ask `MutationVerdictVerifier.confirmationRequirement`
    /// against, so schemata mode gathers exactly the confirmations
    /// `retestKilledMutants`/`confirmCrashKills`/`confirmTimedOutMutants`
    /// promise, never a policy this runner invents on its own.
    private let policy: MutationVerdictVerifier.VerdictVerificationPolicy

    public init(
        planID: String,
        workUnitID: String,
        programs: [SchemataProgram],
        points: [MutationID: MutationPoint],
        originalSources: [String: Data],
        build: any SchemataBuildable,
        test: any SchemataTestable,
        workspaces: WorkspaceManager,
        timeoutSeconds: Double,
        toolchainHash: String,
        buildArgumentsHash: String,
        policy: MutationVerdictVerifier.VerdictVerificationPolicy
    ) {
        self.planID = planID
        self.workUnitID = workUnitID
        self.programs = programs
        self.points = points
        self.originalSources = originalSources
        self.build = build
        self.test = test
        self.workspaces = workspaces
        self.timeoutSeconds = timeoutSeconds
        self.toolchainHash = SHA256Digest.of(Data(toolchainHash.utf8))
        self.buildArgumentsHash = SHA256Digest.of(Data(buildArgumentsHash.utf8))
        self.policy = policy
    }

    public func run() async throws -> Outcome {
        let baseline = try await establishBaseline()
        guard baseline.passed else {
            let summary = baseline.testSummary.map { "\($0.failed) of \($0.total) tests failed" }
            throw RunError.baselineDidNotPass(diagnosis: summary ?? "the baseline test run did not pass")
        }

        var entryOutcomes: [EntryRunOutcome] = []
        for program in programs {
            entryOutcomes.append(contentsOf: await runChunk(program))
        }

        // All-or-nothing per MutationID (never per placement): if *any* of
        // a mutation's target placements lacked runtime activation proof,
        // every placement's own schemata `TargetRecord` for that
        // `MutationID` — including one that individually verified fine —
        // is dropped before grouping. Never merge a schemata result for
        // one target with an isolated-fallback result for another; that
        // would double-ledger the same MutationID across two backends.
        var dynamicFallbackReasons: [MutationID: MutationVerdictVerifier.SchemataIsolatedFallbackReason] = [:]
        for case let .isolatedFallback(mutationID, reason) in entryOutcomes {
            dynamicFallbackReasons[mutationID] = reason
        }
        let perTarget: [TargetRecord] = entryOutcomes.compactMap {
            guard case let .verified(record) = $0, dynamicFallbackReasons[record.record.mutationRef.mutationID] == nil else { return nil }
            return record
        }

        let grouped = try Self.groupByMutation(perTarget)
        let verdicts = grouped.map { $0.verdict }
        let results = try grouped.map {
            try Self.projectAggregate($0, points: points, planID: planID, workUnitID: workUnitID)
        }
        // Deterministic order (sorted, not orchestration/completion order),
        // the same discipline `SchemataChunkPlanner`'s own chunk IDs use.
        let isolatedFallbacks = dynamicFallbackReasons
            .map { DynamicFallback(mutationID: $0.key, reason: $0.value) }
            .sorted { $0.mutationID.rawValue < $1.mutationID.rawValue }
        return Outcome(baseline: baseline, results: results, multiTargetVerdicts: verdicts, isolatedFallbacks: isolatedFallbacks)
    }

    /// What one embedded entry's own attempt produced — either a fully
    /// verified schemata result, or a signal that this `MutationID` (every
    /// target placement, not just this one) needs to be re-run through
    /// isolated mode instead (see `Outcome.isolatedFallbacks`'s own doc
    /// comment).
    private enum EntryRunOutcome {
        case verified(TargetRecord)
        case isolatedFallback(mutationID: MutationID, reason: MutationVerdictVerifier.SchemataIsolatedFallbackReason)
    }

    /// One target's own verified record, paired with which target
    /// produced it — the raw material `groupIntoMultiTargetVerdicts` folds
    /// into one `MultiTargetVerdict` per mutation.
    private struct TargetRecord {
        let targetIdentity: TargetExecutionIdentity
        let record: VerifiedMutationRecord
        let durationSeconds: Double
        let testDurationSeconds: Double?
    }

    /// One mutation's `MultiTargetVerdict`, paired with the raw
    /// `TargetRecord`s it was built from — kept alongside so
    /// `projectAggregate` can recover the winning target's own timing,
    /// which `TargetVerdict` itself does not carry.
    private struct GroupedMutation {
        let verdict: MultiTargetVerdict
        let perTarget: [TargetRecord]
    }

    /// A mutation embedded into more than one target (see
    /// `SchemataChunkPlanner.classify`) runs — and is verified — once per
    /// target, independently, since each is a genuinely separate build.
    /// Groups every target's own record by `MutationID` into one
    /// `MultiTargetVerdict`, preserving every target's evidence — see
    /// `MultiTargetVerdict`'s own doc comment for why this replaced
    /// ADR-0005 PR F's lossy `mergeMultiTargetResults`.
    private static func groupByMutation(_ perTarget: [TargetRecord]) throws -> [GroupedMutation] {
        var order: [MutationID] = []
        var grouped: [MutationID: [TargetRecord]] = [:]
        for entry in perTarget {
            let id = entry.record.mutationRef.mutationID
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(entry)
        }
        return try order.map { id in
            let records = grouped[id]!
            let verdict = try MultiTargetVerdict(
                mutationRef: records[0].record.mutationRef,
                perTarget: records.map { TargetVerdict(targetIdentity: $0.targetIdentity, record: $0.record) }
            )
            return GroupedMutation(verdict: verdict, perTarget: records)
        }
    }

    /// Projects a mutation's aggregate outcome into a single
    /// `MutationResult` for display — the specific `TargetRecord` whose
    /// own outcome equals `aggregateOutcome` (ties broken by `perTarget`'s
    /// own deterministic, identity-sorted order), never a value computed
    /// independently of it.
    private static func projectAggregate(
        _ grouped: GroupedMutation, points: [MutationID: MutationPoint], planID: String, workUnitID: String
    ) throws -> MutationResult {
        let verdict = grouped.verdict
        // Ties broken by target identity, not by whichever chunk happened
        // to finish evaluating first: `grouped.perTarget` is orchestration
        // order (per-chunk completion), not the deterministic order
        // `verdict.perTarget` already sorts into.
        let winningIdentities = verdict.perTarget
            .filter { $0.record.outcome == verdict.aggregateOutcome }
            .map(\.targetIdentity)
        let winnerIdentity = winningIdentities.min() ?? verdict.perTarget[0].targetIdentity
        let winner = grouped.perTarget.first { $0.targetIdentity == winnerIdentity } ?? grouped.perTarget[0]
        guard let point = points[verdict.mutationRef.mutationID] else {
            preconditionFailure("no MutationPoint supplied for embedded mutation \(verdict.mutationRef.mutationID.rawValue)")
        }
        return try MutationResult.projected(
            from: winner.record, point: point, planID: planID, workUnitID: workUnitID,
            durationSeconds: winner.durationSeconds, testDurationSeconds: winner.testDurationSeconds
        )
    }

    // MARK: - Baseline

    private func establishBaseline() async throws -> BaselineRecord {
        let started = Date()
        let sandbox = try await workspaces.createSandbox(id: "schemata-baseline")
        do {
            let record = try await establishBaseline(in: sandbox, startedAt: started)
            try? await workspaces.destroySandbox(at: sandbox)
            return record
        } catch {
            try? await workspaces.destroySandbox(at: sandbox)
            throw error
        }
    }

    private func establishBaseline(in sandbox: URL, startedAt started: Date) async throws -> BaselineRecord {
        let artifact = try await build.buildBaseline(in: sandbox)
        let testStarted = Date()
        let run = try await test.runBaseline(artifact, in: sandbox, timeoutSeconds: timeoutSeconds)

        return BaselineRecord(
            passed: run.status == .passed,
            testSummary: run.summary,
            durationSeconds: Date().timeIntervalSince(started),
            buildProductHash: artifact.productHash,
            buildCommand: artifact.command,
            testCommand: run.command,
            buildDurationSeconds: testStarted.timeIntervalSince(started),
            testDurationSeconds: Date().timeIntervalSince(testStarted)
        )
    }

    // MARK: - Per chunk

    private func runChunk(_ program: SchemataProgram) async -> [EntryRunOutcome] {
        let embeddedEntries = program.entries.filter(\.isEmbedded)
        guard !embeddedEntries.isEmpty else { return [] }

        let sandbox: URL
        do {
            sandbox = try await workspaces.createSandbox(id: program.chunkID)
        } catch {
            return embeddedEntries.compactMap {
                infrastructureFailureResult(for: $0, reason: "the chunk sandbox could not be created: \(error)")
            }.map(EntryRunOutcome.verified)
        }

        let results = await runChunk(program, entries: embeddedEntries, in: sandbox)
        try? await workspaces.destroySandbox(at: sandbox)
        return results
    }

    private func runChunk(
        _ program: SchemataProgram, entries embeddedEntries: [SchemataPlanEntry], in sandbox: URL
    ) async -> [EntryRunOutcome] {
        let artifact: BuildArtifact
        do {
            artifact = try await build.buildSchemataChunk(loweredSources: program.loweredSources, in: sandbox)
        } catch let failure as BuildFailure {
            return embeddedEntries.compactMap { buildFailureResult(for: $0, kind: failure.kind, diagnosis: failure.diagnosis) }
                .map(EntryRunOutcome.verified)
        } catch {
            return embeddedEntries.compactMap {
                infrastructureFailureResult(for: $0, reason: "the chunk build could not be run: \(error)")
            }.map(EntryRunOutcome.verified)
        }

        guard artifact.productHash != nil else {
            return embeddedEntries.compactMap {
                infrastructureFailureResult(
                    for: $0, reason: "the chunk build produced no product hash, so its evidence cannot be trusted"
                )
            }.map(EntryRunOutcome.verified)
        }

        // Real per-compilation-unit, per-image LC_UUID identity (ADR-0006
        // Finding 2/4's build-time half) — resolved through the build
        // system's own metadata (`SwiftPMCompilationUnitImageResolver`'s
        // dependency-graph reachability, or Xcode's per-target build
        // settings), never through a target-name substring match. A
        // request this stage cannot build (a malformed/missing
        // `sourceEmbeddingID` or lowerer identity on the entry itself) is
        // simply left unresolved for that one entry — `expectedImageUUIDs`
        // below falls back to the product-hash placeholder for it, the
        // same "not proven, not guessed" discipline the rest of this
        // pipeline already uses for an ambiguous mapping.
        var requestsByMutationID: [MutationID: SchemataCompilationUnitTargetRequest] = [:]
        for entry in embeddedEntries {
            guard
                let point = points[entry.mutationID],
                let sourceEmbeddingIDString = entry.sourceEmbeddingID,
                let sourceEmbeddingID = SHA256Digest(rawValue: sourceEmbeddingIDString),
                let lowererID = entry.lowererID,
                let lowererVersion = entry.lowererVersion
            else { continue }

            let compilationUnitID = CompilationUnitID.derive(
                projectIdentity: entry.projectIdentity, target: entry.target, module: entry.module,
                sourcePath: point.file, lowererID: lowererID, lowererVersion: lowererVersion
            )
            requestsByMutationID[entry.mutationID] = SchemataCompilationUnitTargetRequest(
                compilationUnitID: compilationUnitID,
                sourceEmbeddingID: sourceEmbeddingID,
                buildTarget: BuildTargetIdentity(projectIdentity: entry.projectIdentity, targetName: entry.target, moduleName: entry.module)
            )
        }

        // Two mutations in the same file (same target/module/lowerer) share
        // one compilation unit — `SchemataBuildReceipt` rightly refuses a
        // duplicate `CompilationUnitID`, so the request list passed to the
        // resolver is deduplicated by that ID before the call, not per
        // mutation.
        var uniqueRequestsByUnit: [CompilationUnitID: SchemataCompilationUnitTargetRequest] = [:]
        for request in requestsByMutationID.values {
            uniqueRequestsByUnit[request.compilationUnitID] = request
        }

        let receiptContext = SchemataBuildReceiptContext(
            planID: planID, workUnitID: workUnitID, chunkID: program.chunkID,
            toolchainHash: toolchainHash, buildArgumentsHash: buildArgumentsHash
        )
        let receipt: SchemataBuildReceipt? = try? await build.resolveSchemataBuildReceipt(
            for: Array(uniqueRequestsByUnit.values), artifact: artifact, in: sandbox, context: receiptContext
        )

        var results: [EntryRunOutcome] = []
        for entry in embeddedEntries {
            results.append(
                await runEntry(entry, artifact: artifact, receipt: receipt, in: sandbox)
            )
        }
        return results
    }

    /// The same derivation `runChunk`'s build-receipt resolution and the
    /// lowerer itself (`BoolLiteralSchemataLowerer.lower`) use — real
    /// compilation-unit identity, never a placeholder. Computed directly
    /// from `entry`/`point` (not read back from `runChunk`'s own per-entry
    /// request map) so this holds even for an entry that map left
    /// unresolved (a malformed `sourceEmbeddingID`, say): the chain check
    /// still has a real, derived unit to check the runtime's own report
    /// against, exactly mirroring `embeddingEvidence`'s existing
    /// `entry.lowererID ?? "unknown"` fallback discipline.
    private static func compilationUnitID(for entry: SchemataPlanEntry, point: MutationPoint) -> CompilationUnitID {
        CompilationUnitID.derive(
            projectIdentity: entry.projectIdentity, target: entry.target, module: entry.module,
            sourcePath: point.file, lowererID: entry.lowererID ?? "unknown", lowererVersion: entry.lowererVersion ?? 0
        )
    }

    private static func targetIdentity(for entry: SchemataPlanEntry) -> TargetExecutionIdentity {
        TargetExecutionIdentity(
            projectIdentity: entry.projectIdentity, target: entry.target, module: entry.module, product: entry.product
        )
    }

    /// Mirrors `MutationRunner.finalize` (ADR-0006 Stage 1): the schemata
    /// path's single choke point from raw observations to a verified
    /// record. Unlike `MutationRunner`, this returns the
    /// `VerifiedMutationRecord` itself rather than a projected
    /// `MutationResult` — `run()` needs every target's own record intact
    /// to build `MultiTargetVerdict`s before any one of them is picked for
    /// display.
    private func finalize(
        point: MutationPoint,
        sourceApplication: SourceApplicationOutcome? = nil,
        build: BuildObservation? = nil,
        test: SingleTestObservation? = nil,
        confirmations: [ConfirmationObservation] = [],
        infrastructureFailureDiagnosis: String? = nil
    ) -> VerifiedMutationRecord {
        let ref = PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID)
        let observations = MutationObservations(
            plannedMutation: ref,
            sourceApplication: sourceApplication,
            build: build,
            coverage: nil,
            test: test,
            confirmations: confirmations,
            infrastructureFailureDiagnosis: infrastructureFailureDiagnosis
        )
        return MutationVerdictVerifier.verify(observations, policy: policy)
    }

    /// The same `MutationObservations` shape `finalize` will eventually
    /// verify, built early so `runEntry` can ask `MutationVerdictVerifier
    /// .confirmationRequirement` whether a confirmation is needed *before*
    /// deciding to gather one — mirrors `finalize`'s own construction
    /// exactly (confirmations always empty here; that is the question this
    /// exists to answer, not something it can already know).
    private func preliminaryObservations(
        point: MutationPoint, sourceApplication: SourceApplicationOutcome, build: BuildObservation, test: SingleTestObservation
    ) -> MutationObservations {
        MutationObservations(
            plannedMutation: PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID),
            sourceApplication: sourceApplication, build: build, coverage: nil, test: test
        )
    }

    // MARK: - Per mutant

    /// Collects raw observations only (ADR-0006 Stage 2) — this runner
    /// decides nothing about whether the mutation was proven built,
    /// selected, or hit. It runs the process, reads back whatever
    /// transcript it wrote (however empty or malformed), and hands the
    /// whole unfiltered result to `MutationVerdictVerifier
    /// .verifySchemataChain` inside a `SchemataExecutionObservation` —
    /// the only place that chain is ever built or judged.
    private func runEntry(
        _ entry: SchemataPlanEntry, artifact: BuildArtifact, receipt: SchemataBuildReceipt?, in sandbox: URL
    ) async -> EntryRunOutcome {
        // `token`/`sourceEmbeddingID` are always non-nil here: `entries` was
        // already filtered to `isEmbedded` entries by the caller, and both
        // are only ever `nil` for `.isolatedFallback` placements. `point`
        // is a caller contract, not a runtime condition: `points` must
        // cover every `MutationID` in `programs`, the same completeness
        // `SchemataPlan.decodeAndValidate` already enforces between a plan
        // and its entries.
        guard
            let token = entry.selectorToken, let sourceEmbeddingIDString = entry.sourceEmbeddingID,
            let sourceEmbeddingID = SHA256Digest(rawValue: sourceEmbeddingIDString)
        else {
            preconditionFailure("a schemata-embedded entry must carry a selector token and source embedding ID")
        }
        guard let point = points[entry.mutationID] else {
            preconditionFailure("no MutationPoint supplied for embedded mutation \(entry.mutationID.rawValue)")
        }
        let compilationUnitID = Self.compilationUnitID(for: entry, point: point)

        let started = Date()
        let runID = RunID()
        let evidenceDirectory = sandbox.appendingPathComponent(".mutantkit-schemata/\(entry.mutationID.rawValue)")
        let transcriptPath = evidenceDirectory.appendingPathComponent("transcript.bin")
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }

        let testStarted = Date()
        let run: TestRunResult
        do {
            run = try await runSchemataToken(artifact, in: sandbox, token: token, transcriptPath: transcriptPath, runID: runID)
        } catch {
            return .verified(TargetRecord(
                targetIdentity: Self.targetIdentity(for: entry),
                record: finalize(point: point, infrastructureFailureDiagnosis: "the test process could not be run: \(error)"),
                durationSeconds: Date().timeIntervalSince(started),
                testDurationSeconds: nil
            ))
        }

        let expectation = SchemataRunExpectation(
            mutationID: entry.mutationID, compilationUnitID: compilationUnitID, sourceEmbeddingID: sourceEmbeddingID,
            selectorToken: token, runID: runID
        )
        let observation = schemataObservation(transcriptPath: transcriptPath, expectation: expectation, receipt: receipt)

        let sourceLevel = sourceLevelEvidence(for: point)
        let evidence = MutationEvidence(
            sourceBeforeHash: sourceLevel.beforeHash,
            sourceAfterHash: sourceLevel.afterHash,
            sourceDiff: sourceLevel.diff,
            buildProductHash: artifact.productHash,
            applicationEvidence: .schemata(observation),
            buildCommand: artifact.command,
            testCommand: run.command
        )
        let buildObservation = BuildObservation(outcome: .succeeded(buildProductHash: artifact.productHash, command: artifact.command))
        let testObservation = SingleTestObservation(run: run, applicationEvidence: .schemata(observation))

        // The same single source of truth `MutationRunner`'s own
        // confirmation gates ultimately encode — never a policy check this
        // runner re-derives on its own (ADR-0006 Stage 3).
        //
        // Never a cascade of more than one confirmation, unlike
        // `MutationRunner.confirmTimeout`'s own nested `retestKilledMutants`/
        // `confirmCrashKills` calls: that cascade only fires for a
        // *batch-attributed* timeout (`TestRunResult.isBatchAttributedTimeout`,
        // set only by `runBatch`) whose confirming rebuild turns out to be a
        // real kill/crash. This runner never batches at all — one fresh
        // process per embedded mutation, no exception — so a schemata
        // timeout's own `isBatchAttributedTimeout` is always `false`, and
        // `MutationVerdictVerifier.confirmTimeout`'s cascade branch is
        // structurally unreachable here: a schemata timeout confirmation
        // that finishes normally is `.flaky`, exactly like isolated mode's
        // own non-batch-attributed case, never promoted to a kill — proven
        // by `SchemataConfirmationVerifierTests
        // .timeoutConfirmationFinishingNormallyIsFlakyNotCascaded`. There is
        // therefore no second confirmation for this runner to ever gather.
        let preliminary = preliminaryObservations(
            point: point, sourceApplication: .applied(evidence), build: buildObservation, test: testObservation
        )

        // Checked before `confirmationRequirement` is even asked (Group 2:
        // no-HIT/no-STARTUP -> isolated fallback): a passing test with no
        // proof this mutation was ever selected/hit gets no confirmation
        // gathered and no `finalize` call here at all — `run()` drops
        // every target placement for this MutationID and
        // `SchemataRunOrchestration` re-runs it through isolated mode from
        // scratch, which will build its own, independent proof chain.
        // Never widen this beyond what `schemataIsolatedFallbackReason`
        // itself already scopes to (see that function's own doc comment).
        if let reason = MutationVerdictVerifier.schemataIsolatedFallbackReason(for: preliminary) {
            return .isolatedFallback(mutationID: entry.mutationID, reason: reason)
        }

        let requirement = MutationVerdictVerifier.confirmationRequirement(for: preliminary, policy: policy)
        var confirmations: [ConfirmationObservation] = []
        if requirement != .none {
            let request = ConfirmationRequest(
                mutationID: entry.mutationID, compilationUnitID: compilationUnitID, sourceEmbeddingID: sourceEmbeddingID,
                token: token, receipt: receipt, originalFailingTests: run.summary?.failingTests, originalDiagnosis: run.diagnosis
            )
            confirmations.append(await confirmSchemataToken(requirement, artifact: artifact, request: request, in: sandbox))
        }

        let record = finalize(
            point: point,
            sourceApplication: .applied(evidence),
            build: buildObservation,
            test: testObservation,
            confirmations: confirmations
        )
        return .verified(TargetRecord(
            targetIdentity: Self.targetIdentity(for: entry),
            record: record,
            durationSeconds: Date().timeIntervalSince(started),
            testDurationSeconds: Date().timeIntervalSince(testStarted)
        ))
    }

    private struct SourceLevelEvidence {
        let beforeHash: String
        let afterHash: String
        let diff: String
    }

    private func sourceLevelEvidence(for point: MutationPoint) -> SourceLevelEvidence {
        guard let original = originalSources[point.file], let applied = try? MutationApplication.apply(point, to: original) else {
            return SourceLevelEvidence(beforeHash: point.sourceFileHash, afterHash: point.sourceFileHash, diff: "")
        }
        return SourceLevelEvidence(
            beforeHash: applied.evidence.sourceBeforeHash, afterHash: applied.evidence.sourceAfterHash, diff: applied.evidence.sourceDiff
        )
    }

    /// Used only where an entry's own `MutationPoint` may genuinely be
    /// absent (a chunk-level build/sandbox failure, before any per-mutant
    /// work starts) — `nil` when `points` has no entry for it, so the
    /// `compactMap` call sites drop it rather than fabricate a result with
    /// no anchor.
    private func infrastructureFailureResult(for entry: SchemataPlanEntry, reason: String, startedAt: Date = Date()) -> TargetRecord? {
        guard let point = points[entry.mutationID] else { return nil }
        return TargetRecord(
            targetIdentity: Self.targetIdentity(for: entry),
            record: finalize(
                point: point, sourceApplication: chunkLevelSourceApplication(for: point), infrastructureFailureDiagnosis: reason
            ),
            durationSeconds: Date().timeIntervalSince(startedAt),
            testDurationSeconds: nil
        )
    }

    private func buildFailureResult(
        for entry: SchemataPlanEntry, kind: BuildFailureKind, diagnosis: String, startedAt: Date = Date()
    ) -> TargetRecord? {
        guard let point = points[entry.mutationID] else { return nil }
        return TargetRecord(
            targetIdentity: Self.targetIdentity(for: entry),
            record: finalize(
                point: point,
                sourceApplication: chunkLevelSourceApplication(for: point),
                build: BuildObservation(outcome: .failed(kind: kind, diagnosis: diagnosis, command: nil), durationSeconds: nil)
            ),
            durationSeconds: Date().timeIntervalSince(startedAt),
            testDurationSeconds: nil
        )
    }

    /// The chunk itself failed to build or produced no product hash, so no
    /// per-mutant test ever ran — but the source-level fact that this
    /// mutation was applied to the chunk's sources is still real and
    /// computable from `originalSources`, so it is honestly reported
    /// rather than omitted.
    private func chunkLevelSourceApplication(for point: MutationPoint) -> SourceApplicationOutcome {
        let sourceLevel = sourceLevelEvidence(for: point)
        return .applied(MutationEvidence(
            sourceBeforeHash: sourceLevel.beforeHash,
            sourceAfterHash: sourceLevel.afterHash,
            sourceDiff: sourceLevel.diff,
            buildProductHash: nil,
            applicationEvidence: nil,
            buildCommand: nil,
            testCommand: nil
        ))
    }
}

// MARK: - Confirmation gathering (ADR-0006 Stage 3)

private extension SchemataMutationRunner {
    /// Runs one already-built chunk's runtime against `token`, under its own
    /// fresh `runID`/`transcriptPath` — the one place `runEntry` and
    /// `confirmSchemataToken` both launch a schemata process, so a primary
    /// run and its confirmation are built from an identical invocation
    /// shape and can never drift apart from each other by accident.
    func runSchemataToken(
        _ artifact: BuildArtifact, in sandbox: URL, token: SchemataSelectorToken, transcriptPath: URL, runID: RunID
    ) async throws -> TestRunResult {
        try await test.runSchemataToken(
            artifact, in: sandbox, timeoutSeconds: timeoutSeconds,
            environment: [
                SchemataEvidenceCollector.tokenEnvironmentVariable: SchemataEvidenceCollector.tokenEnvironmentValue(for: token),
                SchemataEvidenceCollector.transcriptPathEnvironmentVariable: transcriptPath.path,
                SchemataEvidenceCollector.runIDEnvironmentVariable: SchemataEvidenceCollector.runIDEnvironmentValue(for: runID)
            ]
        )
    }

    /// Reads back whatever `runSchemataToken` actually wrote — empty (no
    /// transcript at all, malformed data) becomes an empty transcript,
    /// never a thrown error either caller has to handle specially: an
    /// empty transcript already fails the verifier's chain closed on its
    /// own.
    func schemataObservation(
        transcriptPath: URL, expectation: SchemataRunExpectation, receipt: SchemataBuildReceipt?
    ) -> SchemataExecutionObservation {
        let transcript = (try? SchemataEvidenceCollector.readTranscript(at: transcriptPath))
            ?? RuntimeTranscript(protocolVersion: 0, records: [])
        return SchemataExecutionObservation(expectation: expectation, buildReceipt: receipt, transcript: transcript)
    }

    /// Everything a confirmation attempt needs about the mutation it is
    /// confirming, bundled so `confirmSchemataToken` takes one thing rather
    /// than re-threading each of these individually through its own
    /// parameter list.
    struct ConfirmationRequest {
        let mutationID: MutationID
        let compilationUnitID: CompilationUnitID
        let sourceEmbeddingID: SHA256Digest
        let token: SchemataSelectorToken
        let receipt: SchemataBuildReceipt?
        let originalFailingTests: [String]?
        let originalDiagnosis: String
    }

    /// Runs a genuinely independent confirmation attempt for `request`'s
    /// mutation — its own fresh `RunID`, its own transcript file, its own
    /// test process, requesting the exact same token against the exact
    /// same already-built artifact (ADR-0006 Stage 3): schemata mode never
    /// rebuilds to confirm, since the chunk's build already embeds every
    /// mutation and confirming is only ever a question of whether the
    /// runtime independently reaches and reports the same site again.
    /// Never reuses the primary run's own transcript, `RunID`, or process —
    /// `MutationVerdictVerifier.confirm` independently verifies this
    /// confirmation's own chain and refuses one that reused the original
    /// `RunID` (see `schemataConfirmationChainProblem`), so a shortcut here
    /// would only ever be caught downstream, never silently trusted.
    func confirmSchemataToken(
        _ requirement: ConfirmationRequirement, artifact: BuildArtifact, request: ConfirmationRequest, in sandbox: URL
    ) async -> ConfirmationObservation {
        let kind: ConfirmationObservation.Kind = switch requirement {
        case .retestKilledMutant: .kill
        case .confirmCrash: .crash
        case .confirmTimeout: .timeout
        case .none: preconditionFailure("confirmSchemataToken must never be called for .none")
        }

        let runID = RunID()
        let evidenceDirectory = sandbox
            .appendingPathComponent(".mutantkit-schemata/\(request.mutationID.rawValue)-confirm-\(runID.rawValue.uuidString)")
        let transcriptPath = evidenceDirectory.appendingPathComponent("transcript.bin")
        try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }

        let run: TestRunResult
        do {
            run = try await runSchemataToken(artifact, in: sandbox, token: request.token, transcriptPath: transcriptPath, runID: runID)
        } catch {
            return ConfirmationObservation(
                kind: kind, run: Self.infrastructureFailureRun("the confirmation process could not be run: \(error)"),
                originalFailingTests: request.originalFailingTests, originalDiagnosis: request.originalDiagnosis
            )
        }

        let expectation = SchemataRunExpectation(
            mutationID: request.mutationID, compilationUnitID: request.compilationUnitID, sourceEmbeddingID: request.sourceEmbeddingID,
            selectorToken: request.token, runID: runID
        )
        let observation = schemataObservation(transcriptPath: transcriptPath, expectation: expectation, receipt: request.receipt)
        return ConfirmationObservation(
            kind: kind, run: run, schemataObservation: observation,
            originalFailingTests: request.originalFailingTests, originalDiagnosis: request.originalDiagnosis
        )
    }

    /// A synthetic run standing in for "a confirmation attempt could not
    /// even launch" — mirrors `MutationRunner.infrastructureFailureRun`
    /// exactly, the same convention for the same reason: represented as an
    /// ordinary `TestRunResult` so it flows through `ConfirmationObservation`
    /// like any other confirming run.
    static func infrastructureFailureRun(_ diagnosis: String) -> TestRunResult {
        TestRunResult(
            status: .infrastructureFailure, summary: nil,
            command: CommandRecord(executable: "", arguments: [], workingDirectory: ""),
            resultArtifactPath: nil, diagnosis: diagnosis
        )
    }
}
