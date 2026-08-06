import Foundation
import MutationModel
import Testing

/// Most of the damage a mutation tool does comes from folding an *unknown* into
/// `survived`. A mutant that never compiled, never ran, or never reached the
/// source is a fact about the tool run — not about the test suite — and must not
/// touch a denominator.
@Suite("Mutation score")
struct MutationScoreTests {
    @Test("Killed outcomes are the numerator")
    func killedOutcomes() {
        #expect(MutationOutcome.killedByAssertion.isKilled)
        #expect(MutationOutcome.killedByCrash.isKilled)

        for outcome in MutationOutcome.allCases where !outcome.isKilled {
            #expect(!outcome.isKilled)
        }

        let score = MutationScore.tally([.killedByAssertion, .killedByCrash])
        #expect(score.killed == 2)
    }

    /// Only outcomes that say something about test quality belong in a
    /// denominator. This is the list, and it is deliberately short.
    @Test("Exactly five outcomes are scorable")
    func scorableOutcomes() {
        let scorable = MutationOutcome.allCases.filter(\.isScorable)

        #expect(Set(scorable) == [.killedByAssertion, .killedByCrash, .verifiedTimeout, .survived, .noCoverage])
    }

    /// The whole point of separating `Detection` from `Manifestation`: a
    /// mutant confirmed killed by crash, by assertion failure, or by a
    /// reproduced timeout must move the score identically. A project found —
    /// empirically, across two machines — that the same mutant's
    /// manifestation is not stable, while whether it was caught at all is.
    @Test("crash, assertion, and verified-timeout kills score identically")
    func manifestationDoesNotAffectScore() {
        let byCrash = MutationScore.tally([.killedByCrash, .survived])
        let byAssertion = MutationScore.tally([.killedByAssertion, .survived])
        let byVerifiedTimeout = MutationScore.tally([.verifiedTimeout, .survived])

        #expect(byCrash.killed == byAssertion.killed)
        #expect(byAssertion.killed == byVerifiedTimeout.killed)
        #expect(byCrash.tested == byAssertion.tested)
        #expect(byAssertion.tested == byVerifiedTimeout.tested)
        #expect(byCrash.effective == byAssertion.effective)
        #expect(byAssertion.effective == byVerifiedTimeout.effective)
    }

    /// An unconfirmed `.timedOut` is not yet known to be a kill — it stays
    /// excluded until (or unless) an independent rebuild reproduces it as
    /// `.verifiedTimeout`. Conflating the two would silently score every
    /// pending timeout as a kill before it was ever confirmed.
    @Test("An unconfirmed timeout is excluded; a verified one is killed")
    func unconfirmedVersusVerifiedTimeout() {
        let unconfirmed = MutationScore.tally([.timedOut, .survived])
        let verified = MutationScore.tally([.verifiedTimeout, .survived])

        #expect(unconfirmed.killed == 0)
        #expect(unconfirmed.excluded == ["timedOut": 1])
        #expect(verified.killed == 1)
        #expect(verified.excluded.isEmpty)
    }

    @Test("Outcomes that break the run are integrity violations")
    func integrityViolatingOutcomes() {
        let violating = MutationOutcome.allCases.filter(\.isIntegrityViolation)

        #expect(Set(violating) == [.notApplied, .baselineMismatch])
    }

    /// The specific laundering this guards against: `unviable`, `timedOut`,
    /// `notApplied` and `infrastructureFailure` all look like "the tests didn't
    /// catch it" if you only track a boolean.
    @Test("Inconclusive outcomes are excluded from every denominator")
    func inconclusiveOutcomesAreExcluded() {
        let score = MutationScore.tally([
            .killedByAssertion,
            .survived,
            .noCoverage,
            .unviable,
            .timedOut,
            .notApplied,
            .infrastructureFailure
        ])

        #expect(score.killed == 1)
        #expect(score.survived == 1)
        #expect(score.noCoverage == 1)

        #expect(score.excluded == [
            "unviable": 1,
            "timedOut": 1,
            "notApplied": 1,
            "infrastructureFailure": 1
        ])

        // tested  = 1 / (1 killed + 1 survived)
        // effective = 1 / (1 killed + 1 survived + 1 noCoverage)
        #expect(score.tested == 0.5)
        #expect(score.effective == 1.0 / 3.0)

        // The four excluded outcomes moved neither denominator.
        let withoutExcluded = MutationScore.tally([.killedByAssertion, .survived, .noCoverage])
        #expect(withoutExcluded.tested == score.tested)
        #expect(withoutExcluded.effective == score.effective)
    }

    @Test("Flaky and skipped outcomes are excluded too")
    func flakyAndSkippedAreExcluded() {
        let score = MutationScore.tally([.killedByAssertion, .flaky, .skipped])

        #expect(score.excluded == ["flaky": 1, "skipped": 1])
        #expect(score.tested == 1.0)
    }

    /// `tested` answers "of the code my tests actually run, how much do they
    /// check?"; `effective` answers "of the code I asked to be mutated, how much
    /// is checked?". A suite with poor coverage looks excellent if you only
    /// report the first.
    @Test("The two scores answer different questions")
    func testedAndEffectiveDiffer() {
        // Everything the tests touch is killed, but half the mutants were never
        // covered at all.
        let score = MutationScore.tally([.killedByAssertion, .killedByAssertion, .noCoverage, .noCoverage])

        #expect(score.tested == 1.0)
        #expect(score.effective == 0.5)
    }

    /// "No data" and "everything survived" are different findings, and a 0 would
    /// confuse them.
    @Test("A score with no data is nil, not zero")
    func noDataIsNilNotZero() {
        let empty = MutationScore.tally([])

        #expect(empty.tested == nil)
        #expect(empty.effective == nil)
        #expect(empty.killed == 0)
    }

    @Test("A run of only excluded outcomes has no score")
    func onlyExcludedOutcomesHasNoScore() {
        let score = MutationScore.tally([.unviable, .timedOut, .notApplied, .skipped])

        #expect(score.tested == nil)
        #expect(score.effective == nil)
    }

    /// `noCoverage` is scorable but not killable: it moves `effective` without
    /// touching `tested`.
    @Test("noCoverage affects only the effective score")
    func noCoverageOnlyAffectsEffective() {
        let withoutCoverage = MutationScore.tally([.killedByAssertion, .noCoverage])

        #expect(withoutCoverage.tested == 1.0)
        #expect(withoutCoverage.effective == 0.5)
    }

    @Test("Everything surviving is a zero, not a nil")
    func everythingSurvivingIsZero() {
        let score = MutationScore.tally([.survived, .survived])

        #expect(score.tested == 0.0)
        #expect(score.effective == 0.0)
    }

    @Test("A score survives serialization unchanged")
    func scoreRoundTrips() throws {
        let score = MutationScore.tally([.killedByAssertion, .survived, .noCoverage, .unviable])

        let data = try JSONEncoder().encode(score)
        let decoded = try JSONDecoder().decode(MutationScore.self, from: data)

        #expect(decoded == score)
        #expect(decoded.tested == score.tested)
    }
}
