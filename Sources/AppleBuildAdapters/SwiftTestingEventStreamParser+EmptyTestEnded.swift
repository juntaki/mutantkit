import Foundation
import MutationExecution

/// Newer Swift Testing helpers (Xcode 27) end a function-level test with a
/// `testEnded` event whose `messages` is empty, for a passing and a failing
/// test alike; only a parameterized function's aggregated `testEnded`, a
/// suite's and `runEnded` still carry a `pass` or `fail` symbol. The event
/// itself therefore proves nothing, and a verdict is only ever derived from
/// the rest of the stream, never presumed:
///
/// - a `fail` issue recorded for the test makes it failed;
/// - no issue of any kind recorded for the test, together with a run summary
///   (`runEnded`) that reports a pass and no failure, makes it passed;
/// - everything else (a known-issue or otherwise non-failing issue, no run
///   summary, a failing or unrecognized run summary) is unsupported evidence.
extension SwiftTestingEventStreamParser {
    /// Verdict-less `testEnded` events and the issue/run facts needed to
    /// decide them once the whole stream has been read.
    struct PendingVerdicts {
        var endedWithoutMessages: Set<TestIdentifier> = []
        var issueSymbols: [TestIdentifier: Set<String>] = [:]
        var runSummarySymbols: Set<String> = []
    }

    /// Remembers which message symbols an `issueRecorded` carried, per test.
    /// An issue without a `testID`, or one naming a suite or an undeclared
    /// test, is not tied to a leaf test here; the run summary covers it.
    static func recordIssue(
        symbols: Set<String>, payload: [String: Any], declaredTests: Set<TestIdentifier>, pending: inout PendingVerdicts
    ) {
        guard let rawID = payload["testID"] as? String,
              let identifier = testIdentifier(fromEventStreamID: rawID),
              declaredTests.contains(identifier)
        else { return }
        pending.issueSymbols[identifier, default: []].formUnion(symbols)
    }

    static func resolveTestsEndedWithoutMessages(
        pending: PendingVerdicts, evidence: inout RunEvidence
    ) throws {
        for identifier in pending.endedWithoutMessages {
            let issues = pending.issueSymbols[identifier] ?? []
            if issues.contains("fail") {
                evidence.failedTests.insert(identifier)
                continue
            }
            guard issues.isEmpty else {
                throw UnsupportedEvidence(
                    reason: "\(identifier)'s testEnded carried no verdict and its recorded issues are not failures (symbols: \(issues))"
                )
            }
            guard evidence.startedTests.contains(identifier) else {
                throw UnsupportedEvidence(reason: "\(identifier) ended without a message and was never started")
            }
            guard evidence.runEnded, pending.runSummarySymbols.contains("pass"), !pending.runSummarySymbols.contains("fail") else {
                throw UnsupportedEvidence(
                    reason: "\(identifier)'s testEnded carried no verdict and the run summary does not report a clean pass (symbols: \(pending.runSummarySymbols))"
                )
            }
            evidence.passedTests.insert(identifier)
        }
    }
}
