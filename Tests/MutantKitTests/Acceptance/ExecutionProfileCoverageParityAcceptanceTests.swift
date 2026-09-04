import Foundation
import MutationModel
import Testing

/// Proves the specific correctness claim `ExecutionProfileParityAcceptanceTests`
/// cannot: that `reference` and `optimized` still agree, mutant for mutant,
/// on a project with a genuinely UNcovered mutable line — the exact shape
/// an adversarial review used to prove the opposite was true before this
/// branch's fix. `Fixtures/SchemataMatrixXCTest` (that suite's own fixture)
/// is 100% covered by design and structurally cannot exercise this: nothing
/// on it ever reaches `MutationRunner`'s `.noCoverage` fast path, covered
/// or not. `Fixtures/SchemataCoverageGapXCTest` exists for exactly this —
/// see its own `Package.swift` comment.
///
/// What the finding was: `execution.profile: optimized` used to bundle
/// `measureCoverage` + `selectCoveringTests` in by default. Once a baseline
/// coverage map exists at all, `MutationRunner.prepare` classifies a
/// mutation on a line the map says was never executed as `.noCoverage`
/// *without ever building or testing it* — a real design feature (see
/// `ExecutionSettings.measureCoverage`'s own doc comment), but one that
/// changes the verdict `reference` would reach for that same mutation: a
/// genuinely-uncovered line, actually built and tested, always reports
/// `.survived` (no test exercises it, so none can catch a mutation there),
/// and `.survived` counts against `MutationScore.tested` while `.noCoverage`
/// is excluded from its denominator entirely. Choosing a *speed* profile
/// alone silently turned a real survivor into a laundered non-finding, with
/// zero change to the actual test suite — exactly the class of bug this
/// codebase's `false-survivor-worse-than-false-error` invariant exists to
/// catch. The fix moved that pair behind its own explicit,
/// `execution.profileCoverageSkip` opt-in (see that field's own doc
/// comment) — `optimized` alone, the case this suite exercises, no longer
/// touches either flag, so it can never reach that fast path at all.
///
/// Off by default like every other acceptance suite:
///     MUTANTKIT_ACCEPTANCE=1 swift test --filter ExecutionProfileCoverageParityAcceptanceTests
@Suite("Execution profile: reference vs optimized parity on an uncovered line", .enabled(if: Acceptance.isEnabled))
struct ExecutionProfileCoverageParityAcceptanceTests {
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

    /// Keyed on `MutationID`, not on `(path, originalText, replacementText)`
    /// the way `ExecutionProfileParityAcceptanceTests.VerdictSnapshot` keys
    /// its own comparison — the two mutants here differ enough (one
    /// function's `true` versus the other's) that either key would work on
    /// this specific fixture, but `MutationID` is the identity `reference`
    /// and `optimized` are actually being asked to agree about (the same
    /// planned mutation, evaluated two ways), so this proof uses the
    /// stronger, more literal key the finding itself was reported against.
    private func verdictsByID(_ report: RunReport) -> [MutationID: MutationOutcome] {
        Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0.outcome) })
    }

    @Test("reference and optimized report the identical verdict and MutationScore.tested for a genuinely-uncovered mutable line")
    func referenceAndOptimizedAgreeOnTheUncoveredMutant() throws {
        let directory = try Acceptance.stageFixture("SchemataCoverageGapXCTest")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Planned once, under a profile-agnostic config — see
        // `ExecutionProfileParityAcceptanceTests`'s identical reasoning:
        // `plan` never reads `execution.profile` at all, so both runs below
        // execute the exact same `MutationID` set from the exact same
        // `plan.json`.
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

        // The fixture's own contract: at least one candidate on a line no
        // test executes. If this ever stops being true (the fixture was
        // edited, or the operator catalog changed what it mutates), the
        // rest of this test would pass vacuously — assert it directly
        // rather than trust the fixture's doc comment alone.
        #expect(
            referenceReport.results.contains { $0.outcome == .survived },
            "expected the fixture's genuinely-uncovered candidate to report .survived under reference"
        )

        // The headline proof: identical result counts, identical per-
        // mutant verdicts keyed on MutationID, and — because of that —
        // identical MutationScore.tested. This is the exact comparison
        // that was false before the fix: `optimized` used to report the
        // uncovered mutant `.noCoverage` (dropped from `tested`'s
        // denominator) while `reference` correctly reported it `.survived`
        // (counted against `tested`), so the two scores disagreed with
        // zero change to the actual test suite.
        #expect(referenceReport.results.count == optimizedReport.results.count)
        #expect(verdictsByID(referenceReport) == verdictsByID(optimizedReport))
        #expect(referenceReport.score == optimizedReport.score)
        #expect(referenceReport.score?.tested == optimizedReport.score?.tested)

        // Confirms this proof actually exercised the schemata path (the
        // one thing `optimized` still does differently here), not two
        // silently-identical isolated-mode runs — and confirms the second
        // half of the fix: with `execution.profileCoverageSkip` left off,
        // schemata mode never measures coverage either, so its own
        // `knownUncovered` fast path (`SchemataMutationRunner
        // .SchemataFallbackReason`) — the schemata-side twin of the exact
        // bug this whole suite exists to catch — never fires.
        //
        // Not "zero fallbacks" outright: the uncovered candidate's schemata
        // token genuinely never runs the code it activates (nothing calls
        // it), so its test run passes with no HIT record at all — a real,
        // correctly-detected `activation.noHit`
        // (`MutationVerdictVerifier.SchemataIsolatedFallbackReason`), not a
        // bug. That is the *other* safety net this design relies on: unlike
        // `knownUncovered` (which trusts a coverage map without ever
        // building the mutant), a no-HIT schemata result is re-verified by
        // an actual isolated-mode rebuild-and-retest before being trusted —
        // which is exactly how this mutation still ends up correctly
        // `.survived` above despite embedding via schemata first. Asserting
        // this away as "must be zero" would have to mean either the
        // fixture stopped being genuinely uncovered (breaking the fixture's
        // own contract, already checked above) or this safety net silently
        // stopped firing — a materially worse, different bug than the one
        // `knownUncovered` names.
        let optimizedStrategy = try #require(optimizedReport.executionStrategy)
        #expect(optimizedStrategy.requested == .schemata)
        #expect(
            (optimizedStrategy.fallbackReasonCounts?["knownUncovered"] ?? 0) == 0,
            "expected zero coverage-based schemata fallbacks with profileCoverageSkip left off"
        )
        #expect(referenceReport.executionStrategy == nil, "reference must stay plain isolated mode, unaffected by this feature")
    }
}
