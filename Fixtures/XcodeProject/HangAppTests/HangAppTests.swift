import XCTest

/// App-hosted (`IsAppHostedTestBundle: true`) counterpart to
/// `HangContainmentTests` — Gate 3 Phase H8's attempt to reproduce Phase
/// H7's real finding (native XCTest timeout failing to preempt a real
/// hang observed in a real, large production iOS app) in a fast, local,
/// production-app-independent fixture. Safe only
/// because this whole target/scheme is isolated from every other
/// acceptance suite the same way `HangContainmentTests` already is (see
/// `project.yml`).
final class HangAppTests: XCTestCase {
    func testPassesA() {
        XCTAssertTrue(true)
    }

    /// Blocks the *host app's own main thread* — not just this test's own
    /// background thread — with a tight, non-yielding, memory-growing
    /// loop. `DispatchQueue.main.sync` is what makes this different from
    /// `HangContainmentTests.testCPUBoundHang`: the app process's main run
    /// loop itself stops responding, matching how a real, UI-invoked
    /// synchronous code path (plausibly how a real production app's own
    /// binary-search-index varint-encoding write path gets reached) would
    /// actually hang.
    ///
    /// **Observed (Gate 3 Phase H8 spike), recorded honestly**: this
    /// still does not reproduce Phase H7's severity — the batch still
    /// self-recovers, and its siblings still run. But it recovers via a
    /// *different* mechanism than `testCPUBoundHang` does: the process
    /// crashes with `SIGTRAP` in roughly 20s, well under any configured
    /// `-maximum-test-execution-time-allowance`, with no "exceeded
    /// execution time allowance" message at all — plausibly an OS-level
    /// unresponsive-app watchdog independent of XCTest's own timeout
    /// machinery. Real, useful evidence that app-hosted main-thread
    /// hangs get *an additional* containment path beyond
    /// `-test-timeouts-enabled` — not evidence this is what protects
    /// against Phase H7's actual failure, which took the full outer
    /// timeout with no self-recovery signal of any kind.
    func testMainThreadCPUBoundHang() {
        DispatchQueue.main.sync {
            var buffer = Data()
            let chunk = Data(repeating: 0xAB, count: 1 << 20) // 1 MiB per iteration
            let ceiling = 1 << 30 // 1 GiB
            while true {
                if buffer.count < ceiling {
                    buffer.append(chunk)
                }
            }
        }
    }

    func testPassesC() {
        XCTAssertTrue(true)
    }
}
