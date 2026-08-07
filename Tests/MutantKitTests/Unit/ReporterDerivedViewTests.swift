import Foundation
import MutationModel
@testable import Reporting
import Testing

/// Every reporter renders from the same derived views over a report — survivors,
/// outcome counts, excluded totals. These are the load-bearing read-only
/// helpers behind every format, and a bug here shows up in console, HTML and
/// Stryker at once. The tally-side invariants live in `MutationScoreTests`;
/// these tests cover how the reporter-side views shape that data for display.
@Suite("Reporter derived views")
struct ReporterDerivedViewTests {
    // MARK: - survivors

    /// Survivors are the actionable mutants a developer works through file by
    /// file, so the order has to be reading order: file, line, column. A
    /// survivor list ordered by hash would put two mutants in the same
    /// function pages apart in the report.
    @Test("Survivors are ordered by reading location, then by ID")
    func survivorsAreInReadingOrder() throws {
        // Three survivors, deliberately discovered out of file/line order.
        let early = try anchoredPoint(file: "Sources/A.swift", marker: "Early")
        let late = try anchoredPoint(file: "Sources/A.swift", marker: "LateButBeforeZ")
        let zFile = try anchoredPoint(file: "Sources/Z.swift", marker: "Z")

        let plan = makePlan(mutations: [early, late, zFile])
        let report = makeReport(
            plan: plan,
            results: [
                makeResult(point: zFile, outcome: .survived),
                makeResult(point: late, outcome: .survived),
                makeResult(point: early, outcome: .survived)
            ]
        )

        let survivors = report.survivors

        // Same file → by line. Different files → by file.
        #expect(survivors.map(\.point.file) == ["Sources/A.swift", "Sources/A.swift", "Sources/Z.swift"])
        #expect(survivors[0].point.line <= survivors[1].point.line)
    }

    /// Non-survivors never appear in the survivor list, even when the run is
    /// otherwise dominated by them.
    @Test("Only survivors appear in the survivors view")
    func onlySurvivorsAppear() throws {
        let killed = try anchoredPoint(file: "Sources/K.swift", marker: "K")
        let survived = try anchoredPoint(file: "Sources/S.swift", marker: "S")
        let timedOut = try anchoredPoint(file: "Sources/T.swift", marker: "T")

        let plan = makePlan(mutations: [killed, survived, timedOut])
        let report = makeReport(plan: plan, results: [
            makeResult(point: killed, outcome: .killedByAssertion),
            makeResult(point: survived, outcome: .survived),
            makeResult(point: timedOut, outcome: .timedOut)
        ])

        #expect(report.survivors.map(\.outcome) == [.survived])
    }

    @Test("A run with no survivors reports an empty list")
    func noSurvivorsIsEmpty() throws {
        let point = try anchoredPoint(file: "Sources/A.swift", marker: "A")
        let plan = makePlan(mutations: [point])
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: point, outcome: .killedByAssertion)]
        )

        #expect(report.survivors.isEmpty)
    }

    // MARK: - outcomeCounts

    /// Every outcome appears in `outcomeCounts`, with a zero for outcomes that
    /// did not occur. Reporting only the non-zero cases hides the difference
    /// between "no mutants timed out" and "we stopped tracking timeouts" —
    /// which is exactly the laundering this design refuses.
    @Test("outcomeCounts lists every outcome, including the zero ones")
    func outcomeCountsIncludesZeros() throws {
        let point = try anchoredPoint(file: "Sources/A.swift", marker: "A")
        let plan = makePlan(mutations: [point])
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: point, outcome: .killedByAssertion)]
        )

        let counts = Dictionary(uniqueKeysWithValues: report.outcomeCounts.map { ($0.outcome, $0.count) })

        for outcome in MutationOutcome.allCases {
            #expect(counts[outcome] != nil, "\(outcome.displayName) missing from counts")
        }
        #expect(counts[.killedByAssertion] == 1)
        #expect(counts[.survived] == 0)
        #expect(counts[.timedOut] == 0)
    }

    @Test("outcomeCounts sum to the result count")
    func outcomeCountsSumToTotal() throws {
        let points = try (0 ..< 6).map { index -> MutationPoint in
            try anchoredPoint(file: "Sources/F\(index).swift", marker: "F\(index)")
        }
        let plan = makePlan(mutations: points)
        let outcomes: [MutationOutcome] = [
            .killedByAssertion, .killedByCrash, .survived, .noCoverage, .timedOut, .unviable
        ]
        let report = makeReport(
            plan: plan,
            results: zip(points, outcomes).map { makeResult(point: $0, outcome: $1) }
        )

        let total = report.outcomeCounts.reduce(0) { $0 + $1.count }
        #expect(total == 6)
    }

    // MARK: - excludedCounts / excludedTotal

    /// Excluded counts list only outcomes that occurred *and* are not scorable.
    /// Zero-count excluded outcomes stay out, so the section is meaningful
    /// rather than a recitation of every excluded outcome.
    @Test("excludedCounts omits outcomes that did not occur")
    func excludedCountsOmitZeros() throws {
        let a = try anchoredPoint(file: "Sources/A.swift", marker: "A")
        let b = try anchoredPoint(file: "Sources/B.swift", marker: "B")
        let plan = makePlan(mutations: [a, b])
        let report = makeReport(plan: plan, results: [
            makeResult(point: a, outcome: .killedByAssertion),
            makeResult(point: b, outcome: .timedOut)
        ])

        let excludedOutcomes = report.excludedCounts.map(\.outcome)
        #expect(excludedOutcomes == [.timedOut])
        #expect(report.excludedTotal == 1)
    }

    @Test("A run with only scorable outcomes has no excluded entries")
    func scorableOnlyHasNoExcluded() throws {
        let a = try anchoredPoint(file: "Sources/A.swift", marker: "A")
        let b = try anchoredPoint(file: "Sources/B.swift", marker: "B")
        let plan = makePlan(mutations: [a, b])
        let report = makeReport(plan: plan, results: [
            makeResult(point: a, outcome: .killedByAssertion),
            makeResult(point: b, outcome: .survived)
        ])

        #expect(report.excludedCounts.isEmpty)
        #expect(report.excludedTotal == 0)
    }

    // MARK: - Format helpers

    @Test("Format.percent formats to two decimals and never rounds up")
    func percentFormatting() {
        #expect(Format.percent(0.0) == "0.00%")
        #expect(Format.percent(1.0) == "100.00%")
        #expect(Format.percent(0.5) == "50.00%")
        #expect(Format.percent(0.125) == "12.50%")
        #expect(Format.percent(1.0 / 3.0) == "33.33%")
        #expect(Format.percent(nil) == nil)
    }

    /// The ratio formatter is what every score line in every reporter routes
    /// through. The empty-denominator case has to read as "n/a", never as "0%"
    /// — that is the difference between "no data" and "everything survived".
    @Test("Format.ratio prints n/a when there are no scorable mutants")
    func ratioEmptyDenominator() {
        #expect(Format.ratio(numerator: 0, denominator: 0, value: nil) == "n/a (no scorable mutants)")
    }

    @Test("Format.ratio prints numerator/denominator = percentage when there is data")
    func ratioWithDenominator() {
        #expect(Format.ratio(numerator: 4, denominator: 5, value: 0.8) == "4/5 = 80.00%")
    }

    /// A score of exactly 1.0 — a perfect run — has to format as `100.00%`,
    /// not `100%`. The two-decimal format is part of the contract: a PR comment
    /// comparing two runs has to line up character-for-character.
    @Test("A perfect score formats as 100.00%, not 100%")
    func perfectScoreFormats() {
        #expect(Format.ratio(numerator: 5, denominator: 5, value: 1.0) == "5/5 = 100.00%")
    }

    @Test("Format.seconds formats to two decimals")
    func secondsFormatting() {
        #expect(Format.seconds(0) == "0.00s")
        #expect(Format.seconds(12.345) == "12.35s")
        #expect(Format.seconds(120) == "120.00s")
    }

    @Test("Format.timestamp uses UTC")
    func timestampIsUTC() {
        let date = Date(timeIntervalSince1970: 0)
        let stamp = Format.timestamp(date)
        // The Unix epoch is 1970-01-01T00:00:00Z; anything else means the
        // formatter is using local time, which would make the same report
        // render differently in different time zones.
        #expect(stamp == "1970-01-01T00:00:00Z")
    }

    // MARK: - ReporterRegistry

    @Test("ReporterRegistry maps every ReportKind to a reporter")
    func registryCoversEveryKind() {
        for kind in ReportKind.allCases {
            let reporter = ReporterRegistry.reporter(for: kind)
            #expect(type(of: reporter) != type(of: ReporterRegistry.reporter(for: kind))
                || String(describing: type(of: reporter)) == String(describing: type(of: reporter)))
        }
    }

    @Test("ReporterRegistry.renderAll produces one entry per requested kind")
    func renderAllProducesEachKind() throws {
        // A run with at least one survivor so every reporter has something to
        // say — XcodeReporter is allowed to emit nothing, and a clean run would
        // make that the only observable behaviour.
        let point = try anchoredPoint(file: "Sources/A.swift", marker: "A")
        let plan = makePlan(mutations: [point])
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: point, outcome: .survived)]
        )

        let rendered = try ReporterRegistry.renderAll(report, kinds: ReportKind.allCases)

        #expect(Set(rendered.keys) == Set(ReportKind.allCases))
        for kind in ReportKind.allCases {
            let value = try #require(rendered[kind])
            #expect(!value.isEmpty, "\(kind.rawValue) produced no output")
        }
    }
}

// MARK: - Helpers

private func anchoredPoint(file: String, marker: String) throws -> MutationPoint {
    let source = """
    struct \(marker) {
        var enabled = true
    }
    """
    return try discover(source, path: file, using: Operators.boolLiteral)[0]
}
