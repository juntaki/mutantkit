/// How the test run behind one observation was executed: which tests it was
/// allowed to run, and whether the failure it reported was attributed to this
/// mutant by running it alone or by a shared batch invocation.
///
/// Raw runner observation, recorded from facts the runner already holds. It
/// decides nothing by itself: `AssertionKillAttribution.evaluate` is the one
/// judge of what it means for a kill, and the verifier is the only caller that
/// turns the result into evidence.
public struct TestExecutionRecord: Codable, Sendable, Hashable {
    /// Whether this run's failure was observed with only this mutant under
    /// test, or inside an invocation shared with other mutants and attributed
    /// to this one by the batch's per-configuration result.
    public enum Attribution: String, Codable, Sendable, Hashable {
        case standalone
        case batch
    }

    /// How far the run was narrowed.
    public enum Selection: String, Codable, Sendable, Hashable {
        /// The run executed the full configured test list.
        case wholeSuite
        /// The run was narrowed to `selectedTests`.
        case restricted
    }

    public let attribution: Attribution
    public let selection: Selection
    /// `-only-testing:`-style identifiers the run was narrowed to. Empty unless
    /// `selection == .restricted`.
    public let selectedTests: [String]

    public init(attribution: Attribution, selection: Selection, selectedTests: [String] = []) {
        self.attribution = attribution
        self.selection = selection
        self.selectedTests = selectedTests
    }

    /// A record from a runner's own optional selection: `nil` or empty means
    /// the full configured list ran (the same reading every runner already
    /// applies when it hands the selection to an adapter).
    public init(attribution: Attribution, selectedTests: [String]?) {
        if let selectedTests, !selectedTests.isEmpty {
            self.init(attribution: attribution, selection: .restricted, selectedTests: selectedTests.sorted())
        } else {
            self.init(attribution: attribution, selection: .wholeSuite)
        }
    }
}

/// What the verifier established about the tests that credited a
/// `killedByAssertion`: were they inside the selection the mutant was run
/// against, were they named at all, and how was the failure attributed.
///
/// Authored by `MutationVerdictVerifier` from the recorded observation, never
/// by the runner. `nil` on a result means only "no attribution was recorded"
/// (older report, cache or checkpoint entry); it is never evidence that the
/// kill was inside its selection, and nothing may read it as such.
public struct AssertionKillAttribution: Codable, Sendable, Hashable {
    public enum Disposition: String, Codable, Sendable, Hashable {
        /// Run narrowed to a selection, and every named failing test lies in it.
        case withinSelection
        /// The full configured list ran, so any failing test is in scope.
        case wholeSuiteRan
        /// The run reported no per-test breakdown. The kill stands on the
        /// run's status alone; this case exists to make that visible.
        case failingTestsUnnamed
        /// At least one failing test is not in the selection the run was
        /// narrowed to. The kill is not credited.
        case outsideSelection
        /// The observation carried no execution record. The kill is not
        /// credited: an unknown selection is never assumed to be fine.
        case executionNotRecorded

        /// Whether a kill with this disposition may stand.
        public var admitsKill: Bool {
            switch self {
            case .withinSelection, .wholeSuiteRan, .failingTestsUnnamed: true
            case .outsideSelection, .executionNotRecorded: false
            }
        }
    }

    public let disposition: Disposition
    /// `nil` only when the execution was not recorded.
    public let attribution: TestExecutionRecord.Attribution?
    /// Size of the selection the run was narrowed to; `nil` for a whole-suite
    /// run or an unrecorded execution.
    public let selectedTestCount: Int?
    /// The deciding run's full failing-test list; `nil` when it reported none.
    public let failingTests: [String]?
    /// The failing tests that matched nothing in the selection.
    public let unmatchedFailingTests: [String]

    public init(
        disposition: Disposition,
        attribution: TestExecutionRecord.Attribution?,
        selectedTestCount: Int?,
        failingTests: [String]?,
        unmatchedFailingTests: [String] = []
    ) {
        self.disposition = disposition
        self.attribution = attribution
        self.selectedTestCount = selectedTestCount
        self.failingTests = failingTests
        self.unmatchedFailingTests = unmatchedFailingTests
    }

    /// The single rule. `failingTests` is the deciding run's own list (`nil`
    /// when the run reported no per-test breakdown); an empty list is treated
    /// the same way, never as "no failing test is outside the selection".
    public static func evaluate(execution: TestExecutionRecord?, failingTests: [String]?) -> AssertionKillAttribution {
        guard let execution else {
            return AssertionKillAttribution(
                disposition: .executionNotRecorded, attribution: nil, selectedTestCount: nil, failingTests: failingTests
            )
        }
        let (disposition, unmatched) = judge(execution, failingTests: failingTests)
        return AssertionKillAttribution(
            disposition: disposition, attribution: execution.attribution,
            selectedTestCount: execution.selection == .restricted ? execution.selectedTests.count : nil,
            failingTests: failingTests, unmatchedFailingTests: unmatched
        )
    }

    private static func judge(_ execution: TestExecutionRecord, failingTests: [String]?) -> (Disposition, [String]) {
        if execution.selection == .restricted, execution.selectedTests.isEmpty {
            return (.outsideSelection, [])
        }
        guard let failingTests, !failingTests.isEmpty else { return (.failingTestsUnnamed, []) }
        guard execution.selection == .restricted else { return (.wholeSuiteRan, []) }
        let selected = execution.selectedTests.map(TestIdentifier.init)
        let unmatched = failingTests.filter { !isSelected($0, by: selected) }
        return unmatched.isEmpty ? (.withinSelection, []) : (.outsideSelection, unmatched)
    }

    /// Why this record contradicts itself or the deciding run's recorded
    /// failing tests (`resultFailingTests`, the result's own test summary), or
    /// `nil` when it is coherent. Used to re-check a stored record without
    /// re-running anything; it never upgrades a record.
    public func inconsistency(resultFailingTests: [String]?) -> String? {
        let named = failingTests ?? []
        if Set(named) != Set(resultFailingTests ?? []) {
            return "its recorded failing tests differ from the result's own test summary"
        }
        if !disposition.admitsKill { return "\(disposition.rawValue): the kill is not admitted" }
        if attribution == nil { return "\(disposition.rawValue) with no attribution recorded" }
        return dispositionProblem(named: named)
    }

    private func dispositionProblem(named: [String]) -> String? {
        switch disposition {
        case .withinSelection:
            if (selectedTestCount ?? 0) == 0 { return "within a selection that has no tests" }
            if named.isEmpty { return "within selection but no failing test is named" }
            if !unmatchedFailingTests.isEmpty { return "within selection but names unmatched failing tests" }
        case .wholeSuiteRan:
            if selectedTestCount != nil { return "whole suite ran but a selection size is recorded" }
            if named.isEmpty { return "whole suite ran but no failing test is named" }
        case .failingTestsUnnamed:
            if !named.isEmpty { return "marked unnamed although failing tests are recorded" }
        case .outsideSelection, .executionNotRecorded:
            return "the kill is not admitted"
        }
        return nil
    }

    /// A deliberately loose key: the last two path components, without a
    /// module prefix on the type name or anything from the argument list on.
    /// Two tests that share it may still be different tests, so it is only for
    /// questions where over-matching is the safe direction (a failure on the
    /// unmutated build that may be the same test as the killed one). Whether a
    /// failing test is inside a selection uses `TestIdentifier` instead.
    static func testKey(_ identifier: String) -> String {
        var components = identifier.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard var last = components.popLast() else { return identifier }
        if let paren = last.firstIndex(of: "(") { last = String(last[..<paren]) }
        guard var owner = components.popLast() else { return last }
        if let dot = owner.lastIndex(of: ".") { owner = String(owner[owner.index(after: dot)...]) }
        return owner + "/" + last
    }
}

/// One confirmation round the verifier folded into a result, in the order it
/// was folded. A cascade (a batch-attributed timeout whose confirming rebuild
/// is itself a kill needing its own confirmation) leaves more than one step;
/// recording only the last would hide how the verdict was reached.
public struct ConfirmationStep: Codable, Sendable, Hashable {
    /// `kill`, `crash` or `timeout`.
    public let kind: String
    public let outcomeBefore: MutationOutcome
    public let outcomeAfter: MutationOutcome
    /// The confirming run's `TestRunStatus` raw value.
    public let confirmingStatus: String

    public init(kind: String, outcomeBefore: MutationOutcome, outcomeAfter: MutationOutcome, confirmingStatus: String) {
        self.kind = kind
        self.outcomeBefore = outcomeBefore
        self.outcomeAfter = outcomeAfter
        self.confirmingStatus = confirmingStatus
    }
}
