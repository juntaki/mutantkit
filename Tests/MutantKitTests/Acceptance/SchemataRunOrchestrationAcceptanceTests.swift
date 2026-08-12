import Foundation
import MutationModel
import Testing

/// `mutantkit run` itself, with `execution.strategy: schemata` in the
/// config, against a fixture with both embeddable candidates (the bool
/// literals `killedFlag`/`survivedFlag`, and `pick`'s ternary) and a
/// non-embeddable one (`sum`'s `+`, no `SchemataLowerer` registered for
/// `ArithmeticOperatorReplacementOperator`) — proving a requested
/// `.schemata` run genuinely mixes both backends: the bool-literal and
/// ternary candidates run through the real `SchemataMutationRunner`, the
/// arithmetic one falls back to isolated mode, and both verdicts land in
/// one reconciled report (ADR-0006 Stage 3: schemata scoring re-enabled,
/// gated by which operators have a registered lowerer — see
/// `SchemataRunOrchestration`'s own doc comment).
///
/// Deliberately not a relational-operator, logical-connector, unary-not,
/// return-value-replacement, or ternary-branch-swap candidate: all five now
/// have a `SchemataLowerer` registered in `SchemataLowererRegistry.builtIn`
/// (the last, ternary-branch-swap, closed its own promotion gate), so none
/// of them reliably falls back anymore — every operator this fixture's
/// `profile: default` config would ever discover is schemata-eligible
/// today. `ArithmeticOperatorReplacementOperator` is `defaultEnabled: false`
/// (only under the `experimental` profile, which this fixture's config now
/// opts into specifically so `sum`'s `+` gets discovered at all), and has no
/// registered lowerer — the one operator left that stays genuinely
/// isolated-only.
///
/// Requires `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` in the environment
/// (inherited by the spawned `mutantkit` process the same way every other
/// schemata acceptance suite needs it) — see the schemata production-
/// integration plan's Stage 0.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: schemata run orchestration", .enabled(if: Acceptance.isEnabled))
struct SchemataRunOrchestrationAcceptanceTests {
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    operators:
      profile: experimental
    execution:
      strategy: schemata
    reports: [console, json]
    """

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "SchemataSwiftPackageMacOS", configuration: configuration)
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    @Test("Baseline passes and the run exits cleanly")
    func baselinePassesAndRunSucceeds() throws {
        let result = try run()
        #expect(result.report.baseline.passed, "the baseline must reflect a genuinely passing suite")
        #expect(result.exitCode == 0, "\(result.runOutput)")
    }

    @Test("A mixed schemata run reports real embedded/fallback counts, not a blanket degradation")
    func executionStrategyReportsRealCounts() throws {
        let result = try run()
        let strategy = try #require(result.report.executionStrategy)
        #expect(strategy.requested == .schemata)
        #expect(
            strategy.effectiveCount == 3,
            "killedFlag/survivedFlag (bool-literal) and pick (ternary) are the only embeddable candidates"
        )
        #expect(
            strategy.fallbackCount > 0,
            "sum's arithmetic operator has no registered lowerer, so at least one mutant must fall back to isolated mode"
        )
        #expect(
            strategy.effectiveCount + strategy.fallbackCount == result.report.results.count,
            "every result must be attributed to exactly one of the two backends"
        )
    }

    @Test("The bool-literal and ternary candidates run through the real schemata backend; the arithmetic one runs isolated")
    func mixedBackendAttribution() throws {
        let result = try run()
        #expect(!result.report.results.isEmpty)

        let boolLiteralCandidates = result.report.results.filter { $0.point.originalText == "true" }
        #expect(boolLiteralCandidates.count == 2)
        for candidate in boolLiteralCandidates {
            guard case .schemata? = candidate.evidence?.applicationEvidence else {
                let got = String(describing: candidate.evidence?.applicationEvidence)
                Issue.record("expected schemata evidence for \(candidate.point.id.rawValue), got \(got)")
                continue
            }
        }

        let ternaryCandidate = try #require(result.report.results.first {
            $0.point.enclosingDeclaration.description.contains("pick")
        })
        guard case .schemata? = ternaryCandidate.evidence?.applicationEvidence else {
            let got = String(describing: ternaryCandidate.evidence?.applicationEvidence)
            Issue.record("expected schemata evidence for pick's mutant, got \(got)")
            return
        }

        let arithmeticCandidate = try #require(result.report.results.first {
            $0.point.enclosingDeclaration.description.contains("sum")
        })
        guard case .isolated? = arithmeticCandidate.evidence?.applicationEvidence else {
            let got = String(describing: arithmeticCandidate.evidence?.applicationEvidence)
            Issue.record("expected isolated evidence for sum's mutant, got \(got)")
            return
        }

        let killed = try #require(result.report.results.first {
            $0.point.originalText == "true" && $0.point.enclosingDeclaration.description.contains("killedFlag")
        })
        #expect(killed.outcome == .killedByAssertion, "\(killed.diagnosis)")
    }

    @Test("Integrity reconciles against the one original plan")
    func integrityReconciles() throws {
        let result = try run()
        #expect(result.report.integrity.passed, "\(result.report.integrity.violations)")
        #expect(result.report.results.count == result.report.results.map(\.point.id).count, "no duplicate mutation IDs")
    }

    /// Regression for a real bug found while running MutantBench-Swift
    /// against `apple/swift-argument-parser`: `SchemataRunOrchestration
    /// .classify` only read source content for files that had a planned
    /// mutation of their own, so a target member with zero mutation
    /// candidates (a plain compiled dependency sharing the target) was
    /// missing from the `sources` map `SchemataChunkPlanner.plan` needs to
    /// build the whole target's compilable chunk — degrading the entire
    /// target to isolated fallback. Never actually about path characters;
    /// the fixture covers several anyway (a space, multiple consecutive
    /// spaces, Unicode, an apostrophe, a leading hyphen in a filename)
    /// since they were the visible symptom in the real repro and are worth
    /// pinning regardless.
    @Test("Zero-candidate target members with odd paths (spaces, Unicode, punctuation) never degrade schemata to full fallback")
    func nonMutatedTargetMembersDoNotDegradeSchemata() throws {
        let result = try run()
        let strategy = try #require(result.report.executionStrategy)
        #expect(
            strategy.effectiveCount == 3,
            """
            the bool-literal and ternary candidates must still embed under schemata even though the target also \
            contains several files with zero mutation candidates of their own, some with spaces/Unicode/punctuation \
            in their path
            """
        )
    }
}
