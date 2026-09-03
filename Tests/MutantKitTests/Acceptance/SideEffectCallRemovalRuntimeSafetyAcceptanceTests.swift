import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Turns an earlier semantic-quality sample's own side-effect-call-
/// removal finding (4 of 25 real candidates from swift-argument-parser
/// flagged "suspicious", clustered on `Mutex.swift`'s raw
/// `os_unfair_lock_unlock`/`_Lock.initialize` calls) into real, reproducible
/// fixtures — and corrects an initial hypothesis in the process.
///
/// **The initial hypothesis — "a removed unlock silently deadlocks forever"
/// — was empirically wrong on this platform (macOS 26.6.2).** Prototyping
/// this fixture found a removed `os_unfair_lock_unlock` does not hang: the
/// *next* thread that contends for the same lock is killed almost
/// immediately (observed: 16–230ms) by `libsystem_platform`'s own
/// corruption/staleness detector (`_os_unfair_lock_corruption_abort`,
/// diagnostic message "os_unfair_lock is corrupt, or owner thread exited
/// without unlocking" — confirmed via a real crash report, `bug_type 309`,
/// `exception.signal: SIGKILL`). A **deterministic, fast crash**, not an
/// indefinite hang. The same crash signature (kernel log: `killed] exiting
/// with signal 9`, `ReportCrash ... type 309`) was also observed for real
/// during `mutantkit reproduce --run` against the real corpus's own
/// `mut_81f5b85a767ba6d4` (`_Lock.unlock`'s own body, broad impact across
/// every `Mutex` use) — `mutantkit` reported `Tests: failed`, matching a
/// crashed test run, not a hang.
///
/// A **removed lock-initialize call is a different class again**: both this
/// fixture and the real corpus's own `mut_a1f43429f39de818` produced no
/// observable difference at all (10/10 trials here; a real, passing test
/// run there) — `ManagedBuffer`-backed storage is zero-filled in practice,
/// and `os_unfair_lock`'s valid "unlocked" state is all-zero, so skipping
/// the explicit initializer is a silent no-op on this allocator. Not proof
/// this holds on every allocator/platform, but the two classes are
/// confirmed **not** interchangeable — including the third real candidate
/// (`mut_517333168af085a6`, a narrower unlock-removal call site that
/// survived — not exercised contended by this corpus's own test suite) and
/// the containment verification (`SwiftPackageMacOSAdapter`'s
/// `result.terminatingSignal` check correctly classifies a signal-killed
/// test process `.crashed` → `.killedByCrash`, never mistaken for a hang or
/// infrastructure issue; no orphaned processes after any real run).
///
/// Off by default like every other acceptance suite (a real, executed
/// subprocess per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: side-effect-call-removal runtime safety", .enabled(if: Acceptance.isEnabled))
struct SideEffectCallRemovalRuntimeSafetyAcceptanceTests {
    private struct RunOutcome {
        let exitCode: Int32
        let killedBySignal: Bool
        let elapsedSeconds: Double
    }

    /// Compiles `source` and runs it, bounded by `timeoutSeconds`. Reports
    /// whether the process was killed by a signal (a crash — the shape this
    /// suite's own unlock-removal fixture produces) versus exited normally,
    /// distinct from `nil` (still running when the bound expired — a
    /// genuine hang, not what either fixture here actually produces, but
    /// checked for explicitly rather than assumed away).
    private func run(_ source: String, timeoutSeconds: Double) throws -> RunOutcome? {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("sideeffect-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let sourceFile = workDir.appendingPathComponent("main.swift")
        try Data(source.utf8).write(to: sourceFile)
        let binary = workDir.appendingPathComponent("main")

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", "-O", sourceFile.path, "-o", binary.path]
        compile.standardOutput = Pipe()
        compile.standardError = Pipe()
        try compile.run()
        compile.waitUntilExit()
        #expect(compile.terminationStatus == 0, "fixture itself must compile cleanly")

        let process = Process()
        process.executableURL = binary
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        let startedAt = Date()
        try process.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        return RunOutcome(
            exitCode: process.terminationStatus,
            killedBySignal: process.terminationReason == .uncaughtSignal,
            elapsedSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    /// `operatorID: nil` returns `source` unmodified — the original,
    /// unmutated program, used as this fixture's own negative control.
    private func mutatedSource(_ source: String, from operatorID: String?, matching needle: String) throws -> String {
        guard let operatorID else { return source }
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(
            points.first { $0.originalText.contains(needle) },
            "expected a discovered candidate containing \(needle)"
        )
        return try String(decoding: MutationApplication.apply(point, to: Data(source.utf8)).mutatedSource, as: UTF8.self)
    }

    private static let lockSource = """
    import os
    import Foundation

    func withLock<T>(_ lock: UnsafeMutablePointer<os_unfair_lock>, _ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    lock.initialize(to: os_unfair_lock())

    let sem1 = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = withLock(lock) { 1 }
        sem1.signal()
    }
    sem1.wait()

    let sem2 = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        _ = withLock(lock) { 2 }
        sem2.signal()
    }
    sem2.wait()
    print("done")
    """

    @Test("Removing an unlock call inside a defer crashes the next contended lock attempt — a fast, deterministic kill, not a hang")
    func unlockInsideDeferRemovalCrashesOnContendedReacquisition() throws {
        let original = try mutatedSource(Self.lockSource, from: nil, matching: "")
        let originalRun = try #require(try run(original, timeoutSeconds: 5), "the original, unmutated program must terminate, not hang")
        #expect(originalRun.exitCode == 0, "the original program must exit cleanly")
        #expect(!originalRun.killedBySignal, "the original program must not crash")

        let mutated = try mutatedSource(Self.lockSource, from: "swift.core.side-effect-call-removal", matching: "os_unfair_lock_unlock")
        // Bounded generously (5s) even though the real signature is a fast
        // kill (observed: well under 1s) — a hang would still show up as
        // `nil` here, it would just take the full bound to detect.
        let mutantRun = try run(mutated, timeoutSeconds: 5)
        #expect(mutantRun != nil, "this mutation crashes fast — it must not still be running after 5s")
        #expect(
            mutantRun?.killedBySignal == true,
            """
            with the unlock call gone, the second thread's contended lock attempt must be killed by \
            os_unfair_lock's own corruption/staleness detector
            """
        )
    }

    @Test("Removing the lock's own initialize call produces no observable difference — a silent survivor, not a crash or a hang")
    func lockInitializeRemovalIsUndetectable() throws {
        let original = try mutatedSource(Self.lockSource, from: nil, matching: "")
        let originalRun = try #require(try run(original, timeoutSeconds: 5))
        #expect(originalRun.exitCode == 0)

        let mutated = try mutatedSource(
            Self.lockSource, from: "swift.core.side-effect-call-removal", matching: "lock.initialize(to: os_unfair_lock())"
        )
        let mutantRun = try #require(
            try run(mutated, timeoutSeconds: 5),
            "this mutation must not hang either — it is a silent no-op, not a hazard of any kind"
        )
        #expect(
            mutantRun.exitCode == 0 && !mutantRun.killedBySignal,
            """
            `ManagedBuffer`-backed storage is zero-filled in practice, and os_unfair_lock's own valid \
            \"unlocked\" state is all-zero — skipping the explicit initializer is a silent no-op on this \
            allocator, distinct from the unlock-removal class above
            """
        )
    }
}
