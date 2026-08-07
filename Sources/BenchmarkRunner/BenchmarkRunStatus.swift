import Foundation

/// The benchmark run's own machine-readable completion status — read this
/// before reading any number in the report. `usabilityCompletePerformanceBlocked`
/// exists specifically so a run that finished everything it could
/// (harness, preflight, current-toolchain usability) but never obtained a
/// side-by-side performance comparison is never confused with either a
/// fully finished run or an abandoned one.
public enum BenchmarkCompletionStatus: String, Codable, Sendable {
    case complete
    case usabilityCompletePerformanceBlocked
    case incomplete
}

/// One lane's own status — `current` and `compatibility` are tracked
/// independently, since one can be `completed` while the other is
/// `blockedMissingToolchain` (exactly this run's own case).
public enum BenchmarkLaneStatus: String, Codable, Sendable {
    case completed
    case blockedMissingToolchain
    case blockedNoComparableProjects
    case incomplete
}

/// What actually happened when this benchmark tried to recover a run it
/// expected to find still in progress or already finished — never
/// `timeout`, `crash`, or `success`, because none of those were observed;
/// only that the run's own working state (task, process, log) could not be
/// located. Recorded so a run neither counts as a measurement nor
/// disappears silently.
public struct UnrecoverableRunRecord: Codable, Sendable, Equatable {
    public enum Classification: String, Codable, Sendable {
        case unrecoverableInterruptedRun
    }

    public let taskIdentifier: String
    public let previousPID: Int32?
    public let expectedLogPath: String
    public let taskFound: Bool
    public let processRunning: Bool
    public let logPathPresent: Bool
    public let parentDirectoryPresent: Bool
    public let classification: Classification
    public let includedInPerformanceAggregation: Bool

    public init(
        taskIdentifier: String, previousPID: Int32?, expectedLogPath: String, taskFound: Bool,
        processRunning: Bool, logPathPresent: Bool, parentDirectoryPresent: Bool,
        classification: Classification = .unrecoverableInterruptedRun, includedInPerformanceAggregation: Bool = false
    ) {
        self.taskIdentifier = taskIdentifier
        self.previousPID = previousPID
        self.expectedLogPath = expectedLogPath
        self.taskFound = taskFound
        self.processRunning = processRunning
        self.logPathPresent = logPathPresent
        self.parentDirectoryPresent = parentDirectoryPresent
        self.classification = classification
        self.includedInPerformanceAggregation = includedInPerformanceAggregation
    }
}

/// The run-level summary written alongside `report.md`/`report.html` —
/// this is the one artifact a caller should check programmatically before
/// trusting any number in the human-readable report, since prose can drift
/// but this struct's own fields cannot silently claim more than what was
/// actually measured.
public struct BenchmarkRunSummary: Codable, Sendable {
    public let completionStatus: BenchmarkCompletionStatus
    public let currentLaneStatus: BenchmarkLaneStatus
    public let compatibilityLaneStatus: BenchmarkLaneStatus
    public let unrecoverableRuns: [UnrecoverableRunRecord]

    public init(
        completionStatus: BenchmarkCompletionStatus, currentLaneStatus: BenchmarkLaneStatus,
        compatibilityLaneStatus: BenchmarkLaneStatus, unrecoverableRuns: [UnrecoverableRunRecord] = []
    ) {
        self.completionStatus = completionStatus
        self.currentLaneStatus = currentLaneStatus
        self.compatibilityLaneStatus = compatibilityLaneStatus
        self.unrecoverableRuns = unrecoverableRuns
    }
}
