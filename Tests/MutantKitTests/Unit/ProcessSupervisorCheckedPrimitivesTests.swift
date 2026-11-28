import Darwin
import Foundation
@testable import MutationExecution
import Testing

/// Failure injection for the checked supervision primitives: launch setup,
/// exit observation, bounded drain and process-table sampling. Each primitive
/// reports its failure; none turns it into success, an empty result or a
/// fabricated exit.
@Suite("ProcessSupervisor: checked primitives", .subprocessExclusive)
struct ProcessSupervisorCheckedPrimitivesTests {
    private static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mk-checked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Launch

    static let setupOperations = [
        "pipe(stdout)", "pipe(stderr)", "fcntl(F_SETFD,stdout.read)", "fcntl(F_SETFD,stderr.write)",
        "posix_spawn_file_actions_init", "posix_spawn_file_actions_adddup2(stdout)",
        "posix_spawn_file_actions_adddup2(stderr)", "posix_spawn_file_actions_addclose(stdout.read)",
        "posix_spawn_file_actions_addclose(stderr.read)", "posix_spawn_file_actions_addchdir_np",
        "posix_spawnattr_init", "posix_spawnattr_setflags", "posix_spawnattr_setpgroup",
        "posix_spawnattr_setsigmask", "posix_spawnattr_setsigdefault"
    ]

    @Test("A failing launch-setup step starts no child, reports the operation and errno, and leaks no descriptor",
          arguments: setupOperations)
    func setupFailureStartsNothing(operation: String) throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("ran")
        let seen = Box<[Int32]>([])

        do {
            _ = try ProcessLaunch.spawn(
                executable: "/usr/bin/touch", arguments: [marker.path], workingDirectory: directory,
                environment: [:], fault: { name, owned in
                    guard name == operation else { return nil }
                    seen.value = owned
                    return EMFILE
                }
            )
            Issue.record("spawn succeeded despite a failing \(operation)")
        } catch let ProcessSupervisorError.spawnSetupFailed(failed, code) {
            #expect(failed == operation)
            #expect(code == EMFILE)
        }

        usleep(200_000)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "no child may start after a setup failure")
        for fd in seen.value {
            #expect(fcntl(fd, F_GETFD) == -1 && errno == EBADF, "descriptor \(fd) leaked after \(operation) failed")
        }
    }

    @Test("A failing posix_spawn is spawnFailed and leaks no descriptor")
    func spawnFailureLeaksNothing() throws {
        let seen = Box<[Int32]>([])
        #expect(throws: ProcessSupervisorError.self) {
            try ProcessLaunch.spawn(
                executable: "/usr/bin/true", arguments: [], workingDirectory: FileManager.default.temporaryDirectory,
                environment: [:], fault: { name, owned in
                    guard name == "posix_spawn" else { return nil }
                    seen.value = owned
                    return EAGAIN
                }
            )
        }
        #expect(!seen.value.isEmpty)
        for fd in seen.value { #expect(fcntl(fd, F_GETFD) == -1 && errno == EBADF, "descriptor \(fd) leaked") }
    }

    @Test("The child runs in the requested working directory and leads its own process group")
    func childRunsInWorkingDirectoryAsGroupLeader() async throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", "pwd -P; ps -o pid=,pgid= -p $$"],
            workingDirectory: directory, timeoutSeconds: 30
        )
        let lines = String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.first == String(cString: realpath(directory.path, nil)))
        let ids = (lines.last ?? "").split(separator: " ").compactMap { Int($0) }
        #expect(ids.count == 2 && ids[0] == ids[1], "child must lead its own group: \(lines)")
    }

    @Test("A launch setup failure through run() throws and leaves the run usable")
    func runSurfacesSetupFailure() async throws {
        await #expect(throws: ProcessSupervisorError.self) {
            try await ProcessSupervisor.run(
                executable: "/usr/bin/true", arguments: [], workingDirectory: FileManager.default.temporaryDirectory,
                environment: [:], timeoutSeconds: 5, lifecycleEventHook: nil,
                launchFault: { name, _ in name == "posix_spawn_file_actions_addchdir_np" ? ENOMEM : nil }
            )
        }
    }

    // MARK: - Exit observation

    private struct WaitStep {
        let rc: pid_t
        let status: Int32
        let errno: Int32
        init(_ rc: pid_t, _ status: Int32, _ errno: Int32) {
            self.rc = rc; self.status = status; self.errno = errno
        }
    }

    private static func fakeWait(_ script: @escaping @Sendable (Int) -> WaitStep) -> ProcessSupervisor.WaitPID {
        let calls = Counter()
        return { _, statusPointer, _ in
            let step = script(calls.next())
            statusPointer.pointee = step.status
            if step.rc < 0 { errno = step.errno }
            return step.rc
        }
    }

    @Test("reap retries EINTR and then reports the observed exit")
    func reapRetriesEINTR() {
        let wait = Self.fakeWait { $0 < 2 ? WaitStep(-1, 0, EINTR) : WaitStep(42, 3 << 8, 0) }
        #expect(ProcessSupervisor.reap(42, waitpid: wait) == .exited(code: 3))
    }

    @Test("reap reports a signalled process as signalled")
    func reapSignalled() {
        #expect(ProcessSupervisor.reap(42, waitpid: Self.fakeWait { _ in WaitStep(42, SIGKILL, 0) }) == .signaled(signal: SIGKILL))
    }

    @Test("ECHILD is unavailable, never a successful exit 0")
    func reapECHILDIsUnavailable() {
        let observation = ProcessSupervisor.reap(42, waitpid: Self.fakeWait { _ in WaitStep(-1, 0, ECHILD) })
        guard case .unavailable = observation else { Issue.record("got \(observation)"); return }
        #expect(observation.shellExitCode == nil)
    }

    @Test("A waitpid that reaps a different pid is unavailable")
    func reapWrongPidIsUnavailable() {
        let observation = ProcessSupervisor.reap(42, waitpid: Self.fakeWait { _ in WaitStep(7, 0, 0) })
        guard case .unavailable = observation else { Issue.record("got \(observation)"); return }
    }

    @Test("A failed reap through run() is an unverified result with no exit code, not exit 0")
    func failedReapIsNotSuccess() async throws {
        let pidBox = Box<pid_t>(0)
        let result = try await ProcessSupervisor.run(
            executable: "/usr/bin/true", arguments: [], workingDirectory: FileManager.default.temporaryDirectory,
            environment: [:], timeoutSeconds: 30,
            lifecycleEventHook: { if case let .groupSignal(pid, _) = $0 { pidBox.value = pid } },
            waitpid: { _, _, _ in errno = ECHILD; return -1 }
        )
        defer { if pidBox.value > 0 { var status: Int32 = 0; waitpid(pidBox.value, &status, 0) } }

        #expect(!result.exitStatusAvailable)
        #expect(!result.succeeded)
        #expect(result.exitCode == -1)
        #expect(!result.cleanupVerified)
        #expect(result.cleanupDiagnosis?.contains("exit status") == true)
    }

    @Test("A normal run still reports its real exit code")
    func normalExitStillReported() async throws {
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", "exit 7"], workingDirectory: FileManager.default.temporaryDirectory,
            timeoutSeconds: 30
        )
        #expect(result.exitStatusAvailable && result.exitCode == 7 && !result.succeeded)
    }

    // MARK: - Drain

    private static func makePipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        precondition(pipe(&fds) == 0)
        return (fds[0], fds[1])
    }

    @Test("A held-open writer cannot keep the reader, descriptor or buffer alive once the drain is stopped")
    func heldOpenWriterIsReleasedByStop() {
        let ends = Self.makePipe()
        defer { close(ends.write) }
        let group = DispatchGroup()
        let drain = PipeDrain(fd: ends.read, group: group)
        _ = write(ends.write, "partial", 7)
        let readDeadline = Date().addingTimeInterval(10)
        while drain.value.count < 7, Date() < readDeadline { usleep(1000) }

        #expect(group.wait(timeout: .now() + 0.2) == .timedOut, "writer still open: reader keeps going until told to stop")
        drain.stop()
        #expect(group.wait(timeout: .now() + 2) == .success, "reader must exit and close its fd within a poll slice")
        #expect(String(decoding: drain.value, as: UTF8.self) == "partial")
        #expect(!drain.reachedEOF, "a stop is not EOF")
        #expect(fcntl(ends.read, F_GETFD) == -1 && errno == EBADF, "the reader must have closed its own descriptor")
    }

    @Test("An unbounded producer is capped and flagged truncated")
    func unboundedProducerIsBounded() {
        let ends = Self.makePipe()
        let group = DispatchGroup()
        let drain = PipeDrain(fd: ends.read, maxBytes: 10000, group: group)
        let chunk = [UInt8](repeating: 0x41, count: 4096)
        for _ in 0 ..< 64 { _ = write(ends.write, chunk, chunk.count) }
        close(ends.write)

        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(drain.value.count == 10000)
        #expect(drain.truncated)
        #expect(drain.reachedEOF, "EOF was reached; completeness must still be false because of truncation")
    }

    @Test("Large output under the cap is complete and untruncated")
    func largeOutputUnderCapIsComplete() {
        let ends = Self.makePipe()
        let group = DispatchGroup()
        let drain = PipeDrain(fd: ends.read, group: group)
        let writer = Thread {
            let chunk = [UInt8](repeating: 0x42, count: 64 * 1024)
            for _ in 0 ..< 32 { _ = write(ends.write, chunk, chunk.count) }
            close(ends.write)
        }
        writer.start()

        #expect(group.wait(timeout: .now() + 10) == .success)
        #expect(drain.value.count == 32 * 64 * 1024)
        #expect(drain.reachedEOF && !drain.truncated)
    }

    @Test("Output beyond the capture ceiling makes the run's output incomplete")
    func truncatedOutputIsIncompleteThroughRun() async throws {
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", "yes | head -c 100000"],
            workingDirectory: FileManager.default.temporaryDirectory, environment: [:], timeoutSeconds: 30,
            lifecycleEventHook: nil, maxCapturedBytes: 1000
        )
        #expect(result.standardOutput.count == 1000)
        #expect(!result.outputComplete)
        #expect(result.exitCode == 0)
    }

    // MARK: - Process table

    private static let entryStride = MemoryLayout<kinfo_proc>.stride

    /// A fake sysctl: the size call reports `sizedEntries`, the fill call
    /// writes `filledEntries` records (pids 100, 101, ...) and reports `filledBytes`.
    private static func fakeSysctl(
        sizedEntries: Int, filledEntries: Int, filledBytes: Int? = nil, failFill: Bool = false
    ) -> ProcessTree.SysctlCall {
        { _, _, old, length, _, _ in
            guard let old else { length.pointee = sizedEntries * entryStride; return 0 }
            if failFill { errno = ENOMEM; return -1 }
            let records = old.bindMemory(to: kinfo_proc.self, capacity: filledEntries)
            for index in 0 ..< filledEntries {
                var record = kinfo_proc()
                record.kp_proc.p_pid = pid_t(100 + index)
                records[index] = record
            }
            length.pointee = filledBytes ?? filledEntries * entryStride
            return 0
        }
    }

    @Test("A table that shrank between sizing and filling yields only the filled entries")
    func shrunkTableHasNoSyntheticEntries() throws {
        let table = try #require(ProcessTree.readProcessTable(sysctl: Self.fakeSysctl(sizedEntries: 5, filledEntries: 3)))
        #expect(table.map(\.pid) == [100, 101, 102])
    }

    @Test("A table that grew within the headroom is read in full")
    func grownTableWithinHeadroomIsRead() throws {
        let table = try #require(ProcessTree.readProcessTable(sysctl: Self.fakeSysctl(sizedEntries: 3, filledEntries: 6)))
        #expect(table.count == 6)
    }

    @Test("A failed fill, an empty fill or a torn record length is unreadable, never an empty table")
    func unreadableTablesAreNil() {
        #expect(ProcessTree.readProcessTable(sysctl: Self.fakeSysctl(sizedEntries: 3, filledEntries: 3, failFill: true)) == nil)
        #expect(ProcessTree.readProcessTable(sysctl: Self.fakeSysctl(sizedEntries: 3, filledEntries: 0, filledBytes: 0)) == nil)
        let torn = Self.fakeSysctl(sizedEntries: 3, filledEntries: 3, filledBytes: Self.entryStride * 3 - 1)
        #expect(ProcessTree.readProcessTable(sysctl: torn) == nil)
        #expect(ProcessTree.readProcessTable(sysctl: { _, _, _, _, _, _ in -1 }) == nil)
    }

    @Test("A failed sample is nil, not 'no descendants'")
    func failedSampleIsNotEmpty() {
        #expect(ProcessTree.descendantIdentities(of: getpid(), readTable: { nil }) == nil)
        #expect(ProcessTree.descendantIdentities(of: getpid(), readTable: { [] }) == [])
    }

    @Test("A missed ancestry sample makes cleanup unverified even when the final check is clean")
    func missedSampleCannotClaimContainment() async throws {
        let calls = Counter()
        let result = try await ProcessSupervisor.run(
            executable: "/bin/sh", arguments: ["-c", "exit 0"], workingDirectory: FileManager.default.temporaryDirectory,
            environment: [:], timeoutSeconds: 30, lifecycleEventHook: nil,
            processTableReader: { calls.next() < ProcessTree.tableReadAttempts ? nil : ProcessTree.readProcessTable() }
        )
        #expect(result.exitCode == 0 && result.exitStatusAvailable)
        #expect(!result.cleanupVerified)
        #expect(result.cleanupDiagnosis?.contains("process-table sample") == true)
    }
}

private final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
