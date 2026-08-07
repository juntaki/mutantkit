@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("BenchmarkRunStatus")
struct BenchmarkRunStatusTests {
    @Test("A run summary round-trips through Codable with both lane statuses independent")
    func summaryRoundTrips() throws {
        let summary = BenchmarkRunSummary(
            completionStatus: .usabilityCompletePerformanceBlocked,
            currentLaneStatus: .completed,
            compatibilityLaneStatus: .blockedMissingToolchain,
            unrecoverableRuns: [
                UnrecoverableRunRecord(
                    taskIdentifier: "bpyg8pp2r", previousPID: 98113, expectedLogPath: "/tmp/mb-corpus/numerics-mk-run.log",
                    taskFound: false, processRunning: false, logPathPresent: false, parentDirectoryPresent: false
                )
            ]
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(BenchmarkRunSummary.self, from: data)
        #expect(decoded.completionStatus == .usabilityCompletePerformanceBlocked)
        #expect(decoded.currentLaneStatus == .completed)
        #expect(decoded.compatibilityLaneStatus == .blockedMissingToolchain)
        #expect(decoded.unrecoverableRuns.count == 1)
    }

    @Test("An unrecoverable run is never classified as timeout, crash, or success")
    func unrecoverableRunHasExactlyOneClassification() {
        let record = UnrecoverableRunRecord(
            taskIdentifier: "x", previousPID: nil, expectedLogPath: "/tmp/x.log",
            taskFound: false, processRunning: false, logPathPresent: false, parentDirectoryPresent: false
        )
        #expect(record.classification == .unrecoverableInterruptedRun)
        #expect(!record.includedInPerformanceAggregation)
    }
}
