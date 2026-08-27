import Testing

/// Cross-suite mutual exclusion for tests that spawn a real OS subprocess.
///
/// Part of the mutation-testing hardening program's CI-reliability follow-up
/// (`Research/mutation-testing-hardening-2026-08/PROGRESS.md`, P1 → C2).
/// Real public CI failures traced a recurring flake to real contention: a
/// GitHub-hosted macOS runner (confirmed 3 vCPUs) running many real-
/// subprocess-spawning tests concurrently — `xcodebuild`, `simctl`,
/// `ProcessSupervisor`-managed children, `git`, real compiles for MachO/
/// dSYM fixtures — starves the very OS-level timing (how fast a killed
/// descendant is actually removed from the process table, how fast a real
/// simulator boots) several of these tests assert on directly.
///
/// `@Suite(.serialized)` was tried first and is not enough on its own: it
/// only stops a *single* suite's own tests from racing each other. Swift
/// Testing schedules every *other* suite fully concurrently by default —
/// `ProcessSupervisorResidueTests`' own tests kept failing in CI even after
/// being marked `.serialized`, because they were still running at the same
/// time as `XcodeConfigDetectorTests`/`XcodeBuildAdapterUninstallFailureTests`
/// (different suites, same binary, same 3 real cores).
///
/// This is a real, process-wide semaphore (an actor implementing an async
/// mutex via an explicit acquire/release pair and a continuation queue) —
/// not a naive actor method that merely `await`s a closure. Swift actors are
/// reentrant at suspension points: a plain `actor { func exclusive(_ op:
/// () async -> T) { await op() } }` would let a *second* caller's `op` start
/// running the moment the *first* caller's `op` suspends at its own internal
/// `await` (which every one of these tests does, immediately, spawning its
/// subprocess) — defeating the entire purpose. The explicit queue here holds
/// exclusivity for an operation's whole real duration, not just between its
/// own suspension points.
///
/// Applied via the `.subprocessExclusive` trait below, at `@Suite` level with
/// `isRecursive: true` — required for the trait to cascade to each
/// individual test in a multi-test suite; without it, Swift Testing invokes
/// `provideScope` once for the *suite* as a whole, and the suite's own tests
/// still run concurrently with each other inside that one scope (confirmed
/// directly against this exact Swift Testing version, 1902, in an isolated
/// throwaway probe package before trusting it here — `isRecursive` defaults
/// to `false`).
///
/// Only the specific, evidenced set of real-subprocess-spawning suites opt
/// in (see each suite's own `.subprocessExclusive` application) — the
/// overwhelming majority of this target's tests (pure-unit, no real
/// subprocess involvement) are completely unaffected and keep running at
/// full Swift Testing concurrency, exactly as before.
actor SubprocessTestGate {
    static let shared = SubprocessTestGate()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Ownership passes directly to the next queued waiter rather than
    /// releasing the lock and letting every waiter race to re-acquire it —
    /// both are correct, but handing off directly is a fairer, FIFO order,
    /// and avoids a fresh round of actor-hop scheduling overhead per handoff.
    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            isLocked = false
        }
    }

    func exclusive<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }
}

/// A `Trait` that runs every test (and, recursively, every test in a suite)
/// it is attached to through `SubprocessTestGate`, so it never overlaps with
/// any other `.subprocessExclusive`-tagged test anywhere in the binary.
struct SubprocessExclusiveTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await SubprocessTestGate.shared.exclusive(function)
    }
}

extension Trait where Self == SubprocessExclusiveTrait {
    /// Apply to a `@Suite` (recursively covering every test in it) or an
    /// individual `@Test` that spawns a real OS subprocess — a real
    /// `Process()`/`posix_spawn`, a real `xcodebuild`/`simctl`/`git`
    /// invocation, or anything that drives `ProcessSupervisor` for real.
    static var subprocessExclusive: Self { SubprocessExclusiveTrait() }
}
