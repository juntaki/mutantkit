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

/// `JSONOutput.compactLine(for:)` — the NDJSON building block `--format
/// agent` (`FixPlanCommand`/`NextCommand`) uses instead of an unquoted
/// `key=value` line format: a field lifted verbatim from real Swift source
/// (a mutant's `original`/`replacement` text) can itself contain a space, an
/// `=`, or an embedded newline (a multi-line ternary/return-value swap), any
/// of which would have made a hand-rolled delimited line ambiguous, or
/// actually split across lines, to a consumer parsing by splitting on
/// whitespace or newlines.
@Suite("JSONOutput: compactLine (NDJSON)")
struct JSONOutputCompactLineTests {
    private struct Row: Codable, Equatable {
        let id: String
        let text: String
    }

    @Test("compactLine never contains a raw newline, even when a field's own value has one")
    func neverContainsRawNewline() throws {
        let row = Row(id: "mut_1", text: "line one\nline two\nline three")
        let line = try JSONOutput.compactLine(for: row)

        #expect(!line.contains("\n"), "a value's embedded newline must come back JSON-escaped, never as a raw line break")
        #expect(line.contains("\\n"), "the newline must still be represented, just escaped inside the JSON string")
    }

    @Test("compactLine round-trips a field containing spaces, an `=`, and quotes exactly")
    func roundTripsAmbiguousCharacters() throws {
        let row = Row(id: "mut_2", text: "path with spaces/File.swift: x >= 10, note=\"quoted\"")
        let line = try JSONOutput.compactLine(for: row)
        let decoded = try MutationPlan.decoder().decode(Row.self, from: Data(line.utf8))
        #expect(decoded == row)
    }

    @Test("A stream of compactLine results is genuinely NDJSON: split on \\n, each line parses independently")
    func streamsAsNDJSON() throws {
        let rows = [
            Row(id: "mut_a", text: "flag ? 1 : 2"),
            Row(id: "mut_b", text: "multi\nline\nvalue"),
            Row(id: "mut_c", text: "has spaces and an = sign")
        ]
        let stream = try rows.map { try JSONOutput.compactLine(for: $0) }.joined(separator: "\n")

        let lines = stream.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == rows.count, "one physical line per object -- no embedded value split or merged an entry")

        let decoded = try lines.map { try MutationPlan.decoder().decode(Row.self, from: Data($0.utf8)) }
        #expect(decoded == rows)
    }
}
