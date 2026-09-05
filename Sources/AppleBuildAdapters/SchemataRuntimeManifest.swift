/// The shape of `lib/mutantkit/schemata/manifest.json` — the file a
/// released `mutantkit` tarball bundles alongside its per-platform
/// `MutantKitSchemataRuntime` archives (`scripts/release-build.sh` produces
/// this; this type only reads and validates it). Every field `SchemataRuntimeLibraryLocator`
/// checks before it will link a bundled archive into anyone's build: this
/// is the only thing a bundled-runtime lookup trusts about directory
/// layout — never a convention-only path guess with no verification behind
/// it.
struct SchemataRuntimeManifest: Codable, Equatable {
    /// This struct's own format version — bumped only if a future change
    /// needs a field this decoder cannot read compatibly (a removed
    /// required field, a changed meaning for an existing one). Adding an
    /// optional field does not require a bump; `JSONDecoder` already
    /// tolerates that without one.
    static let supportedSchemaVersion = 1

    struct Archive: Codable, Equatable {
        /// `SchemataRuntimePlatform.rawValue` — `"macosx"`/`"iphonesimulator"`.
        /// A raw `String`, not `SchemataRuntimePlatform` itself: a manifest
        /// produced by a newer `mutantkit` release could name a platform
        /// this older decoder's `SchemataRuntimePlatform` enum does not yet
        /// know, and that must decode as "an archive for a platform we
        /// don't recognize" (silently skipped when resolving, never a
        /// decode failure that takes the *whole* manifest down with it).
        let platform: String
        /// Relative to `manifest.json`'s own directory — never an absolute
        /// path, so the whole `lib/mutantkit/schemata/` tree stays
        /// relocatable as a unit (e.g. a CI job that unpacks the release
        /// tarball somewhere other than where it was built).
        let path: String
        /// Lowercase hex SHA-256 of the archive file's raw bytes — the
        /// actual trust anchor. Platform/architecture naming is a
        /// convenience for a human reading the manifest; digest identity is
        /// what `SchemataRuntimeLibraryLocator` actually verifies before
        /// linking.
        let sha256: String
        /// Informational only (e.g. `["arm64", "x86_64"]` for a fat
        /// archive) — never independently re-verified against the Mach-O
        /// itself. The sha256 above already proves the file is byte-for-
        /// byte what the release build produced; re-deriving architectures
        /// from `lipo`/lib parsing here would only duplicate that proof
        /// with strictly less certainty.
        let architectures: [String]
    }

    let schemaVersion: Int
    /// Mirrors `MUTANTKIT_V3_RUNTIME_ABI_VERSION` from
    /// `mutantkit_protocol_v3.h` — the compiled runtime library's own ABI
    /// identity, independent of `BoolLiteralSchemataLowerer.runtimeABIVersion`
    /// (a *lowerer*-side embedding-compatibility number) and of
    /// `MUTANTKIT_V3_PROTOCOL_VERSION` (the wire-format version already
    /// mirrored in `SchemataEvidenceCollector.protocolVersion`) — three
    /// genuinely different "version" concepts in this codebase that this
    /// field must not be conflated with.
    let runtimeABIVersion: UInt32
    let archives: [Archive]
}
