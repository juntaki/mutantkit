import Foundation
import MutationModel
import Testing

/// `execution.selectCoveringTests` against a real `.xcodeproj`.
///
/// The regression this suite exists to catch: coverage instrumentation for
/// a real Xcode project has to be compiled in at `build-for-testing` time —
/// `-enableCodeCoverage YES` on `test-without-building` alone produces a
/// bundle whose `content-availability` reports `hasCoverage: false`, no
/// matter what. Found only by running the real pipeline end to end: every
/// unit test here used fakes, so nothing exercised the actual `xcodebuild`
/// invocation shape, and per-test coverage silently attributed nothing —
/// every mutant fell back to the full test target, correctly but slower,
/// with no visible failure anywhere. This suite is the one place that
/// would have caught it, and the one place a future regression in this
/// exact shape will be caught again.
@Suite("Acceptance: Xcode project with covering-tests selection", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeCoverageSelectionAcceptanceTests {
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
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "XcodeProject", configuration: configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("Coverage instrumentation actually attributes lines to tests, not just to the whole run")
    func perTestCoverageActuallyAttributes() throws {
        let run = try self.run()

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        // Every covered mutant must be narrowed to the two tests that actually
        // cover `canApplyCoupon(subtotal:)` — never the bare target, which is
        // what a silently-empty coverage map falls back to. The fixture splits
        // the boundary witness from the non-boundary witness deliberately so
        // wave-based early kill can prove a real second wave later.
        let covered = run.report.results.filter {
            $0.point.enclosingDeclaration.path.last == "canApplyCoupon(subtotal:)"
        }
        #expect(covered.count == 2)
        // Phase C13: `onlyTestingArgument` now always appends the trailing
        // `()` (required for `xcodebuild` to match a Swift Testing `@Test`
        // function at all; tolerated either way for XCTest, confirmed by
        // this exact test still passing unchanged in outcome).
        let expected = Set([
            "-only-testing:CheckoutTests/CheckoutTests/testCouponAboveMinimum()",
            "-only-testing:CheckoutTests/CheckoutTests/testCouponAtMinimum()"
        ])
        for mutant in covered {
            let args = mutant.evidence?.testCommand?.arguments ?? []
            let onlyTesting = Set(args.filter { $0.hasPrefix("-only-testing:") })
            #expect(
                onlyTesting == expected,
                "\(mutant.point.id.rawValue) ran with \(onlyTesting), expected both narrowed witnesses"
            )
        }
    }

    @Test("Classification is identical to the coverage-blind run: same kills, same survivors")
    func classificationMatchesTheBaselineRun() throws {
        let run = try self.run()

        // Same fixture, same expected split as `XcodeProjectAcceptanceTests`
        // — narrowing which tests run must never change which mutants are
        // detected, only how much work detecting them costs.
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
