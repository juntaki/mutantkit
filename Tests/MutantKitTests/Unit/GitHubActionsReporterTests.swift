import Foundation
import MutationModel
@testable import Reporting
import Testing

/// Phase C7 (competitive-parity program): `GitHubActionsReporter` is the one
/// concrete gap C0 found in this codebase's CI story — `CISummaryReporter`
/// gives a markdown job summary, but nothing ever emitted the
/// `::warning::`/`::error::` workflow-command syntax GitHub's own runner
/// parses out of a step's stdout to create inline PR annotations.
///
/// Correctness here has a sharp edge most reporters do not: an incorrectly
/// escaped workflow command is not merely ugly, it is silently truncated or
/// misparsed by GitHub's own runner, so this suite tests the escaping rules
/// directly, not just "does the output contain the right substring."
@Suite("GitHub Actions reporter")
struct GitHubActionsReporterTests {
    private func point(file: String = "Sources/Example.swift") throws -> MutationPoint {
        try makeAnchoredPoint(file: file)
    }

    // MARK: - Survivor annotations

    @Test("A survivor renders as a ::warning:: annotation anchored to its file/line/col")
    func survivorRendersAsWarning() throws {
        let mutationPoint = try point()
        let plan = makePlan(mutations: [mutationPoint])
        let report = makeReport(plan: plan, results: [makeResult(point: mutationPoint, outcome: .survived)])

        let output = try GitHubActionsReporter().render(report)

        #expect(output.hasPrefix("::warning file=\(mutationPoint.file),line=\(mutationPoint.line),col=\(mutationPoint.column)::"))
        #expect(output.contains("Mutant survived:"))
        #expect(output.contains("[\(mutationPoint.id)]"))
        #expect(output.contains("mutantkit inspect \(mutationPoint.id.rawValue)"))
    }

    @Test("A killed mutant produces no annotation at all")
    func killedMutantProducesNoAnnotation() throws {
        let mutationPoint = try point()
        let plan = makePlan(mutations: [mutationPoint])
        let report = makeReport(plan: plan, results: [makeResult(point: mutationPoint, outcome: .killedByAssertion)])

        let output = try GitHubActionsReporter().render(report)

        #expect(output.isEmpty)
    }

    @Test("Multiple survivors each get their own line, one command per line")
    func multipleSurvivorsEachGetOwnLine() throws {
        let first = try point(file: "Sources/A.swift")
        let second = try point(file: "Sources/B.swift")
        let plan = makePlan(mutations: [first, second])
        let report = makeReport(
            plan: plan,
            results: [
                makeResult(point: first, outcome: .survived),
                makeResult(point: second, outcome: .survived)
            ]
        )

        let output = try GitHubActionsReporter().render(report)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)

        #expect(lines.count == 2)
        for line in lines {
            #expect(line.hasPrefix("::warning file="))
        }
    }

    // MARK: - Fail-closed / integrity violations

    @Test("Integrity failure emits ::error:: annotations, never a survivor warning")
    func integrityFailureEmitsErrorNotWarning() throws {
        let mutationPoint = try point()
        let plan = makePlan(mutations: [mutationPoint])
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: mutationPoint, outcome: .survived)],
            baselinePassed: false
        )

        let output = try GitHubActionsReporter().render(report)

        #expect(!output.isEmpty)
        #expect(!output.contains("::warning"))
        #expect(output.contains("::error"))
        #expect(!output.contains("Mutant survived:"))
    }

    @Test("A whole-run violation with no mutation to anchor to omits file/line/col entirely")
    func unanchoredViolationOmitsProperties() throws {
        // An empty plan/ledger with a failed baseline is a whole-run
        // violation with no `mutationID` to anchor to -- GitHub's own syntax
        // permits a bare `::error::message`, unlike XcodeReporter, which has
        // no such affordance and must fabricate a `1:1` location instead.
        let plan = makePlan(mutations: [])
        let report = makeReport(plan: plan, results: [], baselinePassed: false)

        let output = try GitHubActionsReporter().render(report)

        #expect(!output.isEmpty)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            #expect(line.hasPrefix("::error::"), "expected a bare, property-less error command, got: \(line)")
        }
    }

    // MARK: - Escaping

    /// GitHub's own documented escaping for workflow-command *data* (the
    /// message text): `%`, then CR, then LF. Order matters -- escaping `%`
    /// last would double-escape the `%` this method's own CR/LF replacements
    /// introduce.
    @Test("Message escaping handles %, CR, and LF in the diagnosis text")
    func messageEscapesPercentAndNewlines() throws {
        let mutationPoint = try point()
        let plan = makePlan(mutations: [mutationPoint])
        let report = makeReport(
            plan: plan,
            results: [makeResult(point: mutationPoint, outcome: .survived, diagnosis: "100% sure\r\nline two")]
        )

        let output = try GitHubActionsReporter().render(report)

        #expect(output.contains("100%25 sure%0D%0Aline two"))
        // The raw control characters must never survive into the emitted
        // command -- a literal newline would split one annotation into two
        // lines GitHub cannot parse as a single command.
        #expect(!output.contains("100% sure\r\nline two"))
    }

    /// GitHub's own escaping for a workflow-command *property value*
    /// additionally escapes `,` and `:`, since both are themselves
    /// delimiter syntax in the property list (`file=...,line=...`). A file
    /// path is an unlikely but not impossible place for either character to
    /// appear (a colon in particular is legal in a POSIX filename).
    @Test("Property escaping handles comma and colon in a file path")
    func propertyEscapesCommaAndColon() throws {
        let mutationPoint = try point(file: "Sources/weird,name:file.swift")
        let plan = makePlan(mutations: [mutationPoint])
        let report = makeReport(plan: plan, results: [makeResult(point: mutationPoint, outcome: .survived)])

        let output = try GitHubActionsReporter().render(report)

        #expect(output.contains("file=Sources/weird%2Cname%3Afile.swift,line="))
        #expect(!output.contains("file=Sources/weird,name:file.swift"))
    }
}
