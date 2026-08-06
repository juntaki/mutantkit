import Foundation
import MutationModel
import Testing

/// `execution.testBatchSize` combined with `selectCoveringTests`, against a
/// real `.xcodeproj`.
///
/// The regression this suite exists to catch: a batch `.xctestrun`'s
/// per-target `OnlyTestIdentifiers` must be bare `Class/method` — the entry
/// is already scoped to one `BlueprintName`, so a target-qualified
/// identifier (`Target/Class/method`, the form `-only-testing:` and
/// `TestIdentifier.onlyTestingArgument` both correctly use everywhere else)
/// matches nothing at all. Found only by inspecting a real batch's own
/// `.xctestrun` and result bundle after `xcodebuild` silently ran "0 tests
/// ... on 2 configurations" — no error, no crash, every planned mutant
/// still present in the report, just classified from an empty run. Every
/// unit test in this codebase uses fakes and constructs a
/// `.xctestrun`-shaped dictionary by hand rather than reading one Xcode
/// actually wrote, so nothing but a real end-to-end run exercises this
/// exact format constraint.
@Suite("Acceptance: Xcode project with batched test execution", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeBatchTestingAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeProject
          scheme: Checkout
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [CheckoutTests]
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
        try Acceptance.planAndRun(fixture: "XcodeProject", configuration: configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("Batched mutants that share covering tests are actually tested — not silently run against nothing")
    func batchedMutantsActuallyRun() throws {
        let run = try self.run()

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        // The two `canApplyCoupon(subtotal:)` mutants both narrow to the same
        // two tests and land in the same batch. If the batch silently tested
        // nothing (this suite's regression), every mutant in it would come
        // back `.infrastructureFailure`.
        let covered = run.report.results.filter {
            $0.point.enclosingDeclaration.path.last == "canApplyCoupon(subtotal:)"
        }
        #expect(covered.count == 2)
        #expect(covered.allSatisfy { $0.testSummary?.total == 2 })
    }

    @Test("Classification is identical to the coverage-blind, unbatched run")
    func classificationMatchesTheBaselineRun() throws {
        let run = try self.run()

        // Same fixture, same expected split as `XcodeProjectAcceptanceTests`
        // — batching which xcodebuild invocation a mutant's test runs
        // through must never change which mutants are detected.
        #expect(run.killed == [
            .init(declaration: "canApplyCoupon(subtotal:)", original: ">=", replacement: ">"),
            .init(declaration: "canApplyCoupon(subtotal:)", original: ">=", replacement: "<")
        ])
        #expect(run.mutations(withOutcome: .noCoverage) == [
            .init(declaration: "requiresSignature(itemCount:)", original: ">", replacement: ">="),
            .init(declaration: "requiresSignature(itemCount:)", original: ">", replacement: "<="),
            .init(declaration: "expressCheckoutEnabled", original: "true", replacement: "false")
        ])
    }
}
