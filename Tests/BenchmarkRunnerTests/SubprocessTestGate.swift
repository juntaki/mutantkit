import Testing

/// Cross-suite mutual exclusion for tests in *this* target that spawn a real
/// OS subprocess — the `BenchmarkRunnerTests` twin of
/// `Tests/MutantKitTests/Support/SubprocessTestGate.swift`. See that file's
/// own doc comment for the full rationale (a real public-CI reliability
/// investigation, `Research/mutation-testing-hardening-2026-08/PROGRESS.md`)
/// and why a naive actor-wrapping-a-closure is not sufficient (reentrancy).
///
/// **Deliberately a separate type, not a shared one**: `BenchmarkRunnerTests`
/// and `MutantKitTests` are different SwiftPM test targets with no existing
/// common library dependency, so a single shared actor instance would need a
/// new SwiftPM library target introduced purely to host it. Not done here:
/// every real CI failure this session traced to real-subprocess contention
/// has been in `MutantKitTests` specifically; nothing in `BenchmarkRunnerTests`
/// has ever been observed to flake this way. `swift test` does link every
/// test target into one combined binary, so in principle a test here could
/// still contend with a gated `MutantKitTests` test — if that combination is
/// ever observed to matter for real, unify the two into one shared module at
/// that point rather than speculatively before there's evidence for it.
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
    static var subprocessExclusive: Self { SubprocessExclusiveTrait() }
}
