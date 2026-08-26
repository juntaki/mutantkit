import Foundation
import MutationModel
import Testing

/// Phase C2 (competitive-parity program): proves SwiftPM + XCTest is real,
/// acceptance-tested end to end — a genuine gap this program's own C0
/// inspection found. Every SwiftPM/macOS fixture in this repo
/// (`SwiftPackageMacOS`'s own `PricingTests`, `CoreOperatorExpansion`,
/// `HangingMutant`) used Swift Testing exclusively; nothing proved the
/// XCTest half of `swift test`'s own structured-output split
/// (`xunit.xml` vs `xunit-swift-testing.xml`, see `XUnitParser`) actually
/// works end to end, only that it exists as a code path.
///
/// Mirrors `SwiftPackageMacOSAcceptanceTests` exactly, but points
/// `tests.targets` at the new `PricingXCTestTests` target instead — the
/// same `Pricing` sources, a completely separate coverage universe.
@Suite("Acceptance: Swift package on macOS, XCTest", .enabled(if: Acceptance.isEnabled))
struct SwiftPackageMacOSXCTestAcceptanceTests {
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    tests:
      targets: [PricingXCTestTests]
    operators:
      profile: default
    execution:
      strategy: isolated
      workers: 2
      measureCoverage: true
    reports: [console, json]
    """

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "SwiftPackageMacOS", configuration: configuration)
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("doctor detects a swiftPackageMacOS project")
    func doctorDetectsProjectKind() throws {
        let directory = try Acceptance.stageFixture("SwiftPackageMacOS")
        defer { try? FileManager.default.removeItem(at: directory) }

        let doctor = try Acceptance.run(["doctor", "--skip-build"], in: directory)
        #expect(doctor.output.contains("swiftPackageMacOS"))
    }

    @Test("The run reconciles and produces a score, reading XCTest's own xunit.xml")
    func runIsInternallyConsistent() throws {
        let run = try self.run()

        #expect(run.report.baseline.passed)

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        // Same 7 mutants as SwiftPackageMacOSAcceptanceTests: discovery is
        // scoped by `sources.include`, not by which test target runs them.
        #expect(integrity.discovered == 7)
        #expect(integrity.planned == 7)
        #expect(integrity.sourceApplied == 7)
        // Only the 2 mutants on the covered line (qualifiesForSeniorRate)
        // are actually built and tested -- the other 5 are noCoverage
        // without ever being built, same as SwiftPackageMacOSCoverage
        // AcceptanceTests' own measureCoverage: true precedent.
        #expect(integrity.buildObserved == 2)
        #expect(integrity.classified == 7)
        #expect(integrity.reported == 7)

        #expect(run.report.score != nil)
        #expect(run.exitCode == 0)
    }

    /// `PricingXCTestTests` only exercises `qualifiesForSeniorRate` — a real,
    /// XCTest-caught assertion failure kills both its mutants. Everything
    /// else in `Pricing` is entirely unreferenced by this target, so it is
    /// `noCoverage`, not `survived`: no test executed that code at all under
    /// this target's own coverage universe (a materially different
    /// distinction than `PricingTests`' own `survived` result for the same
    /// declarations, which its own Swift Testing suite does execute, just
    /// without a strong enough assertion).
    @Test("Killed vs noCoverage are correctly classified via XCTest")
    func verdictsAreCorrect() throws {
        let run = try self.run()

        #expect(run.killed == [
            .init(declaration: "qualifiesForSeniorRate(age:)", original: ">=", replacement: ">"),
            .init(declaration: "qualifiesForSeniorRate(age:)", original: ">=", replacement: "<")
        ])

        #expect(run.mutations(withOutcome: .survived).isEmpty)
        #expect(run.mutations(withOutcome: .noCoverage) == [
            .init(declaration: "init(loyaltyDiscountEnabled:)", original: "true", replacement: "false"),
            .init(declaration: "bulkDiscountRate(itemCount:)", original: ">", replacement: ">="),
            .init(declaration: "bulkDiscountRate(itemCount:)", original: ">", replacement: "<="),
            .init(declaration: "isFreeShipping(total:)", original: ">=", replacement: ">"),
            .init(declaration: "isFreeShipping(total:)", original: ">=", replacement: "<")
        ])
    }
}
