import Foundation

/// The unmutated build, run against the same tests a kill's retest ran, in the
/// same kind of context.
///
/// Raw runner observation: it decides nothing. `judge(killFailingTests:)` is the
/// one rule that turns it into evidence, and only `MutationVerdictVerifier` calls
/// it. A kill's retest runs the same built artifact the first run did, so a
/// failure caused by the environment or the test ordering rather than by the
/// mutation reproduces identically; passing the same tests on the unmutated
/// build is what rules that out.
public struct BaselineControlObservation: Codable, Sendable {
    public let method: AssertionKillConfirmation.Control.Method
    public let run: TestRunResult
    /// `-only-testing:`-style identifiers the control run was narrowed to;
    /// `nil` or empty means the full configured list ran.
    public let selectedTests: [String]?

    public init(method: AssertionKillConfirmation.Control.Method, run: TestRunResult, selectedTests: [String]?) {
        self.method = method
        self.run = run
        self.selectedTests = selectedTests
    }

    /// What the control established about the tests that failed under the
    /// mutation (`killFailingTests`).
    ///
    /// `passedOnBaseline` needs all of: a recorded summary that ran at least one
    /// test, none of the tests that failed under the mutation failing on the
    /// unmutated build (a passing run, or a failing one whose named failures are
    /// all other tests), and a selection that covers every named failing test.
    /// A crashed control, or one that failed the same tests or names none, is
    /// `failedOnBaseline`;
    /// anything else (no verdict, timeout, no per-test summary, a selection that
    /// misses a failing test) is `notEstablished`, never a pass.
    func judge(killFailingTests: [String]?) -> AssertionKillConfirmation.Control {
        let status = judgedStatus(killFailingTests: killFailingTests)
        let restricted = (selectedTests ?? []).isEmpty ? nil : selectedTests?.count
        return AssertionKillConfirmation.Control(
            status: status, method: method, runStatus: run.status.rawValue,
            selectedTestCount: restricted, failingTests: run.summary?.failingTests
        )
    }

    private func judgedStatus(killFailingTests: [String]?) -> AssertionKillConfirmation.Control.Status {
        switch run.status {
        case .crashed:
            return .failedOnBaseline
        case .timedOut, .infrastructureFailure:
            return .notEstablished
        case .failed:
            // Other tests failing on the unmutated build do not by themselves
            // say anything about the tests that failed under the mutation; only
            // a named overlap (or no names to compare) does.
            guard let named = run.summary?.failingTests, !named.isEmpty, let killed = killFailingTests, !killed.isEmpty,
                  Set(named.map(AssertionKillAttribution.testKey)).isDisjoint(with: killed.map(AssertionKillAttribution.testKey))
            else { return .failedOnBaseline }
        case .passed:
            break
        }
        guard let summary = run.summary, summary.total > 0 else { return .notEstablished }
        if run.status == .passed, summary.failed != 0 || !summary.failingTests.isEmpty { return .notEstablished }
        let execution = TestExecutionRecord(attribution: .standalone, selectedTests: selectedTests)
        let coverage = AssertionKillAttribution.evaluate(execution: execution, failingTests: killFailingTests)
        return coverage.disposition.admitsKill ? .passedOnBaseline : .notEstablished
    }
}
