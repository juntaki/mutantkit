import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Regression: **a mutant is reported that is not present in the source.**
///
/// The failure being reproduced: a report listed surviving mutants that had
/// never been written to any file. A developer chasing one of them finds the
/// line already correct, and every number in the report is unfalsifiable — there
/// is no artifact tying a verdict to a change.
///
/// The rule that replaces it: if we cannot prove it, we do not score it. A
/// result is reportable only when it carries evidence of a real source change,
/// and a run containing an unprovable result publishes no score at all.
@Suite("Regression: a reported mutant must exist in the source")
struct PhantomMutantTests {
    /// ADR-0006 Stage 1: a scorable outcome with genuinely *no* evidence at
    /// all is no longer constructible — `ExecutedMutationProof` requires
    /// real evidence to exist as a precondition of the type itself, not a
    /// runtime check `isReportable` re-verifies afterward. What remains
    /// constructible, and what `isReportable` still has to catch, is
    /// *hollow* evidence: real, present, but proving nothing (identical
    /// before/after hashes) — the shape a caller could still assemble
    /// honestly and have it turn out empty.
    @Test("A verdict with hollow (no-op) evidence is not reportable")
    func verdictWithHollowEvidenceIsNotReportable() throws {
        let point = try makeAnchoredPoint()
        let hollow = MutationEvidence(
            sourceBeforeHash: ContentHash.of("same"), sourceAfterHash: ContentHash.of("same"), sourceDiff: ""
        )

        for outcome in MutationOutcome.allCases where outcome.isScorable {
            let result = makeResult(point: point, outcome: outcome, evidence: hollow)
            #expect(!result.isReportable, "\(outcome.displayName) was reportable with hollow evidence")
        }
    }

    /// `skipped` and `notApplied` never touched the source, so for them the
    /// absence of a diff *is* the honest record.
    @Test("Outcomes that never touched the source are exempt from needing a diff")
    func outcomesThatNeverTouchedTheSourceAreExempt() throws {
        let point = try makeAnchoredPoint()

        for outcome in [MutationOutcome.skipped, .notApplied] {
            let result = makeResult(point: point, outcome: outcome, evidence: nil, testSummary: nil)
            #expect(result.isReportable)
        }
    }

    /// The end-to-end statement of the rule: one unprovable mutant anywhere in
    /// the run means no score, not a slightly-wrong score.
    @Test("A single unprovable mutant withholds the whole run's score")
    func oneUnprovableMutantWithholdsTheScore() throws {
        let honest = try makeAnchoredPoint(file: "Sources/A.swift")
        let phantom = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [honest, phantom])

        let cleanReport = makeReport(plan: plan, results: [
            makeResult(point: honest, outcome: .killedByAssertion),
            makeResult(point: phantom, outcome: .survived)
        ])
        #expect(cleanReport.score != nil)

        // The same run, with the phantom `.notApplied` instead of `.survived`
        // with hollowed-out evidence: ADR-0006 Stage 1 moved "no proof, no
        // score" from an `IntegrityChecker` runtime check on evidence
        // quality to a construction-time guarantee — `MutationVerdictVerifier`
        // is the only real path to a scorable outcome, and it only ever
        // attaches evidence it built from a genuine `MutationApplication
        // .apply` diff, so a scorable-but-hollow-evidence result can no
        // longer arise from the pipeline this test exercises end to end.
        // `.notApplied` is the one remaining "loud, unprovable, never
        // silently scored" case IntegrityChecker still actively flags — see
        // `IntegrityChecker.check`'s own doc comment.
        let phantomReport = makeReport(plan: plan, results: [
            makeResult(point: honest, outcome: .killedByAssertion),
            makeResult(point: phantom, outcome: .notApplied, evidence: nil, testSummary: nil)
        ])

        #expect(phantomReport.score == nil)
        #expect(phantomReport.integrity.violations.kinds == [.phantomMutant])
        // `.notApplied` never touched the source, so the absence of a diff
        // *is* its honest record — `isReportable` exempts it, same as
        // `.skipped` (see `outcomesThatNeverTouchedTheSourceAreExempt`), so
        // both results count as `reported` even though the run's score is
        // withheld by the violation above.
        #expect(phantomReport.integrity.reported == 2)
        #expect(phantomReport.integrity.classified == 2)
    }

    /// Evidence produced by the real application path always proves itself, so
    /// the honest path cannot accidentally produce a phantom.
    @Test("Evidence from a real application always proves the change")
    func realApplicationAlwaysProducesProof() throws {
        let source = try Fixture.text("RealisticViewModel")
        let data = Data(source.utf8)

        for point in try discover(source, path: "Sources/CartViewModel.swift") {
            let applied = try MutationApplication.apply(point, to: data)

            #expect(applied.evidence.provesSourceApplication)
            // The diff is the artifact a reviewer reads; it must name the file
            // and show the change.
            #expect(applied.evidence.sourceDiff.contains(point.file))
            #expect(applied.evidence.sourceDiff.contains("@@"))
        }
    }

    /// A no-op mutation would build to an identical binary and be reported as a
    /// mutant that never mutated anything. Discovery refuses to create one, so
    /// the phantom cannot enter the plan in the first place.
    @Test("A no-op mutation never enters the plan")
    func noOpMutationsNeverEnterThePlan() throws {
        for fixture in ["RealisticViewModel", "UnicodeHeavy"] {
            for point in try discover(try Fixture.text(fixture), path: "Sources/\(fixture).swift") {
                #expect(point.originalText != point.replacementText)
            }
        }
    }
}

/// Regression: **a replacement lands at the wrong offset and produces invalid
/// Swift.**
///
/// The failure being reproduced: an edit applied at an offset that no longer
/// meant what the plan thought it meant — because the file had changed, or
/// because a character offset was used where a byte offset was required. The
/// output was either uncompilable (an expensive `unviable` that teaches nothing)
/// or, worse, valid Swift that mutated something nobody planned.
@Suite("Regression: a replacement never lands at the wrong offset")
struct WrongOffsetTests {
    /// The stale-anchor half: the file moved on, so the recorded offsets now
    /// point at different code. The only safe answer is a refusal.
    @Test("A stale anchor is refused instead of spliced")
    func staleAnchorIsRefused() throws {
        let original = """
        struct Cart {
            func isReady() -> Bool { return true }
        }
        """
        let point = try discover(original, path: "Sources/Cart.swift", using: Operators.boolLiteral)[0]

        // Somebody edits above the mutation site while the run is in flight.
        let edited = """
        import Foundation

        struct Cart {
            func isReady() -> Bool { return true }
        }
        """

        #expect(throws: ApplicationError.self) {
            try MutationApplication.apply(point, to: Data(edited.utf8))
        }
    }

    /// The refusal must be a diagnosis, not a guess: relocating the anchor to a
    /// plausible nearby offset is exactly how a tool corrupts a file.
    @Test("A stale anchor is never relocated to a nearby match")
    func staleAnchorIsNotRelocated() throws {
        let original = """
        struct Cart {
            func isReady() -> Bool { return true }
        }
        """
        let point = try discover(original, path: "Sources/Cart.swift", using: Operators.boolLiteral)[0]

        // The same `true` still exists — just two bytes later. A tool that
        // searched for it would "succeed" here.
        let shifted = """
        struct Cart {
              func isReady() -> Bool { return true }
        }
        """

        do {
            let applied = try MutationApplication.apply(point, to: Data(shifted.utf8))
            Issue.record("the anchor was relocated and applied at \(applied.point.utf8Range)")
        } catch let error as ApplicationError {
            let verification = try #require(error.verification)
            #expect(!verification.isValid)
            #expect(verification.failureNames.contains("fileHashMismatch"))
        }
    }

    /// The byte-offset half: a file whose multi-byte characters make byte and
    /// character offsets disagree. Every mutation must still land exactly on its
    /// token and leave a parseable file.
    @Test("Multi-byte text before the site never shifts a splice")
    func multiByteTextNeverShiftsASplice() throws {
        let source = try Fixture.text("UnicodeHeavy")
        let data = Data(source.utf8)
        let points = try discover(source, path: "Sources/UnicodeHeavy.swift")

        #expect(!points.isEmpty)
        for point in points {
            let applied = try MutationApplication.apply(point, to: data)

            #expect(parsesWithoutError(applied.mutatedSource))

            // The bytes outside the splice are untouched, so nothing upstream of
            // the site was clipped or shifted.
            let before = [UInt8](data)
            let after = [UInt8](applied.mutatedSource)
            let delta = point.replacementText.utf8.count - point.originalText.utf8.count
            #expect(Array(before[0 ..< point.utf8Range.start]) == Array(after[0 ..< point.utf8Range.start]))
            #expect(Array(before[point.utf8Range.end...]) == Array(after[(point.utf8Range.end + delta)...]))
        }
    }
}
