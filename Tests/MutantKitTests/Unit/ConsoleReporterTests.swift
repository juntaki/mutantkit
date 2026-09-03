import Foundation
import MutationModel
import Reporting
import Testing

/// Colour in a redirected stream ends up in log files and CI artifacts as
/// mojibake, and tests need a stable byte sequence to compare against. The
/// console reporter's colour policy has to honour both: colours when stdout is
/// a TTY, plain text when it is not.
@Suite("Console reporter")
struct ConsoleReporterTests {
    /// When colour is disabled, the output must not contain any ANSI escape.
    /// Tests assert against this exact form, so even a single stray `\u{001B}`
    /// makes them byte-unstable.
    @Test("Colour-disabled output contains no ANSI escape sequences")
    func noANSIWhenDisabled() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point, point].deduplicatedByID())
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: point, outcome: .survived)]
        )

        let output = try ConsoleReporter(colorEnabled: false).render(report)

        #expect(!output.contains("\u{001B}"))
    }

    /// When colour is enabled, the output must use ANSI codes for the load-
    /// bearing emphasis: killed counts are green, survivors red, and the
    /// fail-closed banner red. Plain text in a TTY would be unreadable.
    @Test("Colour-enabled output marks survivors red and kills green")
    func colouredWhenEnabled() throws {
        let killed = try makeAnchoredPoint(file: "Sources/Killed.swift")
        let survived = try makeAnchoredPoint(file: "Sources/Survived.swift")
        let plan = makePlan(mutations: [killed, survived])
        let report = makeReport(
            plan: plan,
            results: [
                makeResult(point: killed, outcome: .killedByAssertion),
                makeResult(point: survived, outcome: .survived)
            ]
        )

        let output = try ConsoleReporter(colorEnabled: true).render(report)

        #expect(output.contains("\u{001B}[31m")) // red — used for survivors
        #expect(output.contains("\u{001B}[32m")) // green — used for kills
    }

    /// The fail-closed banner has to be unmissable in colour and present in
    /// plain text. Both forms have to spell out the headline verbatim, because
    /// a CI grep for the headline is how an operator finds broken runs.
    @Test("The fail-closed banner is present in both colour and plain modes")
    func failClosedBannerIsAlwaysPresent() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: point, outcome: .killedByAssertion)],
            baselinePassed: false
        )

        let plain = try ConsoleReporter(colorEnabled: false).render(report)
        let coloured = try ConsoleReporter(colorEnabled: true).render(report)

        #expect(plain.contains("NO MUTATION SCORE"))
        #expect(coloured.contains("NO MUTATION SCORE"))
        // Coloured mode wraps the headline in red.
        #expect(coloured.contains("\u{001B}[31m"))
    }

    /// Every section is rendered, in order, every time — even when it is empty.
    /// A missing section is a silent formatting regression; the survivor
    /// section is the most consequential one to drop.
    @Test("Every section is present in a normal report")
    func everySectionPresent() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: point, outcome: .survived)]
        )

        let output = try ConsoleReporter(colorEnabled: false).render(report)

        for section in ["Baseline", "Integrity", "Score", "Outcomes", "Actionable test gaps"] {
            #expect(output.contains(section), "missing section header: \(section)")
        }
    }

    /// A budget-sampled run's skip list is entirely `budgetExceeded` by
    /// design, and repeating that on its own line would just restate the
    /// count already on the line above. The breakdown is worth printing once
    /// a second reason shows up — that's the case an operator actually needs
    /// to notice.
    @Test("The skip breakdown appears only when more than budget is involved")
    func skipBreakdownAppearsOnlyWhenMixed() throws {
        let ran = try makeAnchoredPoint(file: "Sources/A.swift")
        let budgetSkipped = try makeAnchoredPoint(file: "Sources/B.swift")
        let disabledSkipped = try makeAnchoredPoint(file: "Sources/C.swift")

        let budgetOnlyPlan = makePlan(
            mutations: [ran],
            skipped: [SkippedMutation(id: budgetSkipped.id, file: budgetSkipped.file, reason: .budgetExceeded)]
        )
        let budgetOnlyOutput = try ConsoleReporter(colorEnabled: false).render(
            makeReport(plan: budgetOnlyPlan, results: [makeResult(point: ran, outcome: .killedByAssertion)])
        )
        #expect(!budgetOnlyOutput.contains("budgetExceeded:"))

        let mixedPlan = makePlan(
            mutations: [ran],
            skipped: [
                SkippedMutation(id: budgetSkipped.id, file: budgetSkipped.file, reason: .budgetExceeded),
                SkippedMutation(id: disabledSkipped.id, file: disabledSkipped.file, reason: .operatorDisabled)
            ]
        )
        let mixedOutput = try ConsoleReporter(colorEnabled: false).render(
            makeReport(plan: mixedPlan, results: [makeResult(point: ran, outcome: .killedByAssertion)])
        )
        #expect(mixedOutput.contains("budgetExceeded: 1"))
        #expect(mixedOutput.contains("operatorDisabled: 1"))
    }

    @Test("An empty run is still a valid report")
    func emptyRunIsRendered() throws {
        let plan = makePlan(mutations: [])
        let report = makeReport(plan: plan, results: [])

        let output = try ConsoleReporter(colorEnabled: false).render(report)

        #expect(output.contains("MutantKit mutation run"))
        // No surviving mutants — the section says so plainly rather than
        // disappearing.
        #expect(output.contains("none — every mutant that ran was killed"))
    }
}

private extension [MutationPoint] {
    /// Drops any duplicates by ID. Used in tests where the same anchored point
    /// is reused to build a plan that needs only one entry.
    func deduplicatedByID() -> [MutationPoint] {
        var seen: Set<MutationID> = []
        return filter { seen.insert($0.id).inserted }
    }
}
