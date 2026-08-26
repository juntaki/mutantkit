import XCTest

/// A test that hangs forever, but only when explicitly asked to — every other
/// run of this fixture (every other acceptance suite sharing `CheckoutTests`,
/// including whole-suite baseline establishment) must see this test return
/// instantly, or it would hang unrelated suites that never intended to
/// exercise a hang at all.
///
/// Exists for the Gate 3 batch-hang-containment spike: whether XCTest's own
/// `-test-timeouts-enabled`/`-maximum-test-execution-time-allowance` can cut
/// a single hanging test off inside a batched `.xctestrun` without killing
/// the whole `xcodebuild` invocation, so one hang no longer holds an entire
/// batch's combined outer timeout hostage. See
/// `Research/benchmarks/gate3-ios-schemata-2026-08-23/GATE3-RESULT.md`.
final class HangSpikeTests: XCTestCase {
    func testIntentionalHang() {
        guard ProcessInfo.processInfo.environment["MUTANTKIT_SPIKE_HANG"] == "1" else { return }
        while true {
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
