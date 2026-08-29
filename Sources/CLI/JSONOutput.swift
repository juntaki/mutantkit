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
}
