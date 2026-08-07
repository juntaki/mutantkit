import Foundation
import MutationModel
import Testing

/// `execution.incrementalBuild` combined with `testBatchSize` and
/// `selectCoveringTests`, against a real `.xcodeproj` — the one combination
/// `XcodeBatchTestingAcceptanceTests` and the incremental-build acceptance
/// coverage each exercise only half of.
///
/// The regression this suite exists to catch is specific to combining the
/// two: `evaluateIncrementallyInBatches` clones a mutant's build products
/// out of its persistent worker sandbox before that worker starts its next
/// mutant's build, so the batch test phase can still test it later without
/// racing the worker's next `xcodebuild build-for-testing` call, which
/// reuses (and overwrites) that same sandbox's `DerivedData` in place. A
/// real `.xctestrun` — with real absolute paths and real `__TESTROOT__`
/// resolution — is what proves the clone is actually usable by
/// `xcodebuild test-without-building`, not just present on disk; every unit
/// test in this codebase uses fakes and never asks `xcodebuild` to launch
/// anything from a cloned location.
@Suite("Acceptance: Xcode project with incremental build + batched testing", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeIncrementalBatchTestingAcceptanceTests {
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
          incrementalBuild: true
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

    @Test("Batched mutants built incrementally are actually tested — not silently run against nothing")
    func batchedMutantsActuallyRun() throws {
        let run = try self.run()

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        // Same shape as `XcodeBatchTestingAcceptanceTests`: the two
        // `canApplyCoupon(subtotal:)` mutants narrow to the same two tests
        // and land in the same batch. If a clone were unusable by
        // `xcodebuild` (this suite's regression), the batch would come back
        // empty and every mutant in it `.infrastructureFailure`.
        let covered = run.report.results.filter {
            $0.point.enclosingDeclaration.path.last == "canApplyCoupon(subtotal:)"
        }
        #expect(covered.count == 2)
        #expect(covered.allSatisfy { $0.testSummary?.total == 2 })
    }

    @Test("Classification is identical to the batching-alone and coverage-blind runs")
    func classificationMatchesTheBaselineRun() throws {
        let run = try self.run()

        // Same fixture, same expected split as `XcodeProjectAcceptanceTests`
        // and `XcodeBatchTestingAcceptanceTests` — adding incremental build
        // on top of batching must never change which mutants are detected.
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
