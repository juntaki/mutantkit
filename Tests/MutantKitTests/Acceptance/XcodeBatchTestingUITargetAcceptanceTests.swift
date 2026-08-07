import Foundation
import MutationModel
import Testing

/// `execution.testBatchSize` combined with `selectCoveringTests`, against a
/// real `.xcodeproj` whose scheme carries TWO test targets — a unit test
/// target and a UI test target — the shape `XcodeBatchTestingAcceptanceTests`
/// cannot exercise, since `Fixtures/XcodeProject` has only one.
///
/// Background: `BatchXCTestRunBuilder.build` once applied one mutant's
/// narrowed selection (computed from unit-test coverage only) to *every*
/// test target folded in from that mutant's v1 `.xctestrun`, including a UI
/// test target with none of its own tests selected. Against a real app
/// project, a direct, isolated `xcodebuild test-without-building`
/// reproduction confirmed this reliably fails that bundle's runner to
/// initialize ("Timed out waiting for AX loaded notification") rather than
/// cleanly reporting zero tests, and since that failure carries no test
/// identifier `classify(batch:)` can attribute back to the mutant's own
/// configuration, the mutant was reported `infrastructureFailure` instead of
/// its real, correct verdict. Fixed by dropping a target with zero of its own
/// tests selected from the batch configuration entirely — the same way
/// `-only-testing:<other target>/...` already omits it at the `xcodebuild`
/// command-line level for a non-batched run.
///
/// This suite's fixture app is intentionally minimal, so it does not
/// reproduce the AX timeout itself (confirmed: it did not occur even before
/// this fix, most likely because that real app's own UI complexity is what pushes the
/// runner's accessibility-tree readiness past the timeout, not the empty
/// selection alone). What it *does* prove, against a real build and a real
/// batch classification, is the structural contract the fix establishes: a
/// mutant narrowed to only the unit target is classified correctly and its
/// `testSummary` contains only that target's own test, never a stray entry
/// from the UI target — i.e. the UI target is genuinely dropped from the
/// merged batch, not merely lucky. `BatchXCTestRunBuilderTests` pins the same
/// contract at the unit level; the direct real-app reproduction is the record of
/// the real failure mode this was fixed for.
@Suite(
    "Acceptance: Xcode project with a UI test target, batched",
    .enabled(if: Acceptance.simulatorEnabled)
)
struct XcodeBatchTestingUITargetAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeProject
          scheme: BatchUIDemo
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [BatchUIDemoTests]
        operators:
          profile: default
        execution:
          strategy: isolated
          workers: 2
          selectCoveringTests: true
          testBatchSize: 10
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "XcodeAppWithUITests", configuration: configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("Mutants narrowed to only the unit test target are killed, with no stray UI-target test counted")
    func batchedMutantsNarrowedToUnitTargetAreKilled() throws {
        let run = try self.run()

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        // Both `isInStock(count:)` mutants narrow to the same single unit
        // test and land in the same batch alongside the UI test target's
        // own v1 `.xctestrun` entry. `testSummary.total == 1` (not 2) is the
        // direct, non-flaky proof that the UI target's own entry was
        // genuinely dropped from the merged configuration, not merely
        // included-but-harmless.
        let covered = run.report.results.filter {
            $0.point.enclosingDeclaration.path.last == "isInStock(count:)"
        }
        #expect(covered.count == 2)
        #expect(covered.allSatisfy { $0.outcome == .killedByAssertion })
        #expect(covered.allSatisfy { $0.testSummary?.total == 1 })
    }

    @Test("Classification matches: boundary-tested method's mutants are killed, untested method's has no coverage")
    func classificationMatchesExpectedSplit() throws {
        let run = try self.run()

        #expect(run.killed == [
            .init(declaration: "isInStock(count:)", original: ">=", replacement: ">"),
            .init(declaration: "isInStock(count:)", original: ">=", replacement: "<")
        ])
        // `selectCoveringTests` is on, so a mutation with zero covering
        // tests is `.noCoverage`, not `.survived` — same as
        // `XcodeBatchTestingAcceptanceTests`'s `requiresSignature(itemCount:)`.
        #expect(run.mutations(withOutcome: .noCoverage) == [
            .init(declaration: "requiresConfirmation(itemCount:)", original: ">", replacement: ">="),
            .init(declaration: "requiresConfirmation(itemCount:)", original: ">", replacement: "<=")
        ])
    }
}
