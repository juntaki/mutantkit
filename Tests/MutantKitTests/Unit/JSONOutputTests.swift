@testable import CLI
import Foundation
import MutationModel
import Testing

/// `JSONErrorEnvelope`/`JSONOutput.emitError` — the shared `--json`
/// error-path shape introduced so a command that cannot proceed (a report
/// file missing or failing to decode, for instance — see `GateCommandJSONTests`'
/// adversarial cases) still emits exactly one parseable JSON document, per
/// `JSONOutput`'s own doc comment, instead of throwing prose.
@Suite("JSONOutput: error envelope")
struct JSONOutputTests {
    @Test("emitError's JSON is schema-versioned, ok: false, and carries code/message/remedy")
    func errorEnvelopeShape() throws {
        let envelope = JSONErrorEnvelope(
            code: "reportUnreadable",
            message: "Could not read the report at \"missing.json\": file not found.",
            remedy: "Check --report points at a real file."
        )

        let data = try MutationPlan.encoder().encode(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["schemaVersion"] as? Int == SchemaVersion.commandError)
        #expect(json["ok"] as? Bool == false)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "reportUnreadable")
        #expect(error["message"] as? String == "Could not read the report at \"missing.json\": file not found.")
        #expect(error["remedy"] as? String == "Check --report points at a real file.")

        let decoded = try MutationPlan.decoder().decode(JSONErrorEnvelope.self, from: data)
        #expect(decoded.schemaVersion == envelope.schemaVersion)
        #expect(decoded.ok == false)
        #expect(decoded.error.code == "reportUnreadable")
    }

    @Test("emitError's `remedy` is omitted, not emitted as null, when nil")
    func errorEnvelopeOmitsNilRemedy() throws {
        let envelope = JSONErrorEnvelope(code: "reportMalformed", message: "not valid JSON")
        let data = try MutationPlan.encoder().encode(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["remedy"] == nil)
    }
}
