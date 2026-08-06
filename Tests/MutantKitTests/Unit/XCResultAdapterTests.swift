@testable import AppleBuildAdapters
import Foundation
import Testing

/// Pins `XCResultAdapter.classify(summary:)` against real captured
/// `xcresulttool get test-results summary --compact` output, including a
/// shape that is easy to miss: a simulator failing to install or launch the
/// test runner is reported as a synthetic one-"test" failure, not as a
/// zero-test bundle. App name/bundle ID replaced with a placeholder; the
/// `failureText` itself is Xcode's own fixed wording, captured verbatim.
@Suite("XCResultAdapter: classify(summary:)")
struct XCResultAdapterTests {
    /// Captured from a real `xcodebuild test-without-building` invocation that
    /// hit a transient CoreSimulator race (a fresh install launched too soon
    /// after a preceding one) — no test in the target ever ran.
    private static let installFailureSummary = Data("""
    {
        "devicesAndConfigurations": [
            {
                "expectedFailures": 0,
                "failedTests": 1,
                "passedTests": 0,
                "skippedTests": 0,
                "testPlanConfiguration": {
                    "configurationId": "1",
                    "configurationName": "Test Scheme Action"
                }
            }
        ],
        "expectedFailures": 0,
        "failedTests": 1,
        "finishTime": 1784551509.233,
        "passedTests": 0,
        "result": "Failed",
        "skippedTests": 0,
        "startTime": 1784551487.889,
        "testFailures": [
            {
                "failureText": "Failed to install or launch the test runner. (Underlying Error: Simulator device failed to launch com.example.checkout. The request was denied by service delegate (SBMainWorkspace) for reason: Busy (\\"Application failed preflight checks\\"). (Underlying Error: The request to open \\"com.example.checkout\\" failed. The request was denied by service delegate (SBMainWorkspace) for reason: Busy (\\"Application failed preflight checks\\"). (Underlying Error: The operation couldn\\u2019t be completed. Application failed preflight checks)))",
                "targetName": "CheckoutTests",
                "testIdentifier": 1,
                "testIdentifierString": "Checkout encountered an error",
                "testName": "Checkout encountered an error"
            }
        ],
        "title": "Test - Checkout",
        "totalTestCount": 1
    }
    """.utf8)

    private static let plainAssertionFailureSummary = Data("""
    {
        "devicesAndConfigurations": [],
        "expectedFailures": 0,
        "failedTests": 1,
        "passedTests": 2,
        "result": "Failed",
        "skippedTests": 0,
        "testFailures": [
            {
                "failureText": "XCTAssertTrue failed - intentional failure for batching PoC",
                "targetName": "CheckoutTests",
                "testIdentifier": 2,
                "testIdentifierString": "AssertFailProbeTests/testFails()",
                "testName": "testFails()"
            }
        ],
        "totalTestCount": 3
    }
    """.utf8)

    private static let crashSummary = Data("""
    {
        "devicesAndConfigurations": [],
        "expectedFailures": 0,
        "failedTests": 1,
        "passedTests": 0,
        "result": "Failed",
        "skippedTests": 0,
        "testFailures": [
            {
                "failureText": "Crash: xctest at CrashProbeTests.testCrashes()",
                "targetName": "CheckoutTests",
                "testIdentifier": 3,
                "testIdentifierString": "CrashProbeTests/testCrashes()",
                "testName": "testCrashes()"
            }
        ],
        "totalTestCount": 1
    }
    """.utf8)

    /// A genuine failure alongside an unrelated system failure in the same
    /// bundle — contrived (xcresult has not been observed to mix these), but
    /// guards the `count == totalTestCount` condition: a real failure must
    /// never be swallowed just because a system failure also appears.
    private static let mixedSummary = Data("""
    {
        "devicesAndConfigurations": [],
        "expectedFailures": 0,
        "failedTests": 2,
        "passedTests": 0,
        "result": "Failed",
        "skippedTests": 0,
        "testFailures": [
            {
                "failureText": "Failed to install or launch the test runner. (Underlying Error: Busy)",
                "targetName": "CheckoutTests",
                "testIdentifier": 1,
                "testIdentifierString": "Checkout encountered an error",
                "testName": "Checkout encountered an error"
            },
            {
                "failureText": "XCTAssertTrue failed - intentional failure",
                "targetName": "CheckoutTests",
                "testIdentifier": 2,
                "testIdentifierString": "AssertFailProbeTests/testFails()",
                "testName": "testFails()"
            }
        ],
        "totalTestCount": 2
    }
    """.utf8)

    /// A contrived-but-real-shaped bundle: the aggregate count says a test
    /// failed, but `testFailures` names none. Mirrors what the batch path's
    /// `unattributedFailureBatchSummary`/`unattributedFailureBatchTree` guard
    /// against — a failure severe enough to escape any per-test attribution
    /// must never be read as a proven kill.
    private static let unattributedFailureSummary = Data("""
    {
        "devicesAndConfigurations": [],
        "expectedFailures": 0,
        "failedTests": 1,
        "passedTests": 0,
        "result": "Failed",
        "skippedTests": 0,
        "testFailures": [],
        "totalTestCount": 1
    }
    """.utf8)

    /// A codex review's exact failure shape: a bundle spanning two test
    /// targets, where one target's runner fails to install/launch (a single
    /// synthetic system-failure record, no real tests from it ever ran) while
    /// a sibling target's 8 tests actually execute and all pass.
    /// `totalTestCount` (9) counts the sibling's passes too, so the old
    /// `systemFailures.count == totalTestCount` check (1 == 9) never fired —
    /// the broken target's mutant fell through to `.failed`, credited as
    /// "caught" by a test that never ran.
    private static let partialTargetLaunchFailureSummary = Data("""
    {
        "devicesAndConfigurations": [],
        "expectedFailures": 0,
        "failedTests": 1,
        "passedTests": 8,
        "result": "Failed",
        "skippedTests": 0,
        "testFailures": [
            {
                "failureText": "Failed to install or launch the test runner. (Underlying Error: Busy)",
                "targetName": "WidgetUITests",
                "testIdentifier": 1,
                "testIdentifierString": "WidgetUITests encountered an error",
                "testName": "WidgetUITests encountered an error"
            }
        ],
        "totalTestCount": 9
    }
    """.utf8)

    private func classify(_ data: Data) throws -> XCResultAdapter.Outcome {
        let summary = try JSONDecoder().decode(TestSummaryJSON.self, from: data)
        return XCResultAdapter().classify(summary: summary)
    }

    @Test("A test runner install/launch failure is infrastructureFailure, not a kill")
    func installFailureIsInfrastructureFailure() throws {
        let outcome = try classify(Self.installFailureSummary)
        #expect(outcome.status == .infrastructureFailure)
    }

    @Test("A plain assertion failure is still classified failed")
    func plainAssertionFailureIsStillFailed() throws {
        let outcome = try classify(Self.plainAssertionFailureSummary)
        #expect(outcome.status == .failed)
    }

    @Test("A crash is still classified crashed, not caught by the system-failure check")
    func crashIsStillCrashed() throws {
        let outcome = try classify(Self.crashSummary)
        #expect(outcome.status == .crashed)
    }

    @Test("A real failure alongside a system failure is not swallowed as infrastructureFailure")
    func mixedFailureIsNotSwallowed() throws {
        let outcome = try classify(Self.mixedSummary)
        #expect(outcome.status == .failed)
    }

    @Test("A sibling target's runner-launch failure is infrastructureFailure even when another target's tests passed")
    func partialTargetLaunchFailureIsInfrastructureFailureDespitePassingSibling() throws {
        let outcome = try classify(Self.partialTargetLaunchFailureSummary)
        #expect(outcome.status == .infrastructureFailure)
    }

    @Test("A real failure count with no attributable failing test is infrastructureFailure, not a guessed kill")
    func unattributedFailureCountIsInfrastructureFailureNotAGuessedKill() throws {
        let outcome = try classify(Self.unattributedFailureSummary)
        #expect(outcome.status == .infrastructureFailure)
    }
}
