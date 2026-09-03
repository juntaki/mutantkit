import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// The supported-matrix acceptance suite for SwiftPM macOS —
/// XCTest, Swift Testing, and both mixed in one test bundle. Unlike every
/// other schemata acceptance suite that reuses a partially-covered fixture
/// (some candidates deliberately survive), each fixture here
/// (`Fixtures/SchemataMatrix{XCTest,SwiftTesting,Mixed}`) is fully
/// covered on purpose — every candidate a default-profile schemata run
/// discovers is killed by a dedicated test — so a genuinely healthy run
/// must show **zero** isolated fallback of any kind, not merely a
/// correct-but-partial one. "The run was green" is not the bar; "schemata
/// actually activated for every planned mutation, with zero fallback and
/// zero integrity violations" is.
///
/// Requires `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` in the environment,
/// inherited by the spawned `mutantkit` process — same requirement as
/// every other schemata acceptance suite.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Schemata supported matrix: SwiftPM macOS", .enabled(if: Acceptance.isEnabled))
struct SchemataSupportedMatrixSwiftPMMacOSAcceptanceTests {
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

    /// Asserts the shared, fixture-independent bar every supported-matrix row
    /// must clear: schemata actually activated for every planned mutation,
    /// zero isolated fallback (of any kind — dynamic or planner-time), zero
    /// integrity violations, zero shared-chunk-build-failure /
    /// buildReceiptUnavailable operational issues.
    private func assertFullyActivatedNoFallback(_ run: AcceptanceRun) throws {
        #expect(run.exitCode == 0, "\(run.runOutput)")
        #expect(run.report.baseline.passed, "the baseline must reflect a genuinely passing suite")

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        let strategy = try #require(run.report.executionStrategy)
        #expect(strategy.requested == .schemata)
        #expect(strategy.degradationReason == nil, "a whole-run degradation means schemata never really activated")
        #expect(strategy.effectiveCount == integrity.planned, "every planned mutation must go through the real schemata backend")
        #expect(
            strategy.fallbackCount == 0,
            "this fixture is fully covered on purpose — any fallback here is a real gap, not expected uncoverage"
        )
        #expect((strategy.fallbackReasonCounts ?? [:]).isEmpty)
        #expect((strategy.plannerFallbackReasonCounts ?? [:]).isEmpty)

        let operationalIssueKinds = Set(run.report.operationalIssues.map(\.kind))
        #expect(!operationalIssueKinds.contains(.schemataChunkBuildFailed))
        #expect(!operationalIssueKinds.contains(.schemataChunkReceiptUnavailable))
    }

    /// The dev-loop override path this whole suite runs under — see
    /// `ReleaseBundledSchemataRuntimeAcceptanceTests` for the sibling proof
    /// that a real release install resolves the same runtime via
    /// `.provenance == .bundled` instead.
    private func assertOverrideProvenance() throws {
        let located = try SchemataRuntimeLibraryLocator.locate(for: .macOS)
        #expect(located.provenance == .override)
    }

    @Test("SwiftPM macOS + XCTest: fully covered fixture activates schemata for every candidate, zero fallback")
    func xcTestFullyActivates() throws {
        try assertOverrideProvenance()
        let run = try Acceptance.planAndRun(fixture: "SchemataMatrixXCTest", configuration: Self.configuration)
        try assertFullyActivatedNoFallback(run)
    }

    @Test("SwiftPM macOS + Swift Testing: fully covered fixture activates schemata for every candidate, zero fallback")
    func swiftTestingFullyActivates() throws {
        try assertOverrideProvenance()
        let run = try Acceptance.planAndRun(fixture: "SchemataMatrixSwiftTesting", configuration: Self.configuration)
        try assertFullyActivatedNoFallback(run)
    }

    @Test("SwiftPM macOS + mixed XCTest/Swift Testing in one bundle: fully covered fixture fully activates, zero fallback")
    func mixedFrameworksFullyActivate() throws {
        try assertOverrideProvenance()
        let run = try Acceptance.planAndRun(fixture: "SchemataMatrixMixed", configuration: Self.configuration)
        try assertFullyActivatedNoFallback(run)
    }
}
