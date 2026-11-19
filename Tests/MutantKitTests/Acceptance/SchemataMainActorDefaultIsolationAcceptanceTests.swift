import Foundation
import MutationModel
import Testing

/// Schemata against a SwiftPM library target built with
/// `swiftSettings: [.defaultIsolation(MainActor.self)]` (Swift 6.2+)
/// (`Fixtures/MainActorDefaultPackage`).
///
/// The schemata preamble is prepended into the target's own sources, so it
/// takes that target's default isolation. Before its two runtime functions
/// were declared `nonisolated`, every chunk here failed to build ("main
/// actor-isolated default value in a nonisolated(unsafe) context") and
/// every mutant fell back to isolated mode — with the very same verdicts,
/// which is why this suite asserts that no fallback happened as well as
/// naming the mutants expected to live and die. The fixture is fully
/// covered and holds one candidate in main-actor isolated code and two in a
/// `nonisolated` function, so both places the runtime is called from — the
/// descriptor initializer and a mutated call site off the main actor — are
/// exercised.
///
/// Requires `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE`, like every schemata
/// acceptance suite. Off by default: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Schemata: SwiftPM target with main-actor default isolation", .enabled(if: Acceptance.isEnabled))
struct SchemataMainActorDefaultIsolationAcceptanceTests {
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    operators:
      profile: default
    execution:
      strategy: schemata
    reports: [console, json]
    """

    /// One run, shared by every assertion about it — see
    /// `SwiftPackageMacOSAcceptanceTests.sharedRun` for why sharing is safe.
    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "MainActorDefaultPackage", configuration: configuration)
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("Every planned mutation runs on the schemata build, with zero fallback")
    func everyMutationRunsInSchemataMode() throws {
        let run = try self.run()

        #expect(run.exitCode == 0, "\(run.runOutput)")
        #expect(run.report.baseline.passed, "\(run.baselineEvidence)")
        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        #expect(integrity.planned == 3)

        let strategy = try #require(run.report.executionStrategy)
        #expect(strategy.requested == .schemata)
        #expect(strategy.degradationReason == nil, "\(run.baselineEvidence)")
        #expect(strategy.effectiveCount == integrity.planned, "\(run.schemataFallbackEvidence)")
        #expect(strategy.fallbackCount == 0, "\(run.schemataFallbackEvidence)")
        #expect((strategy.fallbackReasonCounts ?? [:]).isEmpty, "\(run.schemataFallbackEvidence)")
        #expect((strategy.plannerFallbackReasonCounts ?? [:]).isEmpty, "\(run.schemataFallbackEvidence)")

        let operationalIssueKinds = Set(run.report.operationalIssues.map(\.kind))
        #expect(!operationalIssueKinds.contains(.schemataChunkBuildFailed), "\(run.schemataFallbackEvidence)")
        #expect(!operationalIssueKinds.contains(.schemataChunkReceiptUnavailable), "\(run.schemataFallbackEvidence)")
    }

    /// `isAdult(age:)` is tested at 17 and 19 but never at 18, so moving the
    /// boundary survives while reversing the comparison dies.
    @Test("Exactly the boundary shift survives; the main-actor and nonisolated candidates otherwise die")
    func survivorsAndKillsAreExact() throws {
        let run = try self.run()

        #expect(run.mutations(withOutcome: .survived) == [
            .init(declaration: "isAdult(age:)", original: ">=", replacement: ">")
        ])
        #expect(run.killed == [
            .init(declaration: "isOpen()", original: "true", replacement: "false"),
            .init(declaration: "isAdult(age:)", original: ">=", replacement: "<")
        ])
    }
}
