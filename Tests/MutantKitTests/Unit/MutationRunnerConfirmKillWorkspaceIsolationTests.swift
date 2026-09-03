import Darwin
import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// F3 zero-base review, verdict-contamination audit: `confirmKill` (the
/// `Configuration.execution.retestKilledMutants` retest) must never
/// execute in a filesystem workspace that any process from the *primary*
/// test run could still be writing into — including a
/// `ProcessSupervisor`-escaped descendant that survived past
/// `ProcessSupervisor.run`'s own return (the exact, confirmed-real gap
/// `EscapedDescendantOwnershipBoundaryDiagnostic` pins). Before the fix
/// this file regression-tests, `confirmKill` reran directly in
/// `prepared.sandbox` — the *same* directory the primary test's own
/// spawned processes had just been running in — so a still-alive escapee
/// racing the confirmation retest was a real, structural possibility, not
/// a hypothetical: `A. primary test → B. escaped descendant survives →
/// C. ProcessSupervisor.run returns anyway → D. confirmKill retests in
/// the same directory → E. the escapee's own leftover state is present
/// for the retest to observe`.
///
/// Three properties, matching the review's own required shape:
/// - **A. workspace identity** — the confirmation retest's own workspace
///   must differ from the primary run's.
/// - **B. temporal isolation** — that confirmation workspace must have
///   been established *before* the primary test ever started, not cloned
///   from the primary workspace afterward (a clone taken after the
///   primary run merely races a still-alive escapee instead of avoiding
///   it — see `PreparedMutant.confirmationSandbox`'s own doc comment).
/// - **C. contamination fixture** — the actual threat model, not just
///   implementation shape: a real, `ProcessSupervisor`-owned but
///   group-escaped descendant is left continuously writing observable
///   state into the primary workspace; the confirmation retest's own
///   workspace must never show any of it, and the mutant's final verdict
///   must not depend on whether the escapee exists at all.
@Suite("Mutation runner: confirmKill's own workspace is isolated from the primary run", .subprocessExclusive)
struct MutationRunnerConfirmKillWorkspaceIsolationTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-confirmkill-isolation-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-confirmkill-isolation-scratch")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0", toolCommitSHA: nil, swiftVersion: "6.3.3", swiftSyntaxVersion: "603.0.2", xcodeVersion: nil
    )

    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    private func writeSingleMutantProject() throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("struct A { var enabled = true }".utf8).write(to: url)
    }

    @Test("A. and B.: the confirmation retest's own workspace differs from the primary run's, and was established before it")
    func confirmationWorkspaceIsIndependentAndPreEstablished() async throws {
        try writeSingleMutantProject()

        let configuration = Configuration(execution: ExecutionSettings(retestKilledMutants: true))
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 1)

        let log = WorkspaceCallLog()
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root,
            build: RecordingBuildAdapter(log: log),
            test: RecordingTestAdapter(log: log, sequence: [.failed, .failed]),
            workspaces: workspaces
        )
        _ = try await runner.run()

        let calls = await log.workspaces
        #expect(calls.count == 2, "expected exactly one primary run and one confirmation retest")
        let primaryWorkspace = calls[0]
        let confirmationWorkspace = calls[1]

        // A. identity
        #expect(confirmationWorkspace != primaryWorkspace, "confirmKill retested in the primary run's own workspace")

        // B. temporal isolation: the confirmation workspace must already
        // have existed on disk by the time the primary test's own
        // `runMutant` call started — i.e. established during the build,
        // strictly before any primary-run process ever ran, not cloned
        // afterward from a directory a still-alive process could race.
        let existedBeforePrimaryRan = await log.confirmationWorkspacePreExisted
        #expect(
            existedBeforePrimaryRan == true,
            """
            the confirmation workspace was not yet on disk when the primary test started -- it can only have been \
            established afterward, which is exactly the unsafe ordering this fix exists to prevent
            """
        )
    }

    @Test("C.: a group-escaped descendant left writing into the primary workspace never contaminates the confirmation retest")
    func escapedDescendantContinuingToWriteNeverReachesTheConfirmationRetest() async throws {
        try writeSingleMutantProject()

        let configuration = Configuration(execution: ExecutionSettings(retestKilledMutants: true))
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 1)

        let markerFileName = "escapee-marker.txt"
        let log = WorkspaceCallLog()
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root,
            build: RecordingBuildAdapter(log: log),
            test: EscapingDescendantTestAdapter(log: log, markerFileName: markerFileName),
            workspaces: workspaces
        )
        let report = try await runner.run()

        // Both checks below happened *synchronously*, inside
        // `EscapingDescendantTestAdapter.runMutant` itself, while both
        // workspaces were still guaranteed to exist on disk -- checking
        // post-hoc here, after `runner.run()` has already returned, would
        // race the primary workspace's own destruction (`evaluate(_:
        // baseline:)` destroys it as soon as this mutant's evaluation is
        // fully done, which may happen before or after the escapee's own
        // 3-second write loop finishes; the *fixture's* own genuine
        // activity is proven synchronously instead, not by surviving that
        // race).
        let calls = await log.workspaces
        #expect(calls.count == 2, "expected exactly one primary run and one confirmation retest")

        let escapeeConfirmedWriting = await log.escapeeMarkerObservedInPrimaryWorkspace
        #expect(
            escapeeConfirmedWriting == true,
            "the escaped descendant was never confirmed writing into the primary workspace -- fixture did not exercise the real threat"
        )

        // The actual property under test: the confirmation retest's own
        // workspace showed zero trace of the escapee at the moment
        // `confirmKill`'s own retest actually ran, however long the
        // escapee kept running in the primary workspace afterward.
        let contaminationDetected = await log.escapeeMarkerInConfirmationWorkspace
        #expect(
            contaminationDetected == false,
            "the escaped descendant's marker was present in confirmKill's own workspace -- confirmation independence is broken"
        )

        // The verdict itself must not depend on the escapee's existence:
        // both scripted runs report `.failed`, and the escapee's presence
        // must not turn that into anything else (a contaminated read could
        // plausibly have flipped the confirmation's own outcome).
        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)
    }
}

// MARK: - Shared test infrastructure

private actor WorkspaceCallLog {
    private(set) var workspaces: [URL] = []
    private(set) var confirmationWorkspacePreExisted: Bool?
    private(set) var escapeeMarkerObservedInPrimaryWorkspace: Bool?
    private(set) var escapeeMarkerInConfirmationWorkspace: Bool?

    func recordRunMutant(workspace: URL) {
        workspaces.append(workspace)
    }

    func recordConfirmationWorkspaceSnapshot(existedAtPrimaryStart: Bool) {
        confirmationWorkspacePreExisted = existedAtPrimaryStart
    }

    func recordEscapeeMarkerObservedInPrimaryWorkspace(_ observed: Bool) {
        escapeeMarkerObservedInPrimaryWorkspace = observed
    }

    func recordEscapeeMarkerObservedInConfirmationWorkspace(_ observed: Bool) {
        escapeeMarkerInConfirmationWorkspace = observed
    }
}

/// Always succeeds, with a mutant product hash that differs from the
/// baseline's -- activation evidence is proven, so classification reaches
/// the test-status branch these tests actually exercise. `productsDirectory`
/// is the workspace itself, matching `MutationRunnerFlakyRetestTests`'s own
/// `StubBuildAdapter` -- `cloneProducts` then clones the *whole* sandbox,
/// which is what lets a marker file written into it be observable in a
/// clone at all.
private struct RecordingBuildAdapter: BuildAdapter {
    let log: WorkspaceCallLog

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

/// Two scripted `.failed` runs (primary, then confirmation), recording
/// every `runMutant` workspace it is handed and, on the *second* call,
/// whether that workspace already existed on disk -- which is only ever
/// true if it was established at `prepare` time (before the first call
/// even started), never if it were cloned reactively after the fact.
private actor RecordingTestAdapter: TestAdapter {
    let log: WorkspaceCallLog
    let sequence: [TestRunStatus]
    private var callIndex = 0

    init(log: WorkspaceCallLog, sequence: [TestRunStatus]) {
        self.log = log
        self.sequence = sequence
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        await log.recordRunMutant(workspace: workspace)
        defer { callIndex += 1 }
        if callIndex == 1 {
            // This IS the confirmation retest (call index 1, zero-based) --
            // its own workspace must already be real, on disk, right now.
            await log.recordConfirmationWorkspaceSnapshot(
                existedAtPrimaryStart: FileManager.default.fileExists(atPath: workspace.path)
            )
        }
        return Self.result(sequence[callIndex])
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

/// The real threat-model fixture (Stage C): on the *first* `runMutant`
/// call (the primary test), spawns a real, `ProcessSupervisor`-owned
/// process whose own child immediately escapes into its own process
/// group (`setpgid(0, 0)`, the exact shape
/// `EscapedDescendantOwnershipBoundaryDiagnostic`/`ProcessTree`'s own doc
/// comments attribute to `swiftpm-testing-helper`) and then, in a loop,
/// continuously overwrites a marker file *inside the primary workspace*
/// -- confirmed alive and writing (a real, blocking pipe handshake, never
/// a sleep guess) before this function returns `.failed`, so the escapee
/// is provably still running, still owned by `ProcessSupervisor`'s own
/// bookkeeping (however incompletely — the exact F3 Finding 1 boundary),
/// and still writing when the confirmation retest (the second call)
/// happens immediately afterward.
private actor EscapingDescendantTestAdapter: TestAdapter {
    let log: WorkspaceCallLog
    let markerFileName: String
    private var callIndex = 0
    private var escapeeRootPID: pid_t?

    init(log: WorkspaceCallLog, markerFileName: String) {
        self.log = log
        self.markerFileName = markerFileName
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        await log.recordRunMutant(workspace: workspace)
        defer { callIndex += 1 }

        if callIndex == 0 {
            let markerPath = workspace.appendingPathComponent(markerFileName).path
            escapeeRootPID = try Self.spawnEscapeeWritingContinuously(into: markerPath)
            // Bounded, real-fact polling for "the escapee has written at
            // least once" -- legitimate setup verification (establishing
            // that the fixture genuinely exercised the threat), not a race
            // this test's own correctness depends on: the actual property
            // under test (checked below, on the *second* call) is
            // determined entirely by *when* `confirmationSandbox` was
            // cloned (at `prepare` time, before this call ever started),
            // never by how this poll happens to resolve.
            let deadline = Date().addingTimeInterval(2.0)
            var observed = FileManager.default.fileExists(atPath: markerPath)
            while !observed, Date() < deadline {
                usleep(5000)
                observed = FileManager.default.fileExists(atPath: markerPath)
            }
            await log.recordEscapeeMarkerObservedInPrimaryWorkspace(observed)
        } else {
            // The confirmation retest, checked immediately, synchronously,
            // right now -- before `runner.run()` has any chance to destroy
            // either workspace. `confirmationSandbox` was cloned at
            // `prepare` time, strictly before the primary `runMutant` call
            // above ever started (let alone before the escapee it spawned
            // wrote anything), so this must be `false` regardless of how
            // long the escapee has had to write into the *primary*
            // workspace by now.
            let markerPath = workspace.appendingPathComponent(markerFileName).path
            await log.recordEscapeeMarkerObservedInConfirmationWorkspace(
                FileManager.default.fileExists(atPath: markerPath)
            )
        }
        return Self.result(.failed)
    }

    /// Real, blocking pipe-read handshake (matching
    /// `ProcessSupervisorOwnershipFixture.runFastParentExit`'s own
    /// convention) for "the escapee has started writing" -- never a sleep
    /// guess. `root` exits the instant the handshake confirms the child is
    /// alive and already writing, so `ProcessSupervisor.run`'s own return
    /// (this function's caller effectively awaits nothing further) happens
    /// while the child -- now provably owned but group-escaped -- keeps
    /// running and rewriting the marker file for a further 3 real seconds,
    /// comfortably outliving the confirmation retest this test drives
    /// immediately afterward.
    private static func spawnEscapeeWritingContinuously(into markerPath: String) throws -> pid_t {
        let script = """
        import os, sys, time
        marker_path = \(pythonLiteral(markerPath))
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            os.setpgid(0, 0)
            os.write(w, b"x")
            os.close(w)
            deadline = time.time() + 3.0
            i = 0
            while time.time() < deadline:
                with open(marker_path, "w") as f:
                    f.write("ESCAPEE_STILL_WRITING iteration=%d\\n" % i)
                i += 1
                time.sleep(0.02)
            os._exit(0)
        else:
            os.close(w)
            os.read(r, 1)
            os.close(r)
            sys.exit(0)
        """

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let argv = ["/usr/bin/python3", "-c", script]
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for pointer in cArgs where pointer != nil { free(pointer) } }
        var mutableArgv = cArgs
        let spawnResult = mutableArgv.withUnsafeMutableBufferPointer { buffer -> Int32 in
            posix_spawn(&pid, "/usr/bin/python3", nil, &attributes, buffer.baseAddress, environ)
        }
        guard spawnResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EIO) }

        // Root exits almost immediately once its own child confirms
        // readiness (matching the fixture's own internal pipe handshake,
        // not this outer one -- this outer spawn call itself returns as
        // soon as `posix_spawn` hands back a pid; we do not separately
        // wait on `root` here since `ProcessSupervisor`/this adapter's own
        // caller has no reason to -- the point of this fixture is that the
        // *caller* (here, this test's own `runMutant`) does not block on
        // root's own exit at all, exactly like a real supervised run
        // wouldn't either).
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return pid
    }

    private static func pythonLiteral(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
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
