import Foundation
import MutationModel
@testable import Reporting
import Testing

/// Stryker's vocabulary is narrower than ours, and the direction of travel is
/// lossy. The specific laundering this suite guards against: folding
/// `notApplied` / `baselineMismatch` / `infrastructureFailure` into `Survived`.
/// A phantom mutant rendered as `Survived` would look exactly like a real gap
/// in the test suite, and the score-side fail-closed could not catch it once
/// the export had left the building.
@Suite("Stryker reporter")
struct StrykerReporterTests {
    /// The complete status mapping. Every outcome has a deterministic Stryker
    /// status, and the three "tool failed" outcomes never become `Survived`.
    @Test("Every outcome maps to a known Stryker status and never to a false Survived")
    func mappingNeverLaunderedAsSurvived() {
        let survivorsLaundered: [MutationOutcome] = [
            .notApplied, .baselineMismatch, .infrastructureFailure,
            .unviable, .timedOut, .flaky, .skipped, .noCoverage,
            .killedByAssertion, .killedByCrash
        ]

        for outcome in survivorsLaundered {
            let status = StrykerReporter.strykerStatus(for: outcome)
            // The four outcome-to-status mappings the schema permits.
            #expect([
                .killed, .survived, .noCoverage, .compileError,
                .runtimeError, .timeout, .ignored
            ].contains(status))

            // Only `survived` becomes `Survived`. Anything else laundered as
            // `Survived` is the bug this suite exists to prevent.
            if outcome != .survived {
                #expect(status != .survived, "\(outcome.displayName) laundered as Survived")
            }
        }

        // The exact mappings, restated so a change shows up as a single line.
        #expect(StrykerReporter.strykerStatus(for: .killedByAssertion) == .killed)
        #expect(StrykerReporter.strykerStatus(for: .killedByCrash) == .killed)
        #expect(StrykerReporter.strykerStatus(for: .survived) == .survived)
        #expect(StrykerReporter.strykerStatus(for: .noCoverage) == .noCoverage)
        #expect(StrykerReporter.strykerStatus(for: .unviable) == .compileError)
        #expect(StrykerReporter.strykerStatus(for: .timedOut) == .timeout)
        #expect(StrykerReporter.strykerStatus(for: .flaky) == .ignored)
        #expect(StrykerReporter.strykerStatus(for: .skipped) == .ignored)
        #expect(StrykerReporter.strykerStatus(for: .notApplied) == .runtimeError)
        #expect(StrykerReporter.strykerStatus(for: .baselineMismatch) == .runtimeError)
        #expect(StrykerReporter.strykerStatus(for: .infrastructureFailure) == .runtimeError)
    }

    /// `killedByCrash` is collapsed to `Killed`, but the distinction survives
    /// in `statusReason`. The status alone is what feeds the viewer's score, so
    /// that direction is allowed to lose information; the reason is what a
    /// reader uses to investigate, so the loss has to be visible there.
    @Test("A crash kill carries its distinction in statusReason")
    func crashKillPreservesDistinction() throws {
        let report = try reportWithOutcome(.killedByCrash, diagnosis: "trapped with SIGTRAP")
        let parsed = try Self.renderAndDecode(report)

        let mutant = try #require(parsed.files.values.flatMap(\.mutants).first)
        #expect(mutant.status == .killed)
        #expect(mutant.statusReason?.contains("crash") == true)
    }

    /// A `flaky` mutant is excluded from our score, which is exactly what
    /// Stryker's `Ignored` means. The mapping is honest in both directions.
    @Test("A flaky mutant maps to ignored")
    func flakyMapsToIgnored() throws {
        let report = try reportWithOutcome(.flaky)
        let parsed = try Self.renderAndDecode(report)

        let mutant = try #require(parsed.files.values.flatMap(\.mutants).first)
        #expect(mutant.status == .ignored)
    }

    @Test("Mutants inside a file are sorted by ID for byte-stable export")
    func mutantsAreSortedByID() throws {
        let a = try Self.anchoredPoint(file: "Sources/Q.swift", line: 1, marker: "A")
        let b = try Self.anchoredPoint(file: "Sources/Q.swift", line: 2, marker: "B")
        let c = try Self.anchoredPoint(file: "Sources/Q.swift", line: 3, marker: "C")

        let plan = Self.plan(mutations: [a, b, c])
        let results = [a, b, c].map {
            Self.result(point: $0, outcome: .killedByAssertion, diagnosis: "killed")
        }
        let report = Self.report(plan: plan, results: results)

        let parsed = try Self.renderAndDecode(report)
        let fileMutants = parsed.files["Sources/Q.swift"]?.mutants
        let mutantIDs = try #require(fileMutants).map { $0.id }

        #expect(mutantIDs == mutantIDs.sorted())
    }

    @Test("Thresholds are recorded verbatim")
    func thresholdsAreRecorded() throws {
        let report = try reportWithOutcome(.killedByAssertion)
        let parsed = try StrykerReporter(thresholds: .init(high: 90, low: 70))
            .render(report)
            |> Self.decode

        #expect(parsed.thresholds.high == 90)
        #expect(parsed.thresholds.low == 70)
    }

    /// A source provider is optional. When supplied, the source is recorded
    /// verbatim; when absent, the `source` key is omitted so the viewer fails
    /// schema validation loudly rather than drawing an empty file.
    @Test("Source is included when a provider is supplied, omitted when not")
    func sourceProviderContract() throws {
        let report = try reportWithOutcome(.killedByAssertion)

        let withSource = try Self.renderAndDecode(
            report, reporter: StrykerReporter(sourceProvider: { _ in "let x = 1" })
        )
        let withoutSource = try Self.renderAndDecode(report)

        #expect(withSource.files.values.first?.source == "let x = 1")
        #expect(withoutSource.files.values.first?.source == nil)
    }

    // MARK: - Location derivation

    /// Stryker wants an exclusive end position. A single-line span ends at the
    /// start column plus the source's character count.
    @Test("A single-line span ends at column + length")
    func singleLineEndLocation() {
        let end = StrykerReporter.endLocation(line: 3, column: 8, originalText: "true")
        #expect(end.line == 3)
        #expect(end.column == 12)
    }

    /// A multi-line span ends at the start of the column after its last line,
    /// matching how editors compute selections.
    @Test("A multi-line span ends on the last line")
    func multiLineEndLocation() {
        let end = StrykerReporter.endLocation(
            line: 4, column: 3, originalText: "foo\nbar\nbaz"
        )
        #expect(end.line == 6)
        #expect(end.column == 4)
    }

    @Test("An empty original text ends where it starts")
    func emptyEndLocation() {
        let end = StrykerReporter.endLocation(line: 5, column: 9, originalText: "")
        #expect(end.line == 5)
        #expect(end.column == 9)
    }

    // MARK: - Helpers

    private func reportWithOutcome(
        _ outcome: MutationOutcome,
        diagnosis: String = "test diagnosis"
    ) throws -> RunReport {
        // Two distinct source files give two distinct anchored IDs without
        // hand-writing them — and the IDs recompute identically, which is what
        // lets integrity pass and the score be non-nil.
        let point = try Self.anchoredPoint(file: "Sources/Q.swift", line: 7, marker: "Q")
        let plan = Self.plan(mutations: [point])
        let results = [Self.result(point: point, outcome: outcome, diagnosis: diagnosis)]
        return Self.report(plan: plan, results: results)
    }

    private static func renderAndDecode(
        _ report: RunReport,
        reporter: StrykerReporter = StrykerReporter()
    ) throws -> StrykerReporter.StrykerReport {
        try reporter.render(report) |> decode
    }

    private static func decode(_ json: String) throws -> StrykerReporter.StrykerReport {
        try MutationPlan.decoder().decode(
            StrykerReporter.StrykerReport.self,
            from: Data(json.utf8)
        )
    }

    /// Discover a real, anchored point. `marker` differentiates sources so two
    /// points in the same file still get distinct, stable IDs.
    private static func anchoredPoint(file: String, line: Int, marker: String) throws -> MutationPoint {
        let source = """
        struct \(marker) {
            var enabled = true
        }
        """
        return try discover(source, path: file, using: Operators.boolLiteral)[0]
    }

    private static func plan(mutations: [MutationPoint]) -> MutationPlan {
        MutationPlan(
            planID: "plan_stryker",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projectRoot: "/p",
            toolchain: ToolchainFingerprint(
                toolVersion: "0.1.0", toolCommitSHA: nil,
                swiftVersion: "6.3.3", swiftSyntaxVersion: "603.0.2",
                xcodeVersion: nil
            ),
            configurationHash: ContentHash.of("config"),
            sourceFileHashes: [:],
            mutations: mutations,
            skipped: [],
            operators: []
        )
    }

    private static func result(
        point: MutationPoint, outcome: MutationOutcome, diagnosis: String
    ) -> MutationResult {
        makeResult(
            point: point,
            outcome: outcome,
            evidence: MutationEvidence(
                sourceBeforeHash: ContentHash.of("before"),
                sourceAfterHash: ContentHash.of("after"),
                sourceDiff: "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-true\n+false\n",
                buildProductHash: ContentHash.of("mutant"),
                applicationEvidence: .isolated(.buildProductDiffersFromBaseline(
                    mutantHash: ContentHash.of("mutant"),
                    baselineHash: ContentHash.of("baseline")
                ))
            ),
            testSummary: TestOutcomeSummary(
                total: 1, passed: outcome == .survived ? 1 : 0,
                failed: outcome == .survived ? 0 : 1,
                failingTests: outcome == .survived ? [] : ["X/y()"],
                durationSeconds: 0.1
            ),
            diagnosis: diagnosis,
            durationSeconds: 0.5
        )
    }

    private static func report(plan: MutationPlan, results: [MutationResult]) -> RunReport {
        RunReport(
            planID: plan.planID,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 100),
            projectRoot: plan.projectRoot,
            toolchain: plan.toolchain,
            baseline: BaselineRecord(
                passed: true,
                testSummary: TestOutcomeSummary(
                    total: 1, passed: 1, failed: 0, failingTests: [], durationSeconds: 0.1
                ),
                durationSeconds: 0.5,
                buildProductHash: ContentHash.of("baseline"),
                buildCommand: nil, testCommand: nil
            ),
            ledger: makeLedger(results),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)
        )
    }
}

/// The pipeline operator Swift doesn't have, but reads cleanly in tests that
/// chain "render this, then decode that".
infix operator |>: AdditionPrecedence
func |> <A, B>(value: A, transform: (A) throws -> B) rethrows -> B { try transform(value) }
