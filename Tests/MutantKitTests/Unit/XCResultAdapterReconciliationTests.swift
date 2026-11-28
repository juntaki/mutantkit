@testable import AppleBuildAdapters
import Foundation
import Testing

/// A single (non-batch) result must account for every selected test: its
/// counts agree with each other, skips and expected failures are explicit, and
/// a result that cannot be reconciled is `.infrastructureFailure`, never a pass.
@Suite("XCResultAdapter: single-result reconciliation")
struct XCResultAdapterReconciliationTests {
    private static func summary(
        result: String = "Passed", total: Int, passed: Int, failed: Int = 0,
        skipped: Int = 0, expectedFailures: Int = 0, failures: [TestSummaryJSON.Failure] = []
    ) -> TestSummaryJSON {
        TestSummaryJSON(
            result: result, totalTestCount: total, passedTests: passed, failedTests: failed,
            skippedTests: skipped, expectedFailures: expectedFailures, testFailures: failures,
            startTime: nil, finishTime: nil
        )
    }

    private static let assertionFailure: TestSummaryJSON.Failure = {
        let json = Data("""
        {"testName": "testA()", "targetName": "T", "failureText": "XCTAssertEqual failed", \
        "testIdentifierString": "T/Suite/testA()"}
        """.utf8)
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(TestSummaryJSON.Failure.self, from: json)
    }()

    @Test("A selection that was entirely skipped is not a pass")
    func allSkippedIsNotAPass() {
        let outcome = XCResultAdapter().classify(
            summary: Self.summary(total: 2, passed: 0, skipped: 2), expectedTestCount: 2
        )
        #expect(outcome.status == .infrastructureFailure)
    }

    @Test("A selection with an intentional skip next to real passes is still a pass")
    func partialSkipIsAPass() {
        let outcome = XCResultAdapter().classify(
            summary: Self.summary(total: 3, passed: 2, skipped: 1), expectedTestCount: 3
        )
        #expect(outcome.status == .passed)
    }

    @Test("A run whose only executed test is an expected failure is a pass")
    func expectedFailureOnlyIsAPass() {
        let outcome = XCResultAdapter().classify(
            summary: Self.summary(total: 1, passed: 0, expectedFailures: 1), expectedTestCount: 1
        )
        #expect(outcome.status == .passed)
    }

    @Test("Counts that do not add up to the total are not a pass")
    func unaccountedTestsAreNotAPass() {
        let outcome = XCResultAdapter().classify(
            summary: Self.summary(total: 3, passed: 1), expectedTestCount: 3
        )
        #expect(outcome.status == .infrastructureFailure)
    }

    @Test("Counts that exceed the total contradict it and are not a pass")
    func overcountedPartsAreNotAPass() {
        let outcome = XCResultAdapter().classify(summary: Self.summary(total: 2, passed: 3))
        #expect(outcome.status == .infrastructureFailure)
    }

    @Test("A negative count is not a pass")
    func negativeCountIsNotAPass() {
        let outcome = XCResultAdapter().classify(summary: Self.summary(total: 1, passed: 2, skipped: -1))
        #expect(outcome.status == .infrastructureFailure)
    }

    @Test("A failure record with a zero failed count is contradictory, not a kill")
    func failureRecordWithoutFailedCountIsNotAKill() {
        let outcome = XCResultAdapter().classify(
            summary: Self.summary(total: 1, passed: 1, failures: [Self.assertionFailure])
        )
        #expect(outcome.status == .infrastructureFailure)
    }

    @Test("A genuine assertion failure is still a failure despite an incomplete selection")
    func assertionFailureSurvivesShortfall() {
        let outcome = XCResultAdapter().classify(
            summary: Self.summary(
                result: "Failed", total: 1, passed: 0, failed: 1, failures: [Self.assertionFailure]
            ),
            expectedTestCount: 3
        )
        #expect(outcome.status == .failed)
    }

    @Test("A crash or timeout record with a zero failed count is contradictory, not a kill")
    func crashRecordWithoutFailedCountIsNotAKill() throws {
        for text in ["Crash: xctest (1234) encountered an error", "Test exceeded execution time allowance of 5.0 seconds"] {
            let json = Data("""
            {"testName": "testA()", "targetName": "T", "failureText": "\(text)", "testIdentifierString": "T/Suite/testA()"}
            """.utf8)
            let failure = try JSONDecoder().decode(TestSummaryJSON.Failure.self, from: json)
            let outcome = XCResultAdapter().classify(summary: Self.summary(total: 1, passed: 1, failures: [failure]))
            #expect(outcome.status == .infrastructureFailure, "\(text)")
        }
    }
}
