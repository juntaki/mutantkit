import Foundation
import MutationModel
import Reporting
import Testing

/// `MutationEvidence.assertionKillConfirmation`: additive Codable, nil is
/// never read as confirmed, and `TrustReport` only counts what is recorded.
@Suite("AssertionKillConfirmation")
struct AssertionKillConfirmationTests {
    private func evidence(_ confirmation: AssertionKillConfirmation?) -> MutationEvidence {
        MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"), sourceAfterHash: ContentHash.of("after"), sourceDiff: "diff",
            buildProductHash: ContentHash.of("mutant-binary"),
            applicationEvidence: .isolated(.buildProductDiffersFromBaseline(
                mutantHash: ContentHash.of("mutant-binary"), baselineHash: ContentHash.of("baseline-binary")
            )),
            assertionKillConfirmation: confirmation
        )
    }

    private let confirmed = AssertionKillConfirmation(
        disposition: .confirmed, primaryFailingTests: ["A/testA()"], confirmingFailingTests: ["A/testA()"], confirmingStatus: "failed"
    )

    // MARK: - Codable

    @Test("Codable round trip preserves every field")
    func roundTrip() throws {
        let original = evidence(AssertionKillConfirmation(
            disposition: .failingSetDiffers, primaryFailingTests: ["A"], confirmingFailingTests: nil, confirmingStatus: "failed"
        ))
        let data = try MutationPlan.encoder().encode(original)
        let decoded = try MutationPlan.decoder().decode(MutationEvidence.self, from: data)
        #expect(decoded == original)
        #expect(decoded.assertionKillConfirmation?.disposition == .failingSetDiffers)
        #expect(decoded.assertionKillConfirmation?.method == .retestOfBuiltMutant)
        #expect(decoded.assertionKillConfirmation?.confirmingFailingTests == nil)
    }

    @Test("Evidence JSON written before the field existed decodes with nil, never confirmed")
    func legacyJSONDecodesNil() throws {
        let data = try MutationPlan.encoder().encode(evidence(nil))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["assertionKillConfirmation"] == nil)
        object.removeValue(forKey: "assertionKillConfirmation")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try MutationPlan.decoder().decode(MutationEvidence.self, from: legacy)
        #expect(decoded.assertionKillConfirmation == nil)
        #expect(decoded.assertionKillConfirmation?.disposition != .confirmed)
    }

    @Test("A nil confirmation is omitted from encoded evidence")
    func nilIsOmitted() throws {
        let data = try MutationPlan.encoder().encode(evidence(nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.keys.contains("assertionKillConfirmation") == false)
    }

    // MARK: - TrustReport

    @Test("Trust counts confirmed vs unconfirmed assertion kills; nil counts as unconfirmed")
    func trustCounts() throws {
        let p1 = try makeAnchoredPoint(file: "Sources/A.swift")
        let p2 = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [p1, p2])
        let report = makeReport(plan: plan, results: [
            makeResult(point: p1, outcome: .killedByAssertion, evidence: evidence(confirmed)),
            makeResult(point: p2, outcome: .killedByAssertion, evidence: evidence(nil))
        ])

        let trust = TrustReport.build(from: report)

        let section = try #require(trust.assertionKills)
        #expect(section.killed == 2)
        #expect(section.confirmed == 1)
        #expect(section.unconfirmed == 1)
        #expect(trust.assertionKillConfirmationLimitation.contains("1 of 2"))
    }

    @Test("A non-confirmed disposition on a kill is counted unconfirmed")
    func nonConfirmedDispositionIsUnconfirmed() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let notConfirmed = AssertionKillConfirmation(disposition: .retestNotFailed, confirmingStatus: "passed")
        let report = makeReport(plan: plan, results: [
            makeResult(point: point, outcome: .killedByAssertion, evidence: evidence(notConfirmed))
        ])

        let section = try #require(TrustReport.build(from: report).assertionKills)
        #expect(section.confirmed == 0)
        #expect(section.unconfirmed == 1)
    }

    @Test("No recorded confirmation anywhere keeps the legacy behavior: no section, original limitation text")
    func absentKeepsLegacyBehavior() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion)])

        let trust = TrustReport.build(from: report)

        #expect(trust.assertionKills == nil)
        #expect(trust.assertionKillConfirmationLimitation.contains("not present as a structured"))
    }

    @Test("Trust JSON keeps the limitation key and adds assertionKills only when present")
    func trustJSONIsAdditive() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [
            makeResult(point: point, outcome: .killedByAssertion, evidence: evidence(confirmed))
        ])
        let trust = TrustReport.build(from: report)

        let data = try MutationPlan.encoder().encode(trust)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["assertionKillConfirmationLimitation"] is String)
        #expect(json["assertionKills"] != nil)
        #expect(try MutationPlan.decoder().decode(TrustReport.self, from: data) == trust)

        // An older trust JSON without the key still decodes, with nil.
        var legacy = json
        legacy.removeValue(forKey: "assertionKills")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try MutationPlan.decoder().decode(TrustReport.self, from: legacyData).assertionKills == nil)
    }
}
