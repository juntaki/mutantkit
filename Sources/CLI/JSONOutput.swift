import Foundation
import MutationModel

/// The one canonical way every `--json`-supporting command turns a value
/// into stdout: `MutationPlan.encoder()`'s pretty-printed, sorted-key,
/// ISO-8601 JSON — the same encoding this tool already uses for every
/// artifact it writes to disk, not a second, ad hoc "JSON for stdout"
/// convention. Every command using this prints exactly one JSON document
/// per invocation, including on error paths: an agent parsing `--json`
/// output must never be handed prose on a path it did not anticipate (see
/// `InspectCommand`'s own `--json` doc comment, which first stated this
/// discipline for `mutantkit inspect`).
enum JSONOutput {
    /// The canonical encoding, as a `String` — for commands (like
    /// `OperatorCatalogCommand`) that build their own render-vs-JSON
    /// branch around a `String`-returning helper rather than printing
    /// directly.
    static func string(for value: some Encodable) throws -> String {
        String(decoding: try MutationPlan.encoder().encode(value), as: UTF8.self)
    }

    /// Prints exactly one JSON document, followed by a trailing newline so
    /// `--json` output composes cleanly with ordinary shell tooling (`| jq`,
    /// redirected to a file, etc.).
    static func emit(_ value: some Encodable) throws {
        print(try string(for: value))
    }

    /// Emits a `JSONErrorEnvelope` — the `--json` counterpart to this file's
    /// own doc comment: a command that cannot proceed (a report file
    /// missing or failing to decode, say) must still emit exactly one JSON
    /// document, not throw an uncaught Swift error that surfaces to stdout
    /// or stderr as prose an agent's JSON parser was not expecting.
    static func emitError(code: String, message: String, remedy: String? = nil) throws {
        try emit(JSONErrorEnvelope(code: code, message: message, remedy: remedy))
    }
}

/// A structured `--json` failure document, shared by every `--json`-
/// supporting command's error path — the one shape this codebase did not
/// yet have (`InspectCommand.ErrorJSON`'s bare `{error: String}` is the only
/// precedent, and predates the `schemaVersion` convention every success
/// shape here already follows: `QualityGateResult`, `BuildDiagnosis`,
/// `AgentEvidenceReport`, etc.). `ok: false` is redundant with a nonzero
/// exit code but is included anyway so an agent parsing only stdout (a
/// captured subprocess's stdout without checking the exit code, say) can
/// still tell success from failure from the document alone.
struct JSONErrorEnvelope: Codable {
    struct Detail: Codable {
        let code: String
        let message: String
        let remedy: String?
    }

    let schemaVersion: Int
    let ok: Bool
    let error: Detail

    init(code: String, message: String, remedy: String? = nil) {
        schemaVersion = SchemaVersion.commandError
        ok = false
        error = Detail(code: code, message: message, remedy: remedy)
    }
}
