import Darwin
import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// F3 zero-base review, verdict-contamination audit: a second, independent
/// instance of the same contamination class `MutationRunnerConfirmKillWorkspaceIsolationTests`
/// regression-tests — found while auditing every `confirmKill` call site per
/// that review, not the original one it fixed.
///
/// `confirmTimeout` (`Configuration.execution.confirmTimedOutMutants`) does
/// its own independent rebuild in a fresh sandbox, then — when that
/// confirming rebuild's own result is a batch-attributed failure — runs a
/// *further*, same-artifact `confirmKill` retest to confirm that kill. Before
/// the fix this file regression-tests, that inner retest reran directly in
/// the confirming rebuild's own sandbox: the *same* directory the confirming
/// rebuild's own spawned processes had just been running in, so a still-alive
/// `ProcessSupervisor`-escaped descendant from *that* rebuild racing the
/// inner retest was exactly the same structural gap as the original finding,
/// just one level deeper in the confirmation chain.
///
/// Same three properties, applied to the confirming rebuild → inner retest
/// boundary instead of the primary run → confirmKill boundary:
/// - **A. workspace identity** — the inner retest's own workspace must
///   differ from the confirming rebuild's.
/// - **B. temporal isolation** — that inner-retest workspace must already
///   have existed before the confirming rebuild's own test ever ran.
/// - **C. contamination fixture** — a real, group-escaped descendant left
///   writing into the confirming rebuild's workspace must never be visible
///   to the inner retest.
@Suite("Mutation runner: confirmTimeout's own inner retest is isolated from its confirming rebuild", .subprocessExclusive)
struct MutationRunnerTimeoutConfirmationInnerRetestIsolationTests {
    private let root: URL = Self.makeTempDir(prefix: "mutantkit-timeout-inner-isolation-project")
    private let scratchRoot: URL = Self.makeTempDir(prefix: "mutantkit-timeout-inner-isolation-scratch")
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

    private func makeConfiguration() -> Configuration {
        Configuration(execution: ExecutionSettings(retestKilledMutants: true, confirmTimedOutMutants: true))
    }

    @Test("A. and B.: the inner retest's own workspace differs from the confirming rebuild's, and was established before it")
    func innerRetestWorkspaceIsIndependentAndPreEstablished() async throws {
        try writeSingleMutantProject()

        let configuration = makeConfiguration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 1)

        let log = InnerRetestWorkspaceCallLog()
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root,
            build: RecordingBuildAdapter(log: log),
            test: RecordingTestAdapter(log: log, sequence: [.timedOut, .failed, .failed]),
            workspaces: workspaces
        )
        let report = try await runner.run()

        let calls = await log.workspaces
        #expect(calls.count == 3, "expected the original timeout, the confirming rebuild, and the inner retest")
        let confirmingRebuildWorkspace = calls[1]
        let innerRetestWorkspace = calls[2]

        // A. identity
        #expect(innerRetestWorkspace != confirmingRebuildWorkspace, "the inner retest reran in the confirming rebuild's own workspace")

        // B. temporal isolation
        let existedBeforeConfirmingRebuildRan = await log.innerRetestWorkspacePreExisted
        #expect(
            existedBeforeConfirmingRebuildRan == true,
            """
            the inner retest's workspace was not yet on disk when the confirming rebuild's own test started -- it can \
            only have been established afterward, which is exactly the unsafe ordering this fix exists to prevent
            """
        )

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)
    }

    @Test("C.: a group-escaped descendant left writing into the confirming rebuild's workspace never contaminates the inner retest")
    func escapedDescendantFromConfirmingRebuildNeverReachesInnerRetest() async throws {
        try writeSingleMutantProject()

        let configuration = makeConfiguration()
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        #expect(plan.mutations.count == 1)

        let markerFileName = "escapee-marker.txt"
        let log = InnerRetestWorkspaceCallLog()
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        let runner = MutationRunner(
            plan: plan, configuration: configuration, projectRoot: root,
            build: RecordingBuildAdapter(log: log),
            test: EscapingDescendantAtConfirmingRebuildAdapter(log: log, markerFileName: markerFileName),
            workspaces: workspaces
        )
        let report = try await runner.run()

        let calls = await log.workspaces
        #expect(calls.count == 3, "expected the original timeout, the confirming rebuild, and the inner retest")

        let escapeeConfirmedWriting = await log.escapeeMarkerInRebuildWorkspace
        #expect(
            escapeeConfirmedWriting == true,
            """
            the escaped descendant was never confirmed writing into the confirming rebuild's workspace -- fixture \
            did not exercise the real threat
            """
        )

        let contaminationDetected = await log.escapeeMarkerInInnerRetestWorkspace
        #expect(
            contaminationDetected == false,
            "the escaped descendant's marker was present in the inner retest's own workspace -- confirmation independence is broken"
        )

        let result = try #require(report.results.first)
        #expect(result.outcome == .killedByAssertion)
    }
}

// MARK: - Shared test infrastructure

private actor InnerRetestWorkspaceCallLog {
    private(set) var workspaces: [URL] = []
    private(set) var innerRetestWorkspacePreExisted: Bool?
    private(set) var escapeeMarkerInRebuildWorkspace: Bool?
    private(set) var escapeeMarkerInInnerRetestWorkspace: Bool?

    func recordRunMutant(workspace: URL) {
        workspaces.append(workspace)
    }

    func recordInnerRetestWorkspaceSnapshot(existedAtConfirmingRebuildStart: Bool) {
        innerRetestWorkspacePreExisted = existedAtConfirmingRebuildStart
    }

    func recordEscapeeMarkerObservedInConfirmingRebuildWorkspace(_ observed: Bool) {
        escapeeMarkerInRebuildWorkspace = observed
    }

    func recordEscapeeMarkerObservedInInnerRetestWorkspace(_ observed: Bool) {
        escapeeMarkerInInnerRetestWorkspace = observed
    }
}

/// Always succeeds, with a mutant product hash that differs from the
/// baseline's -- activation evidence is proven, so classification reaches
/// the test-status branch these tests actually exercise. `productsDirectory`
/// is the workspace itself, matching `MutationRunnerConfirmKillWorkspaceIsolationTests`'s
/// own `RecordingBuildAdapter` -- `cloneProducts` then clones the *whole*
/// sandbox, which is what lets a marker file written into it be observable
/// in a clone at all.
private struct RecordingBuildAdapter: BuildAdapter {
    let log: InnerRetestWorkspaceCallLog

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

/// Three scripted runs (original timeout, confirming rebuild, inner
/// same-artifact retest), recording every `runMutant` workspace it is
/// handed and, on the *third* call, whether that workspace already existed
/// on disk -- which is only ever true if it was cloned before the
/// confirming rebuild's own test even started.
private actor RecordingTestAdapter: TestAdapter {
    let log: InnerRetestWorkspaceCallLog
    let sequence: [TestRunStatus]
    private var callIndex = 0

    init(log: InnerRetestWorkspaceCallLog, sequence: [TestRunStatus]) {
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
        let status = sequence[callIndex]
        if callIndex == 2 {
            await log.recordInnerRetestWorkspaceSnapshot(
                existedAtConfirmingRebuildStart: FileManager.default.fileExists(atPath: workspace.path)
            )
        }
        let isBatchAttributed = callIndex == 0 && status == .timedOut
        return Self.result(status, isBatchAttributedTimeout: isBatchAttributed)
    }

    private static func result(_ status: TestRunStatus, isBatchAttributedTimeout: Bool = false) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted \(status.rawValue)",
            isBatchAttributedTimeout: isBatchAttributedTimeout
        )
    }
}

/// The real threat-model fixture (Stage C): call 0 reports the original
/// `.timedOut`. Call 1 — the confirming rebuild's own test — spawns a real,
/// `ProcessSupervisor`-owned process whose child immediately escapes into
/// its own process group and continuously overwrites a marker file *inside
/// the confirming rebuild's own workspace*, confirmed alive and writing via
/// a real blocking pipe handshake, before reporting `.failed` (a
/// batch-attributed failure, so the inner retest fires). Call 2 — the inner
/// retest — checks, synchronously and immediately, whether that marker is
/// visible in *its own* workspace.
private actor EscapingDescendantAtConfirmingRebuildAdapter: TestAdapter {
    let log: InnerRetestWorkspaceCallLog
    let markerFileName: String
    private var callIndex = 0

    init(log: InnerRetestWorkspaceCallLog, markerFileName: String) {
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

        switch callIndex {
        case 0:
            return Self.result(.timedOut, isBatchAttributedTimeout: true)
        case 1:
            let markerPath = workspace.appendingPathComponent(markerFileName).path
            _ = try Self.spawnEscapeeWritingContinuously(into: markerPath)
            let deadline = Date().addingTimeInterval(2.0)
            var observed = FileManager.default.fileExists(atPath: markerPath)
            while !observed, Date() < deadline {
                usleep(5000)
                observed = FileManager.default.fileExists(atPath: markerPath)
            }
            await log.recordEscapeeMarkerObservedInConfirmingRebuildWorkspace(observed)
            return Self.result(.failed)
        default:
            let markerPath = workspace.appendingPathComponent(markerFileName).path
            await log.recordEscapeeMarkerObservedInInnerRetestWorkspace(
                FileManager.default.fileExists(atPath: markerPath)
            )
            return Self.result(.failed)
        }
    }

    /// Same shape as `MutationRunnerConfirmKillWorkspaceIsolationTests`'s
    /// own `spawnEscapeeWritingContinuously` -- a real, blocking
    /// pipe-read handshake for "the escapee has started writing," never a
    /// sleep guess.
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

    private static func result(_ status: TestRunStatus, isBatchAttributedTimeout: Bool = false) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted \(status.rawValue)",
            isBatchAttributedTimeout: isBatchAttributedTimeout
        )
    }
}
