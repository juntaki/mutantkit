import Foundation
import MutationModel
import Testing

/// An `.xcodeproj` built with `xcodebuild` and tested on a simulator.
///
/// This fixture is where the most dangerous bug in the tool's history showed up:
/// `-project` was passed the *original* project path while the mutated copy sat
/// unread in the sandbox, so every mutant compiled the user's real sources and
/// produced a binary identical to the baseline's. Nothing about the counts looked
/// wrong. Only comparing the built products caught it.
///
/// It is also the only fixture whose code under test lives in a separate product
/// from the test bundle — a framework — which is what proves the product hash
/// covers more than `.xctest`.
@Suite("Acceptance: Xcode project", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeProjectAcceptanceTests {
    /// Overrides the fixture's committed config so the destination is whatever
    /// iPhone this machine has. The fixture pins a model for a human running it by
    /// hand; a suite that pinned one would fail on any other Xcode, as an
    /// infrastructure error indistinguishable from the tool being broken.
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
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "XcodeProject", configuration: configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("An Xcode project builds, runs on a simulator, and reconciles")
    func xcodeProjectRunsEndToEnd() throws {
        let run = try self.run()

        #expect(run.report.baseline.passed)
        // Two test methods by design (see `CheckoutTests.swift`'s doc comment:
        // wave-based early kill needs one mutant the first test alone can't
        // catch, caught by the second).
        #expect(run.report.baseline.testSummary?.total == 2)

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        #expect(integrity.planned == 5)
        #expect(integrity.sourceApplied == 5)
        #expect(integrity.buildObserved == 5)
        #expect(run.report.score != nil)
    }

    @Test("Exactly the uncovered mutations survive")
    func survivorsAreExactlyTheUncoveredOnes() throws {
        let run = try self.run()

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

    /// `expressCheckoutEnabled` is a stored initializer, and its mutation lands
    /// only in `__DATA,__data` — every other section, `__text` included, is
    /// byte-identical. Hashing code alone reported it as never having reached the
    /// binary, which was false and cost the whole run its score. This asserts the
    /// hash still sees a data-only mutation.
    @Test("A mutation confined to stored data is still proven active")
    func dataOnlyMutationIsProvenActive() throws {
        let run = try self.run()

        let dataMutant = try #require(
            run.report.results.first { $0.point.enclosingDeclaration.path.last == "expressCheckoutEnabled" },
            "the fixture should contain a stored-initializer mutation"
        )
        let activation = try #require(dataMutant.evidence?.applicationEvidence?.isolatedActivation)
        #expect(activation.provesActivation)
    }
}

/// An `.xcworkspace` wrapping its own `.xcodeproj`.
///
/// A distinct adapter branch from the project path — `xcodebuild` takes
/// `-workspace` instead of `-project`, and scheme resolution differs — so it
/// needs its own fixture even though the code under test is trivial.
@Suite("Acceptance: Xcode workspace", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeWorkspaceAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeWorkspace
          scheme: Billing
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [BillingTests]
        operators:
          profile: default
        execution:
          strategy: isolated
          workers: 2
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "XcodeWorkspace", configuration: configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("A workspace builds, runs on a simulator, and reconciles")
    func workspaceRunsEndToEnd() throws {
        let run = try self.run()

        #expect(run.report.baseline.passed)
        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        #expect(integrity.planned == 4)
        #expect(integrity.sourceApplied == 4)
        #expect(run.report.score != nil)
    }

    @Test("Exactly the uncovered mutations survive")
    func survivorsAreExactlyTheUncoveredOnes() throws {
        let run = try self.run()

        #expect(run.killed == [
            .init(declaration: "isOverdue(daysLate:)", original: ">", replacement: ">="),
            .init(declaration: "isOverdue(daysLate:)", original: ">", replacement: "<=")
        ])
        #expect(run.mutations(withOutcome: .survived) == [
            .init(declaration: "requiresDeposit(amount:)", original: ">=", replacement: ">"),
            .init(declaration: "requiresDeposit(amount:)", original: ">=", replacement: "<")
        ])
    }

    /// Nothing should time out here, and a timeout would be invisible in the score
    /// because timeouts are excluded from it. The mutant limit is derived from the
    /// baseline's measured wall clock for exactly this reason: budgeting from the
    /// duration a result bundle reports gave killed mutants less time than a
    /// simulator run costs, so the same plan produced different scores on
    /// consecutive runs.
    @Test("No mutant is lost to a timeout")
    func nothingTimesOut() throws {
        let run = try self.run()
        #expect(run.mutations(withOutcome: .timedOut).isEmpty)
        #expect(run.report.score?.excluded.isEmpty == true, "\(run.report.score?.excluded ?? [:])")
    }

    @Test("Detection prefers the workspace over the project beside it")
    func detectionPrefersWorkspace() throws {
        let directory = try Acceptance.stageFixture("XcodeWorkspace")
        defer { try? FileManager.default.removeItem(at: directory) }

        let doctor = try Acceptance.run(["doctor", "--skip-build"], in: directory)
        #expect(doctor.output.contains("xcodeWorkspace"))
    }
}
