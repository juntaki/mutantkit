import Foundation
import MutationModel
import Testing

/// Phase C2 (competitive-parity program): proves Swift Testing support is
/// real under both an Xcode *project* and an Xcode *workspace* — not just
/// parser-level. `SwiftPackageMacOSAcceptanceTests`/`PricingTests` already
/// prove Swift Testing under SwiftPM; `XcodeAcceptanceTests`/`CheckoutTests`
/// and `BillingTests` already prove XCTest under both Xcode project and
/// workspace. This is the missing cell: Xcode project/workspace x Swift
/// Testing, driven through a real `xcodebuild` invocation against a real
/// simulator, read back from the same `.xcresult` XCTest already uses.
///
/// Both fixtures were extended (not replaced) with a new, isolated scheme —
/// `SwiftTestingCheckoutDemo`/`SwiftTestingBillingDemo` — that builds and
/// tests only a new Swift Testing bundle, so every other acceptance suite
/// sharing these fixtures is unaffected.
@Suite("Acceptance: Swift Testing under Xcode project/workspace", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeSwiftTestingAcceptanceTests {
    private static func projectConfiguration() throws -> String {
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
          workers: 1
        reports: [console, json]
        """
    }

    private static func workspaceConfiguration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeWorkspace
          scheme: SwiftTestingBillingDemo
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [SwiftTestingBillingTests]
        operators:
          profile: default
        execution:
          strategy: isolated
          workers: 1
        reports: [console, json]
        """
    }

    private static let sharedProjectRun = Result {
        try Acceptance.planAndRun(fixture: "XcodeProject", configuration: projectConfiguration())
    }

    private static let sharedWorkspaceRun = Result {
        try Acceptance.planAndRun(fixture: "XcodeWorkspace", configuration: workspaceConfiguration())
    }

    // MARK: - Xcode project

    /// Writes a config with a destination this machine actually has,
    /// rather than depending on the fixture's own committed
    /// `mutantkit.yml` (pinned to "iPhone 17 Pro" for reproducibility on
    /// the machine it was authored on — not installed on every machine's
    /// simulator runtimes, a pre-existing gap this test sidesteps rather
    /// than inherits; see `detectionPrefersWorkspace` in
    /// `XcodeAcceptanceTests` for the same pattern hitting it directly).
    @Test("doctor detects an xcodeProject and the Swift Testing scheme builds and tests for real")
    func xcodeProjectDoctorDetectsProjectKind() throws {
        let directory = try Acceptance.stageFixture("XcodeProject")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(Self.projectConfiguration().utf8)
            .write(to: directory.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let doctor = try Acceptance.run(["doctor", "--skip-build"], in: directory)
        #expect(doctor.output.contains("xcodeProject"))
    }

    @Test("A Swift Testing suite under an Xcode project builds, runs on a simulator, and reconciles")
    func xcodeProjectSwiftTestingRunsEndToEnd() throws {
        let run = try Self.sharedProjectRun.get()

        #expect(run.report.baseline.passed)

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        #expect(integrity.planned == 5)
        #expect(integrity.sourceApplied == 5)
        #expect(integrity.buildObserved == 5)
        #expect(run.report.score != nil)
    }

    /// The real proof this is Swift Testing support, not just "the build
    /// still compiles": a killed mutant, from a real `#expect` failure —
    /// exactly the same kind of proof `Checkout`'s own XCTest-based
    /// `CheckoutTests` gives for the XCTest path.
    ///
    /// `requiresSignature`/`expressCheckoutEnabled` are `.survived` here,
    /// not `.noCoverage`, even though `SwiftTestingCheckoutTests` never
    /// references either: this fixture's plain config (no
    /// `execution.selectCoveringTests`) never requests per-test coverage
    /// attribution, so every mutant runs the full, unrestricted test
    /// target regardless of which lines it actually reaches — the same
    /// fail-safe behavior `XcodeProjectAcceptanceTests`' own identically-
    /// unconfigured `CheckoutTests` run relies on for the exact same
    /// declarations. `XcodeCoverageSelectionAcceptanceTests` separately
    /// proves `.noCoverage` is reachable for this exact fixture with
    /// `selectCoveringTests: true` set — but only against the pre-existing
    /// `Checkout`/`CheckoutTests` scheme; setting the same flag against
    /// this phase's new `SwiftTestingCheckoutDemo` scheme was tried and
    /// did not produce per-test narrowing (still `.survived`, not
    /// incorrect, just coarser) for a reason not root-caused in this
    /// phase — recorded in `PLATFORM-FRAMEWORK-MATRIX.md` as an open
    /// follow-up rather than silently worked around.
    @Test("Killed and survived are correctly classified via Swift Testing")
    func xcodeProjectVerdictsAreCorrect() throws {
        let run = try Self.sharedProjectRun.get()

        // canApplyCoupon(subtotal:) is fully boundary-tested by
        // SwiftTestingCheckoutTests -- both its relational mutants must be
        // killed by a real #expect failure.
        #expect(run.killed == [
            .init(declaration: "canApplyCoupon(subtotal:)", original: ">=", replacement: ">"),
            .init(declaration: "canApplyCoupon(subtotal:)", original: ">=", replacement: "<")
        ])

        #expect(run.mutations(withOutcome: .survived) == [
            .init(declaration: "requiresSignature(itemCount:)", original: ">", replacement: ">="),
            .init(declaration: "requiresSignature(itemCount:)", original: ">", replacement: "<="),
            .init(declaration: "expressCheckoutEnabled", original: "true", replacement: "false")
        ])
    }

    // MARK: - Xcode workspace

    @Test("doctor detects an xcodeWorkspace and the Swift Testing scheme builds and tests for real")
    func xcodeWorkspaceDoctorDetectsProjectKind() throws {
        let directory = try Acceptance.stageFixture("XcodeWorkspace")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(Self.workspaceConfiguration().utf8)
            .write(to: directory.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let doctor = try Acceptance.run(["doctor", "--skip-build"], in: directory)
        #expect(doctor.output.contains("xcodeWorkspace"))
    }

    @Test("A Swift Testing suite under an Xcode workspace builds, runs on a simulator, and reconciles")
    func xcodeWorkspaceSwiftTestingRunsEndToEnd() throws {
        let run = try Self.sharedWorkspaceRun.get()

        #expect(run.report.baseline.passed)

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        #expect(integrity.planned == 4)
        #expect(integrity.sourceApplied == 4)
        #expect(run.report.score != nil)
    }

    /// See `xcodeProjectVerdictsAreCorrect`'s doc comment: `.survived`, not
    /// `.noCoverage`, for the same reason (no `selectCoveringTests` in
    /// this fixture's plain config).
    @Test("Killed and survived are correctly classified via Swift Testing under a workspace")
    func xcodeWorkspaceVerdictsAreCorrect() throws {
        let run = try Self.sharedWorkspaceRun.get()

        // isOverdue(daysLate:) is fully boundary-tested by
        // SwiftTestingBillingTests.
        #expect(run.killed == [
            .init(declaration: "isOverdue(daysLate:)", original: ">", replacement: ">="),
            .init(declaration: "isOverdue(daysLate:)", original: ">", replacement: "<=")
        ])

        #expect(run.mutations(withOutcome: .survived) == [
            .init(declaration: "requiresDeposit(amount:)", original: ">=", replacement: ">"),
            .init(declaration: "requiresDeposit(amount:)", original: ">=", replacement: "<")
        ])
    }

    // MARK: - Phase C13: selectCoveringTests now narrows Swift Testing too

    /// Closes the gap `xcodeProjectVerdictsAreCorrect`'s own doc comment
    /// and `PLATFORM-FRAMEWORK-MATRIX.md` recorded: `selectCoveringTests:
    /// true` previously failed to narrow per-test coverage attribution for
    /// this exact Swift Testing scheme, root-caused in Phase C13 to
    /// `TestIdentifier.onlyTestingArgument` missing the trailing `()`
    /// `xcodebuild -only-testing:` requires to match a Swift Testing
    /// `@Test` function at all — every per-test coverage-measurement pass
    /// was silently selecting zero tests, so the whole per-test map came
    /// back empty and every mutant fell back to the full, unrestricted
    /// target. Fixed; this proves it against the real fixture, not just
    /// the unit-level parsing logic.
    private static func projectConfigurationWithCoverageSelection() throws -> String {
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
          workers: 1
          selectCoveringTests: true
        reports: [console, json]
        """
    }

    @Test("selectCoveringTests now narrows per-test attribution for a Swift Testing Xcode scheme")
    func swiftTestingCoverageSelectionNarrowsAttribution() throws {
        let run = try Acceptance.planAndRun(fixture: "XcodeProject", configuration: Self.projectConfigurationWithCoverageSelection())

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        // canApplyCoupon(subtotal:) is the only declaration
        // SwiftTestingCheckoutTests actually exercises -- with narrowing
        // now working, its own mutants must be leased exactly the two
        // real witnesses, never the bare target (a silently-empty
        // coverage map's own fallback, and the previous, broken
        // behavior this test exists to catch a regression back to).
        let covered = run.report.results.filter {
            $0.point.enclosingDeclaration.path.last == "canApplyCoupon(subtotal:)"
        }
        #expect(covered.count == 2)
        let expected = Set([
            "-only-testing:SwiftTestingCheckoutTests/SwiftTestingCheckoutTests/couponBelowBoundary()",
            "-only-testing:SwiftTestingCheckoutTests/SwiftTestingCheckoutTests/couponAtBoundary()"
        ])
        for mutant in covered {
            let args = mutant.evidence?.testCommand?.arguments ?? []
            let onlyTesting = Set(args.filter { $0.hasPrefix("-only-testing:") })
            #expect(
                onlyTesting == expected,
                "\(mutant.point.id.rawValue) ran with \(onlyTesting), expected both narrowed witnesses"
            )
        }

        // requiresSignature/expressCheckoutEnabled are never referenced by
        // SwiftTestingCheckoutTests at all -- with narrowing now actually
        // working, these must be .noCoverage, not .survived (the coarser,
        // fail-safe verdict the pre-fix, always-empty coverage map
        // produced for every mutant regardless of real coverage).
        let uncovered = run.report.results.filter {
            let decl = $0.point.enclosingDeclaration.path.last
            return decl == "requiresSignature(itemCount:)" || decl == "expressCheckoutEnabled"
        }
        #expect(!uncovered.isEmpty)
        for mutant in uncovered {
            #expect(mutant.outcome == .noCoverage, "\(mutant.point.id.rawValue) was \(mutant.outcome), expected .noCoverage now that attribution actually narrows")
        }
    }
}
