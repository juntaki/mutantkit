import Foundation
import MutationModel
import Testing

/// v0.4 Trust Closure, Workstream B: `BatchXCTestRunBuilder.build(items:)`'s
/// own doc comment names an explicit, honest gap — `OnlyTestIdentifiers`
/// (the batched `.xctestrun` plist key) uses `TestIdentifier.qualifiedName`
/// bare, never appending the trailing `()` a Swift Testing `@Test` function
/// needs to match via `-only-testing:` (`onlyTestingArgument`, a different
/// mechanism, already fixed and proven for the *unbatched* path by
/// `XcodeSwiftTestingAcceptanceTests.swiftTestingCoverageSelectionNarrowsAttribution`).
/// Whether the *batched* `OnlyTestIdentifiers` key needs the same `()` for a
/// Swift Testing target had never been verified empirically — this is that
/// verification, against a real `xcodebuild` batch run, mirroring
/// `XcodeBatchTestingAcceptanceTests` exactly but for the
/// `SwiftTestingCheckoutDemo` scheme instead of `Checkout`.
///
/// `SwiftTestingCheckoutTests` (`couponBelowBoundary`, `couponAtBoundary`)
/// gives the same "two witnesses for one declaration" shape
/// `XcodeBatchTestingAcceptanceTests` already relies on for
/// `CheckoutTests`, so both of `canApplyCoupon(subtotal:)`'s mutants narrow
/// to the same two tests and land in the same batch — the exact shape a
/// silently-empty `OnlyTestIdentifiers` would misreport as
/// `infrastructureFailure`, and a wrong-format `OnlyTestIdentifiers` (this
/// suite's actual concern) would misreport as "0 tests ... on N
/// configurations" the same way the original XCTest regression this
/// mechanism guards against did.
@Suite("Acceptance: Xcode project, Swift Testing, batched test execution", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeBatchTestingSwiftTestingAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeProject
          scheme: SwiftTestingCheckoutDemo
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [SwiftTestingCheckoutTests]
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

    @Test("Batched Swift Testing mutants that share covering tests are actually tested — OnlyTestIdentifiers matches for real")
    func batchedSwiftTestingMutantsActuallyRun() throws {
        let run = try self.run()

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        // The two canApplyCoupon(subtotal:) mutants both narrow to
        // couponBelowBoundary/couponAtBoundary and land in the same batch.
        // If the batched OnlyTestIdentifiers entry for a Swift Testing
        // bundle silently matched nothing (this suite's actual concern —
        // the missing-() hypothesis the production code's own doc comment
        // names as unverified), every mutant in the batch would come back
        // infrastructureFailure or, worse, .survived from a real-looking
        // but empty run.
        let covered = run.report.results.filter {
            $0.point.enclosingDeclaration.path.last == "canApplyCoupon(subtotal:)"
        }
        #expect(covered.count == 2)
        #expect(covered.allSatisfy { $0.testSummary?.total == 2 })
    }

    @Test("Classification is identical to the coverage-blind, unbatched Swift Testing run")
    func classificationMatchesTheBaselineRun() throws {
        let run = try self.run()

        // Same fixture/scheme as XcodeSwiftTestingAcceptanceTests'
        // xcodeProjectVerdictsAreCorrect — batching which xcodebuild
        // invocation a mutant's test runs through must never change which
        // mutants are detected, for Swift Testing any more than for XCTest.
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
