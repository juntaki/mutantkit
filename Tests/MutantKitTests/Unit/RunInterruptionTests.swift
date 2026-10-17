@testable import CLI
import Foundation
import MutationExecution
@testable import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// Graceful interruption of `mutantkit run`: stop dispatching, keep what is
/// finished, report it as partial, resume later. None of this sends a real
/// signal — the engine is driven through its injectable `RunStopRequest`, the
/// signal handler through its `handle(signalName:)` entry point.
@Suite("Run interruption")
struct RunInterruptionTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-interrupt-project-\(UUID().uuidString)")
    private let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-interrupt-scratch-\(UUID().uuidString)")
    private let checkpointURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-interrupt-\(UUID().uuidString).jsonl")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0", toolCommitSHA: nil, swiftVersion: "6.3.3", swiftSyntaxVersion: "603.0.2", xcodeVersion: nil
    )

    private func makePlan() async throws -> MutationPlan {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("struct A { var a = true; var b = true; var c = true; var d = true }".utf8).write(to: url)
        let plan = try await MutationPlanner().makePlan(
            configuration: Configuration(), projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        try #require(plan.mutations.count >= 3)
        return plan
    }

    private func makeRunner(
        plan: MutationPlan, adapter: InterruptingTestAdapter, checkpoints: CheckpointStore, stop: RunStopRequest?
    ) throws -> MutationRunner {
        var configuration = Configuration()
        // One worker: dispatch order is then deterministic.
        configuration.execution.workers = 1
        return try MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root, build: StubBuildAdapter(), test: adapter,
            workspaces: WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot),
            checkpoints: checkpoints, stop: stop
        )
    }

    @Test("A stop request lets the running mutant finish, starts no new one, and yields a partial, scoreless report")
    func gracefulStopYieldsPartialReport() async throws {
        let plan = try await makePlan()
        let stop = RunStopRequest()
        let adapter = InterruptingTestAdapter(onFirstMutant: { stop.request(signal: "SIGINT") })
        let checkpoints = CheckpointStore(url: checkpointURL, policy: .permissive)

        let report = try await makeRunner(plan: plan, adapter: adapter, checkpoints: checkpoints, stop: stop).run()

        #expect(await adapter.mutantCalls == 1, "no new mutant may start once a stop was requested")
        #expect(report.results.count == 1, "the mutant that was running finished and is reported")
        #expect(report.interruption == RunInterruption(signal: "SIGINT", completedMutants: 1, plannedMutants: plan.mutations.count))
        #expect(report.score == nil, "a partial run never reports a score")
        #expect(!report.integrity.passed, "a partial run cannot pass integrity")
        #expect(try await checkpoints.completedIDs(plan: plan).count == 1, "the finished mutant is in the checkpoint")
    }

    @Test("Resuming after a stop runs only the remaining mutants and ends in a complete, unmarked report")
    func resumeCompletesTheRun() async throws {
        let plan = try await makePlan()
        let stop = RunStopRequest()
        let first = InterruptingTestAdapter(onFirstMutant: { stop.request(signal: "SIGTERM") })
        _ = try await makeRunner(
            plan: plan, adapter: first, checkpoints: CheckpointStore(url: checkpointURL, policy: .permissive), stop: stop
        ).run()

        let second = InterruptingTestAdapter(onFirstMutant: {})
        let report = try await makeRunner(
            plan: plan, adapter: second, checkpoints: CheckpointStore(url: checkpointURL, policy: .permissive), stop: nil
        ).run()

        #expect(await second.mutantCalls == plan.mutations.count - 1)
        #expect(report.interruption == nil)
        #expect(report.integrity.passed)
        #expect(report.results.count == plan.mutations.count)
    }

    @Test("A forced stop discards the mutant it cut short: not checkpointed, not reported")
    func forcedStopDiscardsInFlightMutant() async throws {
        let plan = try await makePlan()
        let stop = RunStopRequest()
        let adapter = InterruptingTestAdapter(onFirstMutant: {
            stop.request(signal: "SIGINT")
            stop.request(signal: "SIGINT")
        })
        let checkpoints = CheckpointStore(url: checkpointURL, policy: .permissive)

        let report = try await makeRunner(plan: plan, adapter: adapter, checkpoints: checkpoints, stop: stop).run()

        #expect(stop.phase == .forced)
        #expect(report.results.isEmpty)
        #expect(report.interruption?.completedMutants == 0)
        #expect(try await checkpoints.completedIDs(plan: plan).isEmpty, "a cut-short mutant must be re-run on resume")
    }

    @Test("A stop that arrives after the last mutant finished leaves a complete report unmarked")
    func lateStopDoesNotMarkCompleteReport() async throws {
        let plan = try await makePlan()
        let stop = RunStopRequest()
        let adapter = InterruptingTestAdapter(onFirstMutant: {})
        let runner = try makeRunner(
            plan: plan, adapter: adapter, checkpoints: CheckpointStore(url: checkpointURL, policy: .permissive), stop: stop
        )

        var report = try await runner.run()
        stop.request(signal: "SIGINT")
        report = try await makeRunner(
            plan: plan, adapter: InterruptingTestAdapter(onFirstMutant: {}),
            checkpoints: CheckpointStore(url: checkpointURL, policy: .permissive), stop: stop
        ).run()

        #expect(report.interruption == nil, "everything was already checkpointed, so nothing is partial")
        #expect(report.integrity.passed)
    }

    @Test("Further signals escalate: finish in-flight, then terminate, then exit")
    func signalHandlerEscalates() {
        let events = LockedLog()
        let stop = RunStopRequest()
        let handler = RunSignalHandler(
            stop: stop, onForce: { events.add("force") }, onAbort: { events.add("abort") }, log: { events.add($0) }
        )

        handler.handle(signalName: "SIGHUP")
        #expect(stop.phase == .graceful)
        #expect(events.entries.count == 1)
        #expect(events.entries[0].contains("no new mutants will start"))

        handler.handle(signalName: "SIGINT")
        #expect(stop.phase == .forced)
        #expect(events.entries.contains("force"))

        handler.handle(signalName: "SIGINT")
        #expect(events.entries.last == "abort")
        #expect(stop.signalName == "SIGHUP", "the report names the signal that started the interruption")
    }

    @Test("The resume command is the typed one without --no-resume, quoted for a shell")
    func resumeCommandDropsNoResume() {
        let command = RunCommand.resumeCommand(
            arguments: ["mutantkit", "run", "--no-resume", "--plan", "my plan.json", "--project-root", "/p"]
        )
        #expect(command == "mutantkit run --plan 'my plan.json' --project-root /p")
    }

    @Test("The summary says partial, names the checkpoint and the resume command; unfingerprinted runs say nothing is resumable")
    func interruptionSummaryText() async throws {
        let plan = try await makePlan()
        let stop = RunStopRequest()
        let adapter = InterruptingTestAdapter(onFirstMutant: { stop.request(signal: "SIGINT") })
        let report = try await makeRunner(
            plan: plan, adapter: adapter, checkpoints: CheckpointStore(url: checkpointURL, policy: .permissive), stop: stop
        ).run()

        let summary = try #require(RunCommand.interruptionSummary(
            report: report, stop: stop, checkpointURL: checkpointURL, arguments: ["mutantkit", "run"]
        ))
        #expect(summary.contains("PARTIAL"))
        #expect(summary.contains(checkpointURL.path))
        #expect(summary.contains("Resume with: mutantkit run"))

        let unsaved = try #require(RunCommand.interruptionSummary(
            report: report, stop: stop,
            checkpointURL: root.appendingPathComponent("checkpoint-x-unfingerprinted.jsonl"), arguments: ["mutantkit", "run"]
        ))
        #expect(!unsaved.contains("Resume with"))
        #expect(RunCommand.interruptionSummary(report: report, stop: nil, checkpointURL: checkpointURL, arguments: []) == nil)
    }

    @Test("The interruption marker survives a JSON round trip, and reports without it still decode")
    func interruptionRoundTrips() async throws {
        let plan = try await makePlan()
        let stop = RunStopRequest()
        let report = try await makeRunner(
            plan: plan, adapter: InterruptingTestAdapter(onFirstMutant: { stop.request(signal: "SIGINT") }),
            checkpoints: CheckpointStore(url: checkpointURL, policy: .permissive), stop: stop
        ).run()

        let decoded = try RunReport.decode(from: report.encoded())
        #expect(decoded.interruption == report.interruption)

        let object = try #require(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        var legacy = object
        legacy.removeValue(forKey: "interruption")
        #expect(try RunReport.decode(from: JSONSerialization.data(withJSONObject: legacy)).interruption == nil)
    }
}

@Suite("Run progress breakdown")
struct RunProgressBreakdownTests {
    @Test("Completions are broken down by what the mutants turned out to be")
    func breakdownCountsOutcomes() async {
        let started = Date(timeIntervalSince1970: 0)
        let reporter = ProgressReporter(total: 8, label: "mutants", startedAt: started, interactive: false)
        let outcomes: [MutationOutcome] = [
            .killedByAssertion, .killedByCrash, .survived, .unviable, .flaky, .timedOut, .notMaterialized, .noCoverage
        ]
        for outcome in outcomes { await reporter.recordCompletion(outcome: outcome, now: started.addingTimeInterval(8)) }

        let line = await reporter.line(now: started.addingTimeInterval(8))
        #expect(line?.contains("killed 2, survived 1, unviable 1, unstable 2, not materialized 1, other 1") == true)
    }

    @Test("Zero optional buckets stay out of the line; a counter with no outcomes has no breakdown at all")
    func breakdownOmitsEmptyBuckets() async {
        let started = Date(timeIntervalSince1970: 0)
        let reporter = ProgressReporter(total: 4, startedAt: started, interactive: false)
        await reporter.recordCompletion(outcome: .killedByAssertion, now: started)
        #expect(await reporter.line(now: started)?.contains("killed 1, survived 0\n") == true)

        let plain = ProgressReporter(total: 4, startedAt: started, interactive: false)
        await plain.recordCompletion(now: started)
        #expect(await plain.line(now: started)?.contains("killed") == false)
    }

    @Test("A terminal rewrites one line in place; a non-terminal gets plain, newline-terminated lines")
    func ttyAndPlainRendering() {
        let line = "mutants [1/4] 25% — elapsed 1s, ETA ~3s\n"
        #expect(ProgressReporter.rendered(line, interactive: false, final: false) == line)
        #expect(ProgressReporter.rendered(line, interactive: true, final: false) == "\r\u{1B}[2Kmutants [1/4] 25% — elapsed 1s, ETA ~3s")
        #expect(ProgressReporter.rendered(line, interactive: true, final: true).hasSuffix("ETA ~3s\n"))
    }
}

private final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func add(_ entry: String) {
        lock.lock()
        storage.append(entry)
        lock.unlock()
    }
}

private struct StubBuildAdapter: BuildAdapter {
    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: "baseline-hash", xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: "mutant-hash", xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

/// Fails every mutant, and runs `onFirstMutant` while the first one is "in flight".
private actor InterruptingTestAdapter: TestAdapter {
    private(set) var mutantCalls = 0
    private let onFirstMutant: @Sendable () -> Void

    init(onFirstMutant: @escaping @Sendable () -> Void) {
        self.onFirstMutant = onFirstMutant
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        mutantCalls += 1
        if mutantCalls == 1 { onFirstMutant() }
        return Self.result(.failed)
    }

    private static func result(_ status: TestRunStatus) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted \(status.rawValue)"
        )
    }
}
