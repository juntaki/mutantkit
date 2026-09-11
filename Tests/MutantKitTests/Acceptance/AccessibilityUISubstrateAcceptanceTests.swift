import Foundation
import MutationModel
import Testing

/// Phase 5A: the UI-test execution substrate that lets an existing Xcode
/// UI-test target/scheme participate in a real mutation campaign, with
/// results flowing into MutantKit's existing trust/evidence chain. This is
/// infrastructure, not an operator — `Fixtures/AccessibilityUISubstrate` has
/// no unit test target at all, so every mutant here can only ever be killed
/// through its UI test target, `AccessibilityUITests`.
///
/// `isRowTapRegistered(currentCount:)`'s `>= 0` boundary is not a new
/// operator's own fixture: both mutants it produces come from
/// `swift.core.relational-operator-replacement`, a built-in operator that
/// already ships. What is new is that neither mutant has any unit test to be
/// killed by — proving a UI-test-only-covered mutation flows end to end
/// through a real `mutantkit plan` + `mutantkit run` campaign, not merely
/// that the operator itself works.
///
/// The two hand-applied faults this substrate exists to make observable at
/// all (`.accessibilityLabel("Close")` and `.contentShape(Rectangle())`
/// removal) are validated manually against `XCResultAdapter.classify`
/// directly, not here — see the internal Phase 5A UI-test-substrate
/// research record (not part of this public repo) for that evidence.
/// Neither is a registered `MutationOperator`, so neither can be driven
/// through `mutantkit plan`'s own discovery.
@Suite(
    "Acceptance: UI-test execution substrate (Phase 5A)",
    .enabled(if: Acceptance.simulatorEnabled)
)
struct AccessibilityUISubstrateAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeProject
          scheme: AccessibilityUISubstrate
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [AccessibilityUITests]
        operators:
          profile: default
        execution:
          strategy: isolated
          workers: 1
        timeouts:
          baseline: 3m
          mutant:
            strategy: fixed
            maximum: 5m
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "AccessibilityUISubstrate", configuration: configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("Baseline records a real, non-zero XCUITest count read from the test runner's own output")
    func baselineRecordsRealNonZeroTestCount() throws {
        let run = try self.run()

        #expect(run.report.baseline.passed)
        let summary = try #require(run.report.baseline.testSummary)
        // All three of `AccessibilityUITests`' own tests — never inferred
        // from exit code, and never zero (see the vacuous-run rejection
        // test below for what MutantKit does when a run's own count is 0).
        #expect(summary.total == 3)
        #expect(summary.failed == 0)
    }

    @Test("A mutation covered exclusively by the UI test target is killed via that target, with no integrity violation")
    func uiTestOnlyMutationIsKilled() throws {
        let run = try self.run()

        #expect(run.report.integrity.violations.isEmpty, "\(run.report.integrity.violations.map(\.detail))")

        let covered = run.report.results.filter {
            $0.point.enclosingDeclaration.path.last == "isRowTapRegistered(currentCount:)"
        }
        #expect(covered.count == 2)
        #expect(covered.allSatisfy { $0.outcome == .killedByAssertion })
        // Every mutant's own per-run test summary is the real UI-test suite
        // (3 tests: the AX-label check, the audit, and the tap-registration
        // check that actually observes this mutation) — not a narrowed
        // selection that happens to be silent about which target it came
        // from.
        #expect(covered.allSatisfy { $0.testSummary?.total == 3 })
        #expect(covered.allSatisfy {
            $0.testSummary?.failingTests == ["AccessibilityUITests/AccessibilityUITests/testTappingFarFromTextStillTriggersAction()"]
        })
    }

    /// The single most important lesson from Phase 5's own corpus-validation
    /// work (see the hyphenated-test-target incident in this project's
    /// internal `required-decode-introduction-2026-09` corpus-validation
    /// research, not part of this public repo): a test filter that silently matches
    /// zero tests must never be read as a pass. `-only-testing:` here narrows
    /// to a test method that does not exist, so the real suite's 3 tests
    /// become 0 — MutantKit must fail the whole run closed, not report a
    /// vacuous "all mutants killed" or "all survived".
    @Test("A test selector matching zero tests is rejected as an invalid run, never a false pass")
    func vacuousTestSelectionIsRejectedNotReportedAsAPass() throws {
        let configuration = try """
        version: 1
        project:
          kind: xcodeProject
          scheme: AccessibilityUISubstrate
          destination: \(Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [AccessibilityUITests]
          extraArguments:
            - "-only-testing:AccessibilityUITests/AccessibilityUITests/testDoesNotExist"
        operators:
          profile: default
        execution:
          strategy: isolated
          workers: 1
        reports: [console, json]
        """

        let directory = try Acceptance.stageFixture("AccessibilityUISubstrate")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(configuration.utf8).write(to: directory.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let plan = try Acceptance.run(["plan", "--output", "plan.json"], in: directory)
        #expect(plan.exitCode == 0)

        let execution = try Acceptance.run(["run", "--plan", "plan.json", "--report", "json"], in: directory)

        // The whole run must fail closed: no mutant is classified `survived`
        // or `killedByAssertion` off the back of a baseline that never
        // actually ran any test. `baselineMismatch` is one of exactly two
        // outcomes `MutationOutcome.isIntegrityViolation` recognizes, and it
        // withholds the score entirely rather than counting anything toward
        // one.
        let reportURL = directory.appendingPathComponent(".mutantkit/report.json")
        if let data = try? Data(contentsOf: reportURL),
           let report = try? MutationPlan.decoder().decode(RunReport.self, from: data) {
            #expect(report.results.isEmpty, "A vacuous baseline must produce zero classified mutants, not a false pass.")
            #expect(!report.integrity.violations.isEmpty)
            #expect(report.integrity.violations.contains {
                $0.kind == .baselineMismatch && $0.detail.contains("infrastructureFailure")
            })
        } else {
            // Failing the command entirely (never reaching a report at all)
            // is an equally acceptable fail-closed outcome — what must never
            // happen is `execution.exitCode == 0` with a report claiming a
            // real score.
            #expect(execution.exitCode != 0)
        }
    }

    /// A destination that can never resolve to a real device must fail the
    /// whole run before anything is scored — never surface as a mutant-level
    /// `survived` or `killedByCrash`. A real, slow boot-timeout reproduction
    /// (a Simulator whose data directory is deliberately unwritable) is
    /// recorded manually in
    /// the internal Phase 5A UI-test-substrate research record (not part
    /// of this public repo) instead of
    /// here, since it legitimately takes several minutes (the same
    /// `bootTimeoutSeconds: 90` × `bootstatusRetries: 2` budget
    /// `SimulatorPool` always uses) — too slow to keep in the regular
    /// acceptance suite. This is the fast, deterministic half of the same
    /// contract: a destination that never resolves at all.
    @Test("An unresolvable Simulator destination fails the whole run, never a mutant-level verdict")
    func unresolvableDestinationFailsClosed() throws {
        let configuration = """
        version: 1
        project:
          kind: xcodeProject
          scheme: AccessibilityUISubstrate
          destination: platform=iOS Simulator,id=00000000-0000-0000-0000-000000000000
        sources:
          include: [Sources/**]
        tests:
          targets: [AccessibilityUITests]
        operators:
          profile: default
        execution:
          strategy: isolated
          workers: 1
        reports: [console, json]
        """

        let directory = try Acceptance.stageFixture("AccessibilityUISubstrate")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(configuration.utf8).write(to: directory.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let plan = try Acceptance.run(["plan", "--output", "plan.json"], in: directory)
        #expect(plan.exitCode == 0)

        let execution = try Acceptance.run(["run", "--plan", "plan.json", "--report", "json"], in: directory)

        // No report is ever produced: the destination fails to resolve
        // before the baseline runs at all, so nothing is scored — this is
        // the fail-closed contract, not a `report.json` with an
        // `infrastructureFailure` entry inside it.
        #expect(execution.exitCode != 0)
        let reportURL = directory.appendingPathComponent(".mutantkit/report.json")
        #expect(!FileManager.default.fileExists(atPath: reportURL.path))
    }
}
