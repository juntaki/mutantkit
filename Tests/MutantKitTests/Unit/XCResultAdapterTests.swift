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

    /// Captured shape from a real `xcodebuild test-without-building
    /// -test-timeouts-enabled YES -maximum-test-execution-time-allowance 60`
    /// run against a genuinely hanging test (Gate 3 Phase H1 spike,
    /// `XcodeBatchHangTimeoutSpikeAcceptanceTests`). `issueType` (not
    /// modelled here — confirmed separately to read `"Uncategorized"` for
    /// this exact bundle, same as an ordinary assertion failure) is not
    /// what distinguishes this; `failureText`'s fixed prefix is.
    private static let nativeTimeoutSummary = Data("""
    {
        "devicesAndConfigurations": [],
        "expectedFailures": 0,
        "failedTests": 1,
        "passedTests": 0,
        "result": "Failed",
        "skippedTests": 0,
        "testFailures": [
            {
                "failureText": "Test exceeded execution time allowance of 1 minute. The test may have hung; check Xcode's test report for additional diagnostics.",
                "targetName": "CheckoutTests",
                "testIdentifier": 2,
                "testIdentifierString": "HangSpikeTests/testIntentionalHang()",
                "testName": "testIntentionalHang()"
            }
        ],
        "totalTestCount": 1
    }
    """.utf8)

    /// A contrived crash *and* native-timeout mix in the same configuration
    /// — not observed in a real bundle, but locks the precedence H2-2
    /// specifies: a crash anywhere in the configuration wins over a
    /// timeout anywhere else in it, the same way a crash already wins over
    /// an ordinary failure.
    private static let crashAndNativeTimeoutSummary = Data("""
    {
        "devicesAndConfigurations": [],
        "expectedFailures": 0,
        "failedTests": 2,
        "passedTests": 0,
        "result": "Failed",
        "skippedTests": 0,
        "testFailures": [
            {
                "failureText": "Test exceeded execution time allowance of 1 minute.",
                "targetName": "CheckoutTests",
                "testIdentifier": 1,
                "testIdentifierString": "HangSpikeTests/testIntentionalHang()",
                "testName": "testIntentionalHang()"
            },
            {
                "failureText": "Crash: xctest at CrashProbeTests.testCrashes()",
                "targetName": "CheckoutTests",
                "testIdentifier": 2,
                "testIdentifierString": "CrashProbeTests/testCrashes()",
                "testName": "testCrashes()"
            }
        ],
        "totalTestCount": 2
    }
    """.utf8)

    /// A native timeout alongside an unrelated ordinary assertion failure
    /// in the same configuration — locks the other half of H2-2's
    /// precedence: timeout wins over an ordinary failure, the same way a
    /// crash wins over one.
    private static let nativeTimeoutAndOrdinaryFailureSummary = Data("""
    {
        "devicesAndConfigurations": [],
        "expectedFailures": 0,
        "failedTests": 2,
        "passedTests": 0,
        "result": "Failed",
        "skippedTests": 0,
        "testFailures": [
            {
                "failureText": "Test exceeded execution time allowance of 1 minute.",
                "targetName": "CheckoutTests",
                "testIdentifier": 1,
                "testIdentifierString": "HangSpikeTests/testIntentionalHang()",
                "testName": "testIntentionalHang()"
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

    @Test("XCTest's own native execution-time allowance is classified timedOut, not failed")
    func nativeTimeoutIsClassifiedTimedOut() throws {
        let outcome = try classify(Self.nativeTimeoutSummary)
        #expect(outcome.status == .timedOut)
    }

    @Test("A crash still wins over a native timeout in the same configuration")
    func crashWinsOverNativeTimeout() throws {
        let outcome = try classify(Self.crashAndNativeTimeoutSummary)
        #expect(outcome.status == .crashed)
    }

    @Test("A native timeout wins over an ordinary assertion failure in the same configuration")
    func nativeTimeoutWinsOverOrdinaryFailure() throws {
        let outcome = try classify(Self.nativeTimeoutAndOrdinaryFailureSummary)
        #expect(outcome.status == .timedOut)
    }

    @Test("issueType is never consulted — failureText's structured prefix alone drives the timedOut classification")
    func nativeTimeoutClassificationDoesNotDependOnIssueType() throws {
        // `TestSummaryJSON`/`Failure` model no `issueType` field at all —
        // confirmed directly (Gate 3 Phase H1) that Apple's own value for
        // it ("Uncategorized") is identical for a native timeout and a
        // plain `XCTFail`, so it cannot be the discriminator. This test
        // exists so a future attempt to reintroduce an `issueType`-based
        // check has something concrete to fail against: decoding
        // `nativeTimeoutSummary` (which carries no `issueType` key) still
        // classifies as `.timedOut` from `failureText` alone.
        let outcome = try classify(Self.nativeTimeoutSummary)
        #expect(outcome.status == .timedOut)
    }

    @Test("A failure record with no duration at all (the single, unbatched path) still classifies as timedOut")
    func nativeTimeoutWithoutDurationCorroborationStillClassifies() throws {
        // The single-run `test-results summary` shape (unlike the batch
        // tree) never carries a per-failure duration — `durationInSeconds`
        // decodes to `nil`. Corroboration must be optional, never gating.
        let summary = try JSONDecoder().decode(TestSummaryJSON.self, from: Self.nativeTimeoutSummary)
        #expect(summary.testFailures?.first?.durationInSeconds == nil)
        #expect(XCResultAdapter().classify(summary: summary).status == .timedOut)
    }
}

// MARK: - A different real failureText wording for the same synthetic-pseudo-test shape

/// Split from the main suite above purely to keep that struct's body under
/// SwiftLint's `type_body_length`; same suite in spirit.
extension XCResultAdapterTests {
    /// Captured from a real two-independent-target Xcode project (Xcode
    /// 26.6.0): `TargetA`'s bundle crashed at *launch* (a C
    /// `__attribute__((constructor))` calling `abort()`, simulating a
    /// mutation that breaks a static/global initializer rather than causing
    /// a compile error) while independent `TargetBTests` ran normally in
    /// the same `xcodebuild test` invocation. Same *shape* as
    /// `partialTargetLaunchFailureSummary` above, but a **different, real**
    /// `failureText` wording than the one fixed prefix `isSystemFailure`
    /// used to check — see that property's own doc comment for why this
    /// fixture is what proved the fix necessary.
    private static let earlyBootstrapFailureSummary = Data("""
    {
        "devicesAndConfigurations": [
            {
                "expectedFailures": 0,
                "failedTests": 1,
                "passedTests": 1,
                "skippedTests": 0,
                "testPlanConfiguration": {
                    "configurationId": "1",
                    "configurationName": "Test Scheme Action"
                }
            }
        ],
        "expectedFailures": 0,
        "failedTests": 1,
        "passedTests": 1,
        "result": "Failed",
        "skippedTests": 0,
        "testFailures": [
            {
                "failureText": "Early unexpected exit, operation never finished bootstrapping - no restart will be attempted. (Underlying Error: The test runner crashed while preparing to run tests: xctest at <external symbol>)",
                "targetName": "TargetATests",
                "testIdentifier": 1,
                "testIdentifierString": "xctest (88732) encountered an error",
                "testName": "xctest (88732) encountered an error"
            }
        ],
        "totalTestCount": 2
    }
    """.utf8)

    @Test(
        """
        A target crashing at launch (a different real failureText wording than "Failed to install or launch") is \
        still infrastructureFailure, never a kill credited to the synthetic runner-crash pseudo-test
        """
    )
    func earlyBootstrapFailureIsInfrastructureFailureNotAFabricatedKill() throws {
        let outcome = try classify(Self.earlyBootstrapFailureSummary)
        #expect(outcome.status == .infrastructureFailure)
    }
}

// MARK: - expectedTestCount: the zero-work invariant for a narrowed selection

/// Split into its own extension for the same `type_body_length` reason as above.
extension XCResultAdapterTests {
    /// A narrowed run (`selectedTests` of 2) whose bundle reports only 1
    /// test, cleanly "Passed", with nothing else here to explain the
    /// shortfall — no crash, no timeout, no attributable/system failure.
    /// This is the shape a target vanishing from the bundle *without even
    /// a synthetic pseudo-test failure record* would produce: only the
    /// missing count itself proves something did not run.
    private static let shortfallWithNoFailureRecordSummary = Data("""
    {
        "devicesAndConfigurations": [],
        "expectedFailures": 0,
        "failedTests": 0,
        "passedTests": 1,
        "result": "Passed",
        "skippedTests": 0,
        "testFailures": [],
        "totalTestCount": 1
    }
    """.utf8)

    @Test("A narrowed selection reporting fewer tests than expected, with no failure explaining why, is infrastructureFailure")
    func narrowedShortfallWithNoExplanationIsInfrastructureFailure() throws {
        let summary = try JSONDecoder().decode(TestSummaryJSON.self, from: Self.shortfallWithNoFailureRecordSummary)
        let outcome = XCResultAdapter().classify(summary: summary, expectedTestCount: 2)
        #expect(outcome.status == .infrastructureFailure)
    }

    @Test("The same shortfall is not flagged when the caller has no independently-known expected count")
    func shortfallWithNoExpectedCountIsUnaffected() throws {
        // An unnarrowed run (nil expectedTestCount) has no exact number to
        // compare against -- a lower count there can be a legitimate test
        // plan/filtering difference, not evidence of anything missing.
        let summary = try JSONDecoder().decode(TestSummaryJSON.self, from: Self.shortfallWithNoFailureRecordSummary)
        let outcome = XCResultAdapter().classify(summary: summary, expectedTestCount: nil)
        #expect(outcome.status == .passed)
    }

    @Test("A narrowed selection whose count matches exactly is an ordinary pass")
    func narrowedCountMatchIsAnOrdinaryPass() throws {
        let summary = try JSONDecoder().decode(TestSummaryJSON.self, from: Self.shortfallWithNoFailureRecordSummary)
        let outcome = XCResultAdapter().classify(summary: summary, expectedTestCount: 1)
        #expect(outcome.status == .passed)
    }
}
