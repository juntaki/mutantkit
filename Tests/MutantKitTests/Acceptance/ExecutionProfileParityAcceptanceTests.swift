import Foundation
import MutationModel
import Testing

/// Proves `execution.profile: optimized` never weakens correctness: the
/// same real plan, over the same real fixture, run once under `reference`
/// and once under `optimized`, must produce identical per-mutant verdicts.
/// This is the single most important proof for this feature — more
/// important than any timing number — because `optimized` is allowed to
/// change *how* a mutant's verdict gets produced (schemata embedding
/// instead of an isolated build) but never *what* verdict it reports.
///
/// `SchemataMatrixXCTest` (see its own `Package.swift` comment) is the
/// fixture: SwiftPM macOS + XCTest, one candidate per operator this
/// build's schemata backend currently supports
/// (`SchemataLowererRegistry.builtIn`), every candidate fully covered by a
/// dedicated test — exactly the shape that exercises schemata embedding
/// with nothing eligible to fall back on for lack of coverage. It cannot
/// exercise the one thing `optimized` no longer bundles in by default —
/// per-test coverage selection (`execution.profileCoverageSkip`) — because
/// full coverage never gives that opt-in's `.noCoverage` fast path
/// anything to trigger on; `ExecutionProfileCoverageParityAcceptanceTests`
/// covers that case on a fixture built for it. `sharedModuleCache` is
/// never bundled into any profile at all (see `ExecutionProfile`'s own doc
/// comment), so it has nothing to prove here either.
///
/// Requires `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` in the environment,
/// inherited by the spawned `mutantkit` process — same requirement as
/// every other schemata acceptance suite (see
/// `SchemataSupportedMatrixSwiftPMMacOSAcceptanceTests`'s own doc comment).
///
/// Off by default like every other acceptance suite:
///     MUTANTKIT_ACCEPTANCE=1 swift test --filter ExecutionProfileParityAcceptanceTests
@Suite("Execution profile: reference vs optimized parity", .enabled(if: Acceptance.isEnabled))
struct ExecutionProfileParityAcceptanceTests {
    private static func configuration(profile: String) -> String {
        """
        version: 1
        project:
          kind: swiftPackageMacOS
        sources:
          include: [Sources/**]
        operators:
          profile: default
        execution:
          profile: \(profile)
        reports: [console, json]
        """
    }

    /// `AcceptanceRun.Mutation` already identifies a mutant the way a human
    /// describes one (declaration + original → replacement) but drops the
    /// outcome — this proof needs the outcome to compare, so it defines its
    /// own snapshot rather than widen a shared type only this test needs.
    private struct VerdictSnapshot: Hashable {
        let declaration: String
        let original: String
        let replacement: String
        let outcome: MutationOutcome
    }

    private func verdicts(_ report: RunReport) -> Set<VerdictSnapshot> {
        Set(report.results.map {
            VerdictSnapshot(
                declaration: $0.point.enclosingDeclaration.path.last ?? "?",
                original: $0.point.originalText,
                replacement: $0.point.replacementText,
                outcome: $0.outcome
            )
        })
    }

    @Test("reference and optimized report identical per-mutant verdicts for the same real plan")
    func referenceAndOptimizedAgreeOnEveryVerdict() throws {
        let directory = try Acceptance.stageFixture("SchemataMatrixXCTest")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Planned once, under a profile-agnostic config — planning never
        // reads `execution.profile` at all (resolution is a `run`-time-only
        // concern, see `ExecutionProfileResolver`'s own doc comment), so
        // both runs below execute the exact same `MutationID` set from the
        // exact same `plan.json`.
        try Data(Self.configuration(profile: "reference").utf8)
            .write(to: directory.appendingPathComponent("mutantkit.yml"), options: .atomic)
        let plan = try Acceptance.run(["plan", "--output", "plan.json"], in: directory)
        #expect(plan.exitCode == 0, "\(plan.output)")

        try Data(Self.configuration(profile: "reference").utf8)
            .write(to: directory.appendingPathComponent("reference.yml"), options: .atomic)
        try Data(Self.configuration(profile: "optimized").utf8)
            .write(to: directory.appendingPathComponent("optimized.yml"), options: .atomic)

        let referenceRun = try Acceptance.run(
            ["run", "--config", "reference.yml", "--plan", "plan.json", "--report", "json", "--output", "report-reference.json"],
            in: directory
        )
        #expect(referenceRun.exitCode == 0, "\(referenceRun.output)")
        let referenceReport = try MutationPlan.decoder().decode(
            RunReport.self, from: Data(contentsOf: directory.appendingPathComponent("report-reference.json"))
        )

        let optimizedRun = try Acceptance.run(
            ["run", "--config", "optimized.yml", "--plan", "plan.json", "--report", "json", "--output", "report-optimized.json"],
            in: directory
        )
        #expect(optimizedRun.exitCode == 0, "\(optimizedRun.output)")
        let optimizedReport = try MutationPlan.decoder().decode(
            RunReport.self, from: Data(contentsOf: directory.appendingPathComponent("report-optimized.json"))
        )

        #expect(referenceReport.integrity.passed, "\(referenceReport.integrity.violations.map(\.detail))")
        #expect(optimizedReport.integrity.passed, "\(optimizedReport.integrity.violations.map(\.detail))")
        #expect(referenceReport.baseline.passed)
        #expect(optimizedReport.baseline.passed)

        // The headline proof: Detection-level (per-mutant verdict) parity
        // between the two profiles.
        #expect(verdicts(referenceReport) == verdicts(optimizedReport))

        // Confirms this proof actually exercised the schemata path, not two
        // silently-identical isolated-mode runs — a parity test that
        // degraded to comparing isolated-vs-isolated would prove nothing
        // about `optimized`'s own resolution logic.
        let optimizedStrategy = try #require(optimizedReport.executionStrategy)
        #expect(optimizedStrategy.requested == .schemata)
        #expect(optimizedStrategy.effectiveCount > 0, "expected optimized to actually embed at least one mutation via schemata")
        #expect(referenceReport.executionStrategy == nil, "reference must stay plain isolated mode, unaffected by this feature")
    }

    /// Pins a second, independent adversarial-review finding:
    /// `execution.profile: optimized` upgrades `execution.strategy` to
    /// `.schemata` whenever the project has an eligible operator, and
    /// separately (here, via the pre-existing, directly-set
    /// `execution.selectCoveringTests: true` — the same thing
    /// `execution.profileCoverageSkip: true` would also cause) `RunCommand
    /// .resolveTestAdapter` wraps the test adapter in
    /// `PrioritizingTestAdapter` whenever `selectCoveringTests` and the
    /// documented, ADR-0009-sanctioned `earlyAbortSelectedTests` are both
    /// on and there is no batchable `testBatchSize` to take the wave-based
    /// path instead. `PrioritizingTestAdapter` conforms to `TestSelecting`,
    /// never `SchemataTestable` — before the fix, combining these two
    /// independently-reasonable settings made `SchemataRunOrchestration.run`
    /// fail outright with "the resolved project adapter does not support
    /// schemata execution" on a real SwiftPM project that plainly does
    /// support schemata. `ExecutionProfileResolver.resolve` now refuses to
    /// upgrade `strategy` to `.schemata` in exactly this combination — see
    /// its own `wouldConflictWithEarlyAbort` — and this run must both
    /// succeed and honestly report that it stayed on `.isolated` (which
    /// already runs `selectCoveringTests` + `earlyAbortSelectedTests`
    /// correctly today) rather than silently claiming schemata mode.
    @Test("optimized + selectCoveringTests + earlyAbortSelectedTests succeeds on a real SwiftPM project, falling back to isolated")
    func optimizedWithEarlyAbortSelectedTestsSucceeds() throws {
        let configuration = """
        version: 1
        project:
          kind: swiftPackageMacOS
        sources:
          include: [Sources/**]
        operators:
          profile: default
        execution:
          profile: optimized
          selectCoveringTests: true
          earlyAbortSelectedTests: true
        reports: [console, json]
        """
        let run = try Acceptance.planAndRun(fixture: "SchemataMatrixXCTest", configuration: configuration)
        defer { run.cleanUp() }

        #expect(run.exitCode == 0, "\(run.runOutput)")
        #expect(run.report.integrity.passed, "\(run.report.integrity.violations.map(\.detail))")
        #expect(run.report.baseline.passed)
        #expect(
            run.report.executionStrategy == nil,
            "expected isolated mode: schemata would conflict with selectCoveringTests + earlyAbortSelectedTests here"
        )
    }
}
