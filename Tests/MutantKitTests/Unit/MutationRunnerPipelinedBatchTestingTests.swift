import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// Integration coverage for the *pipelined* incremental+batch path
/// (`evaluateIncrementallyInBatches`'s `PipelineCoordinator` /
/// `runPipelinedBuildWorker` / `runPipelinedTestLane`), which
/// `MutationRunnerIncrementalBatchTestingTests` cannot exercise: that suite
/// runs `workers: 1`, deliberately, to make sandbox reuse deterministic to
/// assert on — but with one worker there is only ever one build loop and no
/// sibling worker to overlap with, so it can prove the pipeline still gets
/// the same *results* a single worker always got, but not that build and
/// test genuinely *overlap* across workers, nor that one worker's sandbox
/// lifetime is independent of a sibling's.
///
/// This suite uses `workers: 2` throughout and proves, via explicit
/// synchronization on spies (never a sleep-based race), that:
///  - a batch is tested for one worker's clone while a sibling worker's
///    build is still genuinely in progress, in call order, not just in the
///    final results (`batchFiresWhileASiblingWorkerIsStillBuilding`);
///  - a worker whose whole lifecycle (build, clone, test) is already done
///    has its own sandbox torn down without waiting for a slower sibling —
///    sandbox lifetime is tracked per worker, not behind one shared barrier
///    (same test, second half);
///  - two workers who happen to finish building at the same moment, sharing
///    one final batch, both still have their own sandboxes alive when that
///    shared batch is tested, and both are destroyed only afterward
///    (`bothWorkerSandboxesOutliveTheSharedFinalBatch`);
///  - no mutant is ever duplicated or dropped under genuine concurrent
///    pipelining, run repeatedly to make a one-off race less likely to slip
///    through unnoticed (`exactlyOnceIntegrityUnderConcurrentPipelining`);
///  - `queue.next(forWorker:)` (not the affinity-blind `queue.next()`) is
///    actually the call the pipelined build worker makes — proven by
///    showing a single worker's build order clusters by file despite the
///    plan itself (sorted by content-hash `MutationID`, not by file) being
///    interleaved (`workerAffinityClustersSameFileMutants`).
@Suite("Mutation runner: pipelined incremental build + batch testing")
struct MutationRunnerPipelinedBatchTestingTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-pipeline-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-pipeline-scratch")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0",
        toolCommitSHA: nil,
        swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2",
        xcodeVersion: nil
    )

    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    /// Writes `files.count` source files, each with a distinct struct
    /// containing `mutantCount` bool-literal fields — one `BoolLiteralInversion`
    /// mutation point per field, same shape the other incremental-build
    /// suites' fixtures use.
    private func writeProject(_ files: [(name: String, mutantCount: Int)]) throws {
        for file in files {
            let url = root.appendingPathComponent("Sources/\(file.name)")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let typeName = file.name.replacingOccurrences(of: ".swift", with: "")
            var lines = ["struct \(typeName) {"]
            for i in 0 ..< file.mutantCount {
                lines.append("    var v\(i) = \(i.isMultiple(of: 2) ? "true" : "false")")
            }
            lines.append("}")
            try Data(lines.joined(separator: "\n").utf8).write(to: url)
        }
    }

    private func makePlan(_ configuration: Configuration) async throws -> MutationPlan {
        try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
    }

    private func makeRunner(
        plan: MutationPlan, configuration: Configuration, build: any BuildAdapter, test: any TestAdapter
    ) throws -> MutationRunner {
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        return MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root, build: build, test: test, workspaces: workspaces
        )
    }

    /// Polls `condition` every 2ms until it is true or `timeout` elapses.
    /// Used instead of a fixed `Task.sleep` everywhere this suite needs to
    /// observe a concurrently-running `run()`'s progress: the common case
    /// resolves in well under a millisecond, and the generous timeout only
    /// matters if something has actually regressed (in which case the
    /// subsequent `#expect` fails with a clear message instead of hanging).
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test(
        """
        A batch is tested for one worker's clone while a sibling worker is still mid-build, \
        and the finished worker's sandbox is torn down without waiting for the slower one
        """
    )
    func batchFiresWhileASiblingWorkerIsStillBuilding() async throws {
        try writeProject([("Fast.swift", 1), ("Slow.swift", 1)])
        let configuration = Configuration(execution: ExecutionSettings(workers: 2, incrementalBuild: true, testBatchSize: 1))
        let plan = try await makePlan(configuration)
        #expect(plan.mutations.count == 2)
        let fast = try #require(plan.mutations.first { $0.file.hasSuffix("Fast.swift") })
        let slow = try #require(plan.mutations.first { $0.file.hasSuffix("Slow.swift") })

        let log = CallLog()
        let gate = BuildGate()
        let build = GatedBuildAdapter(log: log, gate: gate, gatedIDs: [slow.id.rawValue])
        let test = GatedBatchAdapter(log: log, buildSpy: build, outcomes: [:])
        let runner = try makeRunner(plan: plan, configuration: configuration, build: build, test: test)

        async let reportTask = runner.run()

        // Wait for the slow worker to have actually entered its build (and
        // therefore be sitting on the gate, blocked) before looking for
        // anything downstream of it.
        await waitUntil {
            await log.events.contains { if case .buildStarted(slow.id.rawValue) = $0 { true } else { false } }
        }
        #expect(
            await log.events.contains { if case .buildStarted(slow.id.rawValue) = $0 { true } else { false } },
            "timed out waiting for the slow worker's build to start"
        )

        // Wait for the fast worker's single clone to have been tested as
        // its own batch (testBatchSize: 1 makes this immediate, not
        // dependent on a second clone ever arriving).
        await waitUntil {
            await log.events.contains { if case let .batch(ids) = $0 { ids == [fast.id.rawValue] } else { false } }
        }
        #expect(
            await log.events.contains { if case let .batch(ids) = $0 { ids == [fast.id.rawValue] } else { false } },
            "timed out waiting for the fast worker's clone to be batch-tested"
        )

        // At this exact point in the test's own control flow, the only
        // thing that can unblock the slow worker's build (`gate.release`)
        // has not been called yet — so the slow worker is *provably* still
        // mid-build right now, while the fast worker's whole lifecycle
        // (build, clone, test, sandbox teardown) has had the chance to run
        // to completion concurrently with it.
        let fastSandbox = try #require(await build.buildMutantCalls.first { $0.mutationID == fast.id.rawValue }?.workspace)
        let slowSandbox = try #require(await build.buildMutantCalls.first { $0.mutationID == slow.id.rawValue }?.workspace)
        #expect(
            FileManager.default.fileExists(atPath: slowSandbox.path),
            "the slow worker's own sandbox must still be alive while its build is still in progress"
        )
        await waitUntil { !FileManager.default.fileExists(atPath: fastSandbox.path) }
        #expect(
            FileManager.default.fileExists(atPath: fastSandbox.path) == false,
            """
            the fast worker's sandbox should already be torn down -- its build finished and its one clone \
            was already tested -- without waiting for the slower sibling worker, which proves sandbox \
            lifetime is tracked per worker, not behind one barrier shared by every worker
            """
        )

        await gate.release(slow.id.rawValue)
        let report = try await reportTask

        #expect(report.results.count == 2)
        #expect(report.integrity.violations.isEmpty)
        #expect(Set(report.results.map(\.id)).count == 2, "no mutant should be duplicated")

        let events = await log.events
        let batchFastIndex = try #require(
            events.firstIndex { if case let .batch(ids) = $0 { ids == [fast.id.rawValue] } else { false } }
        )
        let buildFinishedSlowIndex = try #require(
            events.firstIndex { if case .buildFinished(slow.id.rawValue) = $0 { true } else { false } }
        )
        #expect(
            batchFastIndex < buildFinishedSlowIndex,
            "the fast worker's clone must be tested before the slow worker's build finishes, or build and test never actually overlapped: \(events)"
        )
    }

    @Test(
        """
        Two workers finishing their builds at the same moment share one final batch; \
        both sandboxes stay alive through it and are destroyed only afterward
        """
    )
    func bothWorkerSandboxesOutliveTheSharedFinalBatch() async throws {
        try writeProject([("A.swift", 1), ("B.swift", 1)])
        // A batch size larger than the whole plan means the test lane can
        // only ever flush once, after `coordinator.receive()` returns nil —
        // which cannot happen until *every* worker has already called
        // `workerBuildFinished`. So by construction, both workers' build
        // loops are guaranteed to have already ended by the moment the one
        // and only `runBatch` call happens.
        //
        // `selectCoveringTests` is on, with real (if minimal) per-test
        // coverage: without narrow attribution, both mutants would have
        // `selectedTests == nil` and — correctly — never share a batch at
        // all (unattributed mutants are never bundled together, the same
        // invariant `Self.chunked` enforces on the non-pipelined path).
        // This test's whole point is the *shared*-batch sandbox-lifetime
        // case, which needs both mutants to be batchable together for real.
        let configuration = Configuration(
            execution: ExecutionSettings(workers: 2, selectCoveringTests: true, incrementalBuild: true, testBatchSize: 10)
        )
        let plan = try await makePlan(configuration)
        #expect(plan.mutations.count == 2)
        let points = plan.mutations.sorted { $0.id < $1.id }

        let testA = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testA")
        let testB = TestIdentifier(target: "FakeTests", qualifiedName: "SomeClass/testB")
        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        coveringTests[points[0].file, default: [:]][points[0].line] = [testA]
        coveringTests[points[1].file, default: [:]][points[1].line] = [testB]
        let coverage = PerTestCoverageMap(coveringTests: coveringTests, source: "test")

        let idA = points[0].id.rawValue
        let idB = points[1].id.rawValue

        let log = CallLog()
        let gate = BuildGate()
        let build = GatedBuildAdapter(log: log, gate: gate, gatedIDs: [idA, idB])
        let test = GatedBatchAdapter(log: log, buildSpy: build, outcomes: [:], perTestCoverage: coverage)
        let runner = try makeRunner(plan: plan, configuration: configuration, build: build, test: test)

        async let reportTask = runner.run()

        // Both mutation IDs are gated, so neither `buildMutant` call can
        // return until this test releases it below. A single worker's own
        // build loop is strictly sequential -- it cannot start a second
        // `buildMutant` call while its first one is still blocked on the
        // gate. So observing *both* `buildStarted` events, with neither
        // `buildFinished` yet, is a deterministic proof that two
        // independently-scheduled worker loops each picked up one mutant --
        // not a snapshot taken after the whole run finished, which cannot
        // distinguish that from one worker racing ahead and draining the
        // queue before its sibling was ever scheduled (both leave the same
        // two-workspace footprint by the time the run completes).
        await waitUntil {
            let events = await log.events
            return events.contains { if case .buildStarted(idA) = $0 { true } else { false } }
                && events.contains { if case .buildStarted(idB) = $0 { true } else { false } }
        }
        let startedEvents = await log.events
        #expect(
            startedEvents.contains { if case .buildStarted(idA) = $0 { true } else { false } },
            "timed out waiting for both workers' builds to start"
        )
        #expect(startedEvents.contains { if case .buildStarted(idB) = $0 { true } else { false } })
        #expect(
            !startedEvents.contains { if case .buildFinished(idA) = $0 { true } else { false } },
            "the build for \(idA) must still be blocked on the gate here, or the two builds were never proven concurrent"
        )
        #expect(!startedEvents.contains { if case .buildFinished(idB) = $0 { true } else { false } })

        let inFlightCalls = await build.buildMutantCalls
        let workerSandboxes = Set(inFlightCalls.map(\.workspace))
        #expect(
            workerSandboxes.count == 2,
            "both mutants' builds are in flight at once in genuinely different sandboxes, proving two independent worker loops rather than one worker serially draining the queue: \(inFlightCalls)"
        )

        await gate.release(idA)
        await gate.release(idB)
        let report = try await reportTask

        #expect(report.results.count == 2)
        #expect(report.integrity.violations.isEmpty)

        let batchCalls = await test.runBatchCalls
        #expect(batchCalls.count == 1, "a batch size larger than the plan should produce exactly one final batch: \(batchCalls)")
        #expect(batchCalls.first?.count == 2)

        let aliveDuringBatch = await log.events.compactMap { event -> Bool? in
            if case let .sandboxAliveDuringBatch(_, alive) = event { return alive }
            return nil
        }
        #expect(aliveDuringBatch.count == 2, "expected one alive-check per mutant in the shared batch")
        #expect(
            aliveDuringBatch.allSatisfy { $0 },
            "both workers' own sandboxes must still be alive when their shared final batch is tested"
        )

        for sandbox in workerSandboxes {
            #expect(
                FileManager.default.fileExists(atPath: sandbox.path) == false,
                "every worker's sandbox must be destroyed once the run has fully finished"
            )
        }
    }

    @Test("No mutant is ever duplicated or dropped under genuine multi-worker pipelining, across repeated runs")
    func exactlyOnceIntegrityUnderConcurrentPipelining() async throws {
        for iteration in 0 ..< 5 {
            let iterationRoot = root.appendingPathComponent("iter-\(iteration)")
            let iterationScratch = scratchRoot.appendingPathComponent("iter-\(iteration)")
            try FileManager.default.createDirectory(at: iterationRoot, withIntermediateDirectories: true)

            for file in [("F1.swift", 3), ("F2.swift", 3), ("F3.swift", 3), ("F4.swift", 3)] {
                let url = iterationRoot.appendingPathComponent("Sources/\(file.0)")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let typeName = file.0.replacingOccurrences(of: ".swift", with: "")
                var lines = ["struct \(typeName) {"]
                for i in 0 ..< file.1 {
                    lines.append("    var v\(i) = \(i.isMultiple(of: 2) ? "true" : "false")")
                }
                lines.append("}")
                try Data(lines.joined(separator: "\n").utf8).write(to: url)
            }

            let configuration = Configuration(execution: ExecutionSettings(workers: 4, incrementalBuild: true, testBatchSize: 3))
            let plan = try await MutationPlanner().makePlan(
                configuration: configuration, projectRoot: iterationRoot, toolchain: toolchain, diffScope: nil
            )
            #expect(plan.mutations.count == 12)

            let log = CallLog()
            // Small, jittered artificial delays on both the build and test
            // side push execution away from "one worker races ahead and
            // finishes the whole plan before any other worker gets
            // scheduled" and toward the actually-concurrent interleaving
            // this suite exists to stress -- real Task scheduling, not a
            // sequence of mocked calls that merely look concurrent.
            let build = GatedBuildAdapter(log: log, jitterMicroseconds: 200 ... 2000)
            let test = GatedBatchAdapter(log: log, buildSpy: build, outcomes: [:], jitterMicroseconds: 200 ... 2000)
            let workspaces = try WorkspaceManager(projectRoot: iterationRoot, scratchRoot: iterationScratch)
            let runner = MutationRunner(
                plan: plan, configuration: configuration, projectRoot: iterationRoot,
                build: build, test: test, workspaces: workspaces
            )
            let report = try await runner.run()

            #expect(report.results.count == plan.mutations.count, "iteration \(iteration): wrong result count")
            #expect(report.integrity.violations.isEmpty, "iteration \(iteration): \(report.integrity.violations)")
            let resultIDs = report.results.map(\.id)
            #expect(Set(resultIDs).count == resultIDs.count, "iteration \(iteration): a mutant was duplicated")
            #expect(Set(resultIDs) == Set(plan.mutations.map(\.id)), "iteration \(iteration): a mutant was dropped")
        }
    }

    @Test("A single worker exhausts one file's mutants before switching, despite the plan's content-hash-sorted order interleaving files")
    func workerAffinityClustersSameFileMutants() async throws {
        try writeProject([("A.swift", 3), ("B.swift", 3)])
        let configuration = Configuration(execution: ExecutionSettings(workers: 1, incrementalBuild: true, testBatchSize: 10))
        let plan = try await makePlan(configuration)
        #expect(plan.mutations.count == 6)

        // Sanity check on the fixture itself: `MutationPlan.mutations` is
        // sorted by content-hash `MutationID`, not by file (see
        // `MutationPlanner`'s `outcome.points.sort { $0.id < $1.id }`), so
        // it is *not* expected to already be file-clustered. If it somehow
        // were, the assertion below would pass trivially and prove nothing
        // about affinity actually doing work.
        let planFiles = plan.mutations.map(\.file)
        let planSwitches = zip(planFiles, planFiles.dropFirst()).filter { $0 != $1 }.count
        #expect(planSwitches > 1, "test fixture must produce an interleaved plan to exercise affinity meaningfully; got \(planFiles)")

        let log = CallLog()
        let build = GatedBuildAdapter(log: log)
        let test = GatedBatchAdapter(log: log, buildSpy: build, outcomes: [:])
        let runner = try makeRunner(plan: plan, configuration: configuration, build: build, test: test)
        let report = try await runner.run()

        #expect(report.results.count == 6)
        #expect(report.integrity.violations.isEmpty)

        let idToFile = Dictionary(uniqueKeysWithValues: plan.mutations.map { ($0.id.rawValue, $0.file) })
        let builtFiles = await build.buildMutantCalls.compactMap { idToFile[$0.mutationID] }
        #expect(builtFiles.count == 6)
        let builtSwitches = zip(builtFiles, builtFiles.dropFirst()).filter { $0 != $1 }.count
        #expect(
            builtSwitches == 1,
            "affinity should cluster same-file builds into one switch (all of one file, then all of the other); got \(builtSwitches) switches in \(builtFiles)"
        )
    }
}

// MARK: - Fakes

private actor CallLog {
    enum Event: Equatable {
        case buildStarted(String)
        case buildFinished(String)
        case batch([String])
        /// Recorded from inside `GatedBatchAdapter.runBatch`: whether the
        /// owning worker's own persistent sandbox still existed on disk at
        /// the moment this item's batch test call ran.
        case sandboxAliveDuringBatch(id: String, alive: Bool)
    }

    private(set) var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }
}

/// Lets a test block a specific mutation ID's `buildMutant` call until the
/// test explicitly releases it — the deterministic alternative to a
/// sleep-based race for proving "this worker's build is still genuinely in
/// progress right now".
private actor BuildGate {
    private var released: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func release(_ id: String) {
        released.insert(id)
        if let list = waiters.removeValue(forKey: id) {
            for continuation in list { continuation.resume() }
        }
    }

    func wait(for id: String) async {
        if released.contains(id) { return }
        await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }
}

private actor GatedBuildAdapter: BuildAdapter {
    private let log: CallLog
    private let gate: BuildGate?
    private let gatedIDs: Set<String>
    private let jitterMicroseconds: ClosedRange<UInt64>?
    private(set) var buildMutantCalls: [(workspace: URL, mutationID: String)] = []

    init(
        log: CallLog,
        gate: BuildGate? = nil,
        gatedIDs: Set<String> = [],
        jitterMicroseconds: ClosedRange<UInt64>? = nil
    ) {
        self.log = log
        self.gate = gate
        self.gatedIDs = gatedIDs
        self.jitterMicroseconds = jitterMicroseconds
    }

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace,
            productHash: "baseline-hash",
            xctestrunPath: workspace.appendingPathComponent("baseline.xctestrun"),
            command: CommandRecord(executable: "xcodebuild", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        let mutationID = mutation.point.id.rawValue
        buildMutantCalls.append((workspace, mutationID))
        await log.record(.buildStarted(mutationID))

        if let jitterMicroseconds {
            try? await Task.sleep(nanoseconds: UInt64.random(in: jitterMicroseconds) * 1000)
        }
        if gatedIDs.contains(mutationID) {
            await gate?.wait(for: mutationID)
        }
        await log.record(.buildFinished(mutationID))

        return BuildArtifact(
            productsDirectory: workspace,
            productHash: "mutant-hash-\(mutationID)",
            xctestrunPath: workspace.appendingPathComponent("mutant.xctestrun"),
            command: CommandRecord(executable: "xcodebuild", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

private actor GatedBatchAdapter: TestSelecting, BatchTestable, CoverageMeasuring {
    private let log: CallLog
    /// Read (never written) only to look up which worker's own persistent
    /// sandbox produced a given mutation ID's build, so `runBatch` can
    /// check whether that sandbox is still alive on disk at batch time.
    private let buildSpy: GatedBuildAdapter
    private let outcomes: [MutationID: TestRunStatus]
    private let jitterMicroseconds: ClosedRange<UInt64>?
    /// `nil` (the default) means every mutant is unattributed, exactly as
    /// `selectCoveringTests: false` would produce — which is what most of
    /// this suite's tests want, since they are not testing batching
    /// composition. Only a test that needs mutants to share a batch for
    /// real (narrow attribution required) supplies one.
    private let perTestCoverage: PerTestCoverageMap?
    private(set) var runBatchCalls: [[MutationID]] = []
    private(set) var individualRunMutantCalls: [(id: MutationID, workspace: URL)] = []

    init(
        log: CallLog,
        buildSpy: GatedBuildAdapter,
        outcomes: [MutationID: TestRunStatus],
        jitterMicroseconds: ClosedRange<UInt64>? = nil,
        perTestCoverage: PerTestCoverageMap? = nil
    ) {
        self.log = log
        self.buildSpy = buildSpy
        self.outcomes = outcomes
        self.jitterMicroseconds = jitterMicroseconds
        self.perTestCoverage = perTestCoverage
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func measurePerTestCoverage(
        artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async -> PerTestCoverageMap? { perTestCoverage }

    /// Line coverage (`.noCoverage` classification) is a separate concern
    /// from per-test attribution (`measurePerTestCoverage`, above) — this
    /// suite is not testing the former, so every mutant here is treated as
    /// reached regardless of `perTestCoverage`.
    func readCoverage(in workspace: URL, projectRoot: URL) async -> CoverageMap? { nil }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await runMutant(point, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, selectedTests: nil)
    }

    func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        individualRunMutantCalls.append((point.id, workspace))
        return Self.result(outcomes[point.id] ?? .passed)
    }

    func runBatch(
        _ items: [BatchMutantItem], in workspace: URL, timeoutSeconds: Double
    ) async -> [MutationID: TestRunResult] {
        if let jitterMicroseconds {
            try? await Task.sleep(nanoseconds: UInt64.random(in: jitterMicroseconds) * 1000)
        }

        // The direct, on-disk check for the sandbox-lifetime property this
        // suite pins down: at the moment this batch is actually tested, is
        // the sandbox that built each item's clone still alive?
        let calls = await buildSpy.buildMutantCalls
        for item in items {
            if let owner = calls.first(where: { $0.mutationID == item.id.rawValue })?.workspace {
                let alive = FileManager.default.fileExists(atPath: owner.path)
                await log.record(.sandboxAliveDuringBatch(id: item.id.rawValue, alive: alive))
            }
        }

        await log.record(.batch(items.map(\.id.rawValue)))
        runBatchCalls.append(items.map(\.id))

        var results: [MutationID: TestRunResult] = [:]
        for item in items {
            results[item.id] = Self.result(outcomes[item.id] ?? .passed)
        }
        return results
    }

    private static func result(_ status: TestRunStatus) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "xcodebuild", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil,
            diagnosis: "scripted \(status.rawValue)"
        )
    }
}
