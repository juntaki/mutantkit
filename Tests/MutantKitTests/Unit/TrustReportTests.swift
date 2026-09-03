import Foundation
import MutationModel
import Reporting
import Testing

/// `TrustReport.build(from:)` — a new summary view over an already-decided
/// `RunReport`, never a re-verification. Every assertion here checks that a
/// field is read (or tallied) from real `RunReport` data exactly the way
/// production code elsewhere already defines it (`IntegrityChecker`'s
/// `phantomMutant`, `InspectCommand.agentEvidenceInfo`'s activation-evidence
/// kinds), not a redefinition invented for this report alone.
@Suite("TrustReport")
struct TrustReportTests {
    // MARK: - Healthy report

    @Test("A clean report with proven isolated activation is trustworthy, with zero phantom mutants")
    func cleanReportIsTrustworthy() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion)])

        let trust = TrustReport.build(from: report)

        #expect(trust.trustworthy)
        #expect(trust.integrity.passed)
        #expect(trust.integrity.violationCount == 0)
        #expect(trust.phantomMutantCount == 0)
        #expect(trust.sourceApplication.withEvidence == 1)
        #expect(trust.sourceApplication.withoutEvidence == 0)
        #expect(trust.activationEvidence.isolatedProven == 1)
        #expect(trust.activationEvidence.isolatedNotProven == 0)
        #expect(trust.activationEvidence.schemataPresent == 0)
        #expect(trust.activationEvidence.noEvidence == 0)
        // Reused verbatim from `report.score`, not recomputed.
        #expect(trust.score == report.score)
        #expect(trust.score?.killed == 1)
    }

    // MARK: - Phantom mutant (ADR trust invariant: never laundered into survived)

    @Test("A .notApplied result is counted as exactly one phantom mutant, and withholds trust")
    func phantomMutantIsCountedAndUntrusted() throws {
        let honest = try makeAnchoredPoint(file: "Sources/A.swift")
        let phantom = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [honest, phantom])
        let report = makeReport(plan: plan, results: [
            makeResult(point: honest, outcome: .killedByAssertion),
            makeResult(point: phantom, outcome: .notApplied, evidence: nil, testSummary: nil)
        ])

        let trust = TrustReport.build(from: report)

        #expect(!trust.trustworthy)
        #expect(trust.phantomMutantCount == 1)
        #expect(trust.integrity.violationsByKind["phantomMutant"] == 1)
        // No score claim stands once integrity fails — reused, not
        // recomputed, so this must match `report.score` exactly (both nil).
        #expect(trust.score == nil)
        #expect(report.score == nil)
    }

    // MARK: - Score gating enforced on the decode path, not just via RunReport.init

    @Test("A decoded report with real integrity violations and a populated score still yields a nil TrustReport score")
    func decodedReportWithViolationsAndScoreYieldsNilScore() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        // Built the normal way, so this starts out healthy: no violations,
        // and a real, non-nil `score`.
        let healthyReport = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion)])
        #expect(healthyReport.integrity.passed)
        #expect(healthyReport.score != nil)

        // Simulate a hand-corrupted report.json: a real integrity violation
        // spliced into the JSON after the fact, right alongside the score
        // that was already written — the exact shape `RunReport.init(from:)`
        // (the decode path `mutantkit trust` actually uses) never guards
        // against, since only the memberwise `init` used when a report is
        // freshly produced enforces "no score without passing integrity".
        let violation = IntegrityViolation(kind: .phantomMutant, detail: "corrupted for test", mutationID: nil)
        let violationJSON = try JSONSerialization.jsonObject(with: MutationPlan.encoder().encode(violation))

        var reportJSON = try #require(
            JSONSerialization.jsonObject(with: MutationPlan.encoder().encode(healthyReport)) as? [String: Any]
        )
        var integrityJSON = try #require(reportJSON["integrity"] as? [String: Any])
        integrityJSON["violations"] = [violationJSON]
        reportJSON["integrity"] = integrityJSON

        let corruptedData = try JSONSerialization.data(withJSONObject: reportJSON)
        let decoded = try MutationPlan.decoder().decode(RunReport.self, from: corruptedData)

        // Confirm the fixture is corrupted the way this test intends before
        // trusting what `TrustReport.build` does with it: real violations,
        // but `score` still populated from the original, healthy encode.
        #expect(!decoded.integrity.passed)
        #expect(decoded.score != nil)

        let trust = TrustReport.build(from: decoded)

        #expect(!trust.trustworthy)
        #expect(trust.score == nil)
    }

    // MARK: - Activation evidence breakdown

    @Test("Isolated activation evidence that proves nothing (no-op) is counted separately from proven")
    func unprovenIsolatedActivationIsCountedSeparately() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let hollowButReal = MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"), sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "--- a/Sources/A.swift\n+++ b/Sources/A.swift\n@@ -1 +1 @@\n-true\n+false\n",
            buildProductHash: ContentHash.of("same-as-baseline"),
            applicationEvidence: .isolated(.buildProductIdenticalToBaseline(hash: ContentHash.of("same-as-baseline")))
        )
        let report = makeReport(plan: plan, results: [
            makeResult(point: point, outcome: .noCoverage, evidence: hollowButReal, testSummary: nil)
        ])

        let trust = TrustReport.build(from: report)

        #expect(trust.activationEvidence.isolatedProven == 0)
        #expect(trust.activationEvidence.isolatedNotProven == 1)
        // Source application evidence is a distinct question from
        // activation: the diff is real even though the binary never changed.
        #expect(trust.sourceApplication.withEvidence == 1)
    }

    @Test("A build failure with no application evidence at all is counted as noEvidence, not silently dropped")
    func buildFailureHasNoActivationEvidence() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [
            makeResult(point: point, outcome: .unviable, evidence: makeEvidence(applicationEvidence: nil), testSummary: nil)
        ])

        let trust = TrustReport.build(from: report)

        #expect(trust.activationEvidence.noEvidence == 1)
        #expect(trust.activationEvidence.isolatedProven == 0)
    }

    @Test("Schemata-mode application evidence is counted as schemataPresent, not lumped into an isolated bucket")
    func schemataApplicationEvidenceIsCountedAsSchemataPresent() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let schemataEvidence = makeEvidence(applicationEvidence: .schemata(makeConsistentSchemataObservation()))
        let report = makeReport(plan: plan, results: [
            makeResult(point: point, outcome: .killedByAssertion, evidence: schemataEvidence)
        ])

        let trust = TrustReport.build(from: report)

        #expect(trust.activationEvidence.schemataPresent == 1)
        #expect(trust.activationEvidence.isolatedProven == 0)
        #expect(trust.activationEvidence.isolatedNotProven == 0)
        #expect(trust.activationEvidence.noEvidence == 0)
    }

    // MARK: - Crash / timeout confirmation

    @Test("A killedByCrash result with real CrashConfirmation evidence counts as confirmed")
    func confirmedCrashKillIsCounted() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let evidenceWithConfirmation = MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"), sourceAfterHash: ContentHash.of("after"), sourceDiff: "diff",
            buildProductHash: ContentHash.of("mutant-binary"),
            applicationEvidence: .isolated(.buildProductDiffersFromBaseline(
                mutantHash: ContentHash.of("mutant-binary"), baselineHash: ContentHash.of("baseline-binary")
            )),
            crashConfirmation: CrashConfirmation(
                confirmingBuildCommand: nil, confirmingTestCommand: nil, crashedAgain: true, diagnosis: "crashed again, confirmed"
            )
        )
        let report = makeReport(plan: plan, results: [
            makeResult(point: point, outcome: .killedByCrash, evidence: evidenceWithConfirmation)
        ])

        let trust = TrustReport.build(from: report)

        #expect(trust.crashKills.killed == 1)
        #expect(trust.crashKills.confirmed == 1)
        #expect(trust.crashKills.unconfirmed == 0)
    }

    @Test("A killedByCrash result with no CrashConfirmation counts as unconfirmed, not silently confirmed")
    func unconfirmedCrashKillIsCounted() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [
            makeResult(point: point, outcome: .killedByCrash) // default evidence carries no crashConfirmation
        ])

        let trust = TrustReport.build(from: report)

        #expect(trust.crashKills.killed == 1)
        #expect(trust.crashKills.confirmed == 0)
        #expect(trust.crashKills.unconfirmed == 1)
        // Unrelated to timeout confirmation, which must stay at zero here.
        #expect(trust.timeoutKills.killed == 0)
    }

    @Test("A verifiedTimeout result with real TimeoutConfirmation evidence counts as confirmed")
    func confirmedTimeoutKillIsCounted() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let evidenceWithConfirmation = MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"), sourceAfterHash: ContentHash.of("after"), sourceDiff: "diff",
            buildProductHash: ContentHash.of("mutant-binary"),
            applicationEvidence: .isolated(.buildProductDiffersFromBaseline(
                mutantHash: ContentHash.of("mutant-binary"), baselineHash: ContentHash.of("baseline-binary")
            )),
            timeoutConfirmation: TimeoutConfirmation(
                confirmingBuildCommand: nil, confirmingTestCommand: nil, timedOutAgain: true, diagnosis: "timed out again, confirmed"
            )
        )
        let report = makeReport(plan: plan, results: [
            makeResult(point: point, outcome: .verifiedTimeout, evidence: evidenceWithConfirmation)
        ])

        let trust = TrustReport.build(from: report)

        #expect(trust.timeoutKills.killed == 1)
        #expect(trust.timeoutKills.confirmed == 1)
        #expect(trust.timeoutKills.unconfirmed == 0)
    }

    // MARK: - Honest limitation, not a fabricated count

    @Test("The assertion-kill confirmation limitation note is always present, never a fabricated count")
    func assertionKillLimitationNoteIsAlwaysPresent() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion)])

        let trust = TrustReport.build(from: report)

        // Names the outcome this note is actually about...
        #expect(trust.assertionKillConfirmationLimitation.contains("assertion"))
        #expect(trust.assertionKillConfirmationLimitation.contains("not present as a structured"))
        // ...and, unlike `crashKills`/`timeoutKills`, never states an actual
        // confirmed/unconfirmed number for assertion kills — no digit should
        // ever appear in this note. A regression back to broken or
        // fabricated-count prose would trip one of these.
        let containsADigit = trust.assertionKillConfirmationLimitation.contains { $0.isNumber }
        #expect(!containsADigit)
    }

    // MARK: - JSON round-trip

    @Test("TrustReport survives an encode/decode round-trip with the same schemaVersion")
    func roundTripsThroughJSON() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .survived)])
        let trust = TrustReport.build(from: report)

        let data = try MutationPlan.encoder().encode(trust)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == SchemaVersion.trustReport)

        let decoded = try MutationPlan.decoder().decode(TrustReport.self, from: data)
        #expect(decoded == trust)
    }
}
