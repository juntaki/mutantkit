import XCTest

@testable import Checkout

/// Gate 3 Phase H3-3: real, non-mocked production-path validation of
/// `XcodeBuildAdapter.runBatch`'s native-timeout containment wiring —
/// `MutationRunner.testOneBatch`/`testWaveChunk`'s actual caller, not a
/// hand-built spike. Both hang methods below hang *unconditionally* — safe
/// only because this whole target belongs to the isolated
/// `HangContainmentDemo` scheme (see `project.yml`), never built or run by
/// the "Checkout" scheme every other acceptance suite (and mutantkit's own
/// baseline establishment) uses.
final class HangContainmentTests: XCTestCase {
    func testPassesA() {
        XCTAssertTrue(Checkout.canApplyCoupon(subtotal: 21))
    }

    /// A cooperative hang — sleeps, yielding the thread every second.
    /// Confirmed (Gate 3 Phase H1) that XCTest's own native per-test
    /// execution-time allowance cleanly preempts exactly this shape.
    func testHangs() {
        while true {
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// A non-cooperative hang — Gate 3 Phase H8's attempted regression
    /// fixture for Phase H7's real, large-production-iOS-app finding, in a
    /// fast, controlled, production-app-independent form. Mirrors the
    /// actual production mutation (`mut_70d5b52e5bb74306`, an inverted
    /// loop-termination condition in a real varint-encoding write path) in
    /// the properties that matter: a tight loop with no
    /// `Thread.sleep`/explicit yield point,
    /// growing memory continuously (bounded at a 1 GiB ceiling here, not
    /// truly unbounded, to avoid exhausting the test machine).
    ///
    /// **Does not fully reproduce Phase H7's severity** — recorded
    /// honestly, not smoothed over. Phase H8's own spike tried this at
    /// both 1 GiB and 4 GiB ceilings (the latter run for the real 272s
    /// production allowance) and both were still recovered cleanly by
    /// XCTest's native timeout; a separate app-hosted variant
    /// (`HangAppTests.testMainThreadCPUBoundHang`) blocking a real app's
    /// main thread was *also* recovered, via a faster, different
    /// mechanism (the process crashed with `SIGTRAP`, presumably an
    /// OS-level unresponsive-app watchdog, distinct from
    /// `-maximum-test-execution-time-allowance`). None of the three
    /// reproduce Phase H7's actual observation — the whole batch surviving
    /// with zero self-recovery until MutantKit's own outer supervisor
    /// killed it at the full aggregate timeout. What specifically differs
    /// in the real production app/environment is not identified. Kept as a
    /// fixture anyway: still a materially harder case than
    /// `testHangs`'s cooperative sleep for exercising watchdog logic
    /// (Phase H9+) against, even though it is not proof that logic would
    /// have caught Phase H7 itself — only Phase H12's re-run against the
    /// real production app is.
    func testCPUBoundHang() {
        var buffer = Data()
        let chunk = Data(repeating: 0xAB, count: 1 << 20) // 1 MiB per iteration
        let ceiling = 1 << 30 // 1 GiB — real memory pressure, not true unbounded growth
        while true {
            if buffer.count < ceiling {
                buffer.append(chunk)
            }
        }
    }

    func testPassesC() {
        XCTAssertTrue(Checkout.canApplyCoupon(subtotal: 20))
    }
}

/// Gate 4 Phase G4.2/G4.3: a minimal, deterministic fixture for the
/// external-semantic-bail spike — one passing test, one test with a real,
/// deterministic assertion failure, and one slow-but-passing test standing
/// in for "a covering test that should never run once the mutant is already
/// dead." Kept in its own class (same isolated `HangContainmentDemo` scheme,
/// same target — no `project.yml`/`xcodegen generate` change needed) so
/// this fixture's own three-test suite composition never drifts if
/// `HangContainmentTests` above changes.
final class Gate4FirstDetectionBailTests: XCTestCase {
    func testA_passes() {
        XCTAssertTrue(Checkout.canApplyCoupon(subtotal: 21))
    }

    /// A real, deterministic assertion failure — not a crash, not a hang —
    /// the "mutant already proven dead" signal G4.2's spike exists to
    /// detect and react to before `testC_slowButPasses` ever runs.
    func testB_deterministicFailure() {
        XCTAssertTrue(Checkout.canApplyCoupon(subtotal: -1), "deterministic failure for Gate 4's bail spike")
    }

    /// Stands in for "a covering test that should never run once the
    /// mutant is already dead" — long enough that its own completion is
    /// unambiguous evidence the external bail did not fire in time, short
    /// enough not to waste real wall time when a spike run's own control
    /// case (no bail) needs to let it finish.
    func testC_slowButPasses() {
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(Checkout.canApplyCoupon(subtotal: 20))
    }
}

/// Gate 4 Phase G4.3: the timeout-triggered counterpart to
/// `Gate4FirstDetectionBailTests` above — same A/B/C shape, but B is a
/// native-XCTest-timeout trigger (a cooperative, `Thread.sleep`-based
/// infinite loop, the exact shape Phase H1 confirmed is reliably preempted
/// by `-test-timeouts-enabled`/`-maximum-test-execution-time-allowance`;
/// a non-cooperative CPU-bound hang, per Phase H7/H8, is *not* reliably
/// preempted by native timeout and would make this fixture's own trigger
/// unreliable) instead of a deterministic assertion failure.
final class Gate4TimeoutBailTests: XCTestCase {
    func testA_passes() {
        XCTAssertTrue(Checkout.canApplyCoupon(subtotal: 21))
    }

    /// Cooperative — sleeps, yielding the thread every second. Mirrors
    /// `HangContainmentTests.testHangs` above, the same shape Phase H1
    /// proved is reliably caught by XCTest's own native per-test timeout.
    func testB_nonYieldingTimeout() {
        while true {
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Same role as `Gate4FirstDetectionBailTests.testC_slowButPasses`:
    /// long enough that its own completion is unambiguous evidence the
    /// bail did not fire in time.
    func testC_slowButPasses() {
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(Checkout.canApplyCoupon(subtotal: 20))
    }
}
