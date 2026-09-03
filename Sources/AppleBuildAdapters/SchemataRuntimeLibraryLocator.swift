import Foundation
import MutationModel

/// Finds `libMutantKitSchemataRuntime.a` so a schemata build can link
/// against it — see `SwiftPMLinkerInjector`/`XcodeLinkerInjector`, which
/// turn `Located.archivePath` — the exact file this type resolved and
/// validated, not merely a directory plus a `-l<name>` naming convention
/// (see those two types' own doc comments for why that distinction is
/// load-bearing on the bundled path) — into actual build arguments.
///
/// Two resolution paths, tried in order:
///
/// 1. **Developer override** (`overrideEnvironmentVariable` set): points at
///    the directory containing the platform's `.a` file directly — this
///    repo's own `.build/<triple>/debug` for `.macOS`, or the output of
///    `scripts/build-schemata-runtime.sh` for `.iOSSimulator`. Unchanged
///    from V1: still subject to `SchemataRuntimeStalenessGuard`'s mtime
///    check against a source checkout, since a developer's own build
///    directory can go stale in a way a release artifact never can.
/// 2. **Bundled runtime** (no override set): a released `mutantkit`
///    bundles `lib/mutantkit/schemata/manifest.json` plus its per-platform
///    archives alongside the executable itself (`scripts/release-build.sh`
///    produces this layout — see
///    `SchemataRuntimeManifest`'s own doc comment for the exact shape).
///    Resolved relative to `MutantKitInstallLocation.executableURL()`,
///    validated against the manifest's declared SHA-256 digest and
///    runtime-ABI version, and confined to `lib/mutantkit/schemata/`
///    itself (`confinedArchiveURL` rejects an absolute or `..`-escaping
///    manifest-declared path before it is ever read) — never trusted on
///    directory-layout convention alone, and never subject to the
///    override path's mtime staleness guard (a release artifact's
///    freshness is proven by digest identity, not by comparing timestamps
///    against source files that a release binary — built on a different
///    machine, possibly copied to a third — has no reliable access to).
///
/// Missing, invalid, wrong-platform, or stale is a fail-closed
/// configuration error on both paths, never a silent "schemata mode just
/// does nothing" or "schemata mode runs against the wrong runtime."
public enum SchemataRuntimeLibraryLocator {
    public static let overrideEnvironmentVariable = "MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE"
    public static let libraryFileName = "libMutantKitSchemataRuntime.a"

    /// Mirrors `MUTANTKIT_V3_RUNTIME_ABI_VERSION` from
    /// `mutantkit_protocol_v3.h` exactly — see `SchemataRuntimeManifest
    /// .runtimeABIVersion`'s own doc comment for why this is a distinct
    /// number from the lowerer's or the wire protocol's own "version."
    static let expectedRuntimeABIVersion: UInt32 = 1

    /// Where a bundled runtime lives relative to the executable's own
    /// install directory — `<install-root>/lib/mutantkit/schemata/`. A
    /// bare relative path, joined onto `MutantKitInstallLocation
    /// .executableURL()`'s parent directory; never an absolute path or a
    /// search starting from the current working directory.
    static let bundledRelativeRoot = "lib/mutantkit/schemata"
    static let manifestFileName = "manifest.json"

    public enum Provenance: Sendable, Equatable {
        /// Resolved from `lib/mutantkit/schemata/` next to the running
        /// executable, validated against `manifest.json`.
        case bundled
        /// Resolved from `overrideEnvironmentVariable`, unvalidated beyond
        /// "the file exists" plus the mtime staleness guard.
        case override
    }

    public struct Located: Sendable, Equatable {
        public let libraryDirectory: URL
        /// The archive file itself (`libraryDirectory` +
        /// `libraryFileName`) — recorded directly rather than left for a
        /// caller to reconstruct, since a bundled resolution's own archive
        /// path is exactly what it already validated the digest of.
        public let archivePath: URL
        public let provenance: Provenance

        public init(libraryDirectory: URL, archivePath: URL, provenance: Provenance) {
            self.libraryDirectory = libraryDirectory
            self.archivePath = archivePath
            self.provenance = provenance
        }
    }

    public enum LocatorError: Error, Equatable, CustomStringConvertible {
        /// The override directory has no `libMutantKitSchemataRuntime.a` in it
        /// (`.macOS` — unchanged from V1's flat layout).
        case libraryNotFound(directory: String)
        /// The override directory has no archive for `platform`. Distinct from
        /// `.libraryNotFound` so the message can name the script that produces it, and
        /// can call out the source-checkout requirement that script has.
        case platformLibraryNotFound(platform: SchemataRuntimePlatform, searched: String)
        /// A destination `SchemataRuntimePlatform.resolve(destination:)` has no archive for.
        case unsupportedDestination(String)
        /// The override archive at `archivePath` is older than one or more `.c`/`.h` files
        /// under `Sources/MutantKitSchemataRuntimeC` — see `SchemataRuntimeStalenessGuard`.
        /// Bundled resolutions never throw this — see `Located.provenance`'s own doc comment.
        case staleArchive(platform: SchemataRuntimePlatform, archivePath: String, staleSourcePaths: [String])
        /// Neither an override was set nor could a bundled runtime be found at all —
        /// `reason` names exactly what was missing (no executable location, no manifest
        /// file present, or the file existed but was not readable).
        case bundledRuntimeUnavailable(reason: String)
        /// `manifest.json` was found but could not be trusted: malformed JSON, a
        /// structurally-wrong shape, or a `schemaVersion` this build does not understand.
        case bundledManifestInvalid(path: String, reason: String)
        /// The manifest parsed and validated, but declares no archive for `platform` at
        /// all — e.g. a release that does not (yet) bundle an iOS-Simulator runtime.
        case bundledArchiveMissingForPlatform(platform: SchemataRuntimePlatform, manifestPath: String)
        /// The manifest names an archive at `path`, but no file exists there — a
        /// corrupted or partially-extracted install.
        case bundledArchiveFileMissing(platform: SchemataRuntimePlatform, path: String)
        /// The archive file exists but its SHA-256 does not match the manifest's
        /// declared digest — corrupted or tampered, never linked.
        case bundledArchiveDigestMismatch(platform: SchemataRuntimePlatform, path: String, expectedSHA256: String, actualSHA256: String)
        /// The manifest's declared `runtimeABIVersion` does not match this exact
        /// `mutantkit` build's own expectation (`expectedRuntimeABIVersion`) — a
        /// mismatched pairing between the binary and the runtime archives bundled
        /// alongside it, which should never happen from a release tarball produced as
        /// one unit, but is checked rather than assumed.
        case bundledRuntimeABIMismatch(platform: SchemataRuntimePlatform, manifestVersion: UInt32, expectedVersion: UInt32)
        /// The manifest names an archive `path` for `platform` that is not a safe,
        /// confined relative path under `lib/mutantkit/schemata/` — absolute,
        /// containing a `.`/`..` component, or one that resolves outside that root.
        /// Rejected before any file access or digest check: `SchemataRuntimeManifest
        /// .Archive.path`'s own doc comment declares it relative to the manifest's own
        /// directory, and this is what actually enforces that, rather than trusting
        /// the manifest's author (or a corrupted/tampered install) to have honored it.
        case bundledArchivePathUnsafe(platform: SchemataRuntimePlatform, path: String)

        public var description: String {
            switch self {
            case let .libraryNotFound(directory):
                "\(SchemataRuntimeLibraryLocator.libraryFileName) was not found in \(directory)"
            case let .platformLibraryNotFound(platform, searched):
                "\(SchemataRuntimeLibraryLocator.libraryFileName) for \(platform.rawValue) was not found at " +
                    "\(searched). `swift build` only produces the macOS slice; run " +
                    "`scripts/build-schemata-runtime.sh` from a MutantKit source checkout to produce the " +
                    "\(platform.rawValue) one."
            case let .unsupportedDestination(destination):
                "schemata execution has no MutantKitSchemataRuntime build for destination \"\(destination)\". " +
                    "Supported destinations are macOS and iOS Simulator."
            case let .staleArchive(platform, archivePath, staleSourcePaths):
                "\(archivePath) (the \(platform.rawValue) MutantKitSchemataRuntime archive) is older than " +
                    "\(staleSourcePaths.count == 1 ? "a source file" : "\(staleSourcePaths.count) source files") " +
                    "that changed since it was built: \(staleSourcePaths.joined(separator: ", ")). Re-run " +
                    (platform == .iOSSimulator
                        ? "`scripts/build-schemata-runtime.sh` (iOS Simulator) or `swift build --build-tests` (macOS)"
                        : "`swift build --build-tests`") +
                    " before running schemata mode again — refusing rather than silently linking outdated " +
                    "runtime behavior."
            case let .bundledRuntimeUnavailable(reason):
                "schemata execution found no usable runtime: \(reason). Either run a genuine `mutantkit` " +
                    "release install (which bundles its own schemata runtime), or set " +
                    "\(SchemataRuntimeLibraryLocator.overrideEnvironmentVariable) to point at a directory " +
                    "containing \(SchemataRuntimeLibraryLocator.libraryFileName) for local development."
            case let .bundledManifestInvalid(path, reason):
                "the bundled schemata runtime manifest at \(path) could not be trusted: \(reason)"
            case let .bundledArchiveMissingForPlatform(platform, manifestPath):
                "the bundled schemata runtime manifest at \(manifestPath) declares no archive for " +
                    "\(platform.rawValue); this mutantkit release does not support schemata mode for that platform"
            case let .bundledArchiveFileMissing(platform, path):
                "the bundled schemata runtime manifest names a \(platform.rawValue) archive at \(path), but no " +
                    "file exists there — the install is corrupted or incomplete"
            case let .bundledArchiveDigestMismatch(platform, path, expectedSHA256, actualSHA256):
                "the bundled \(platform.rawValue) schemata runtime archive at \(path) does not match the " +
                    "manifest's declared digest (expected \(expectedSHA256), got \(actualSHA256)) — corrupted " +
                    "or tampered, refusing to link it"
            case let .bundledRuntimeABIMismatch(platform, manifestVersion, expectedVersion):
                "the bundled \(platform.rawValue) schemata runtime manifest declares runtimeABIVersion " +
                    "\(manifestVersion), but this mutantkit build expects \(expectedVersion) — the binary and " +
                    "the bundled runtime were not built together; refusing to link a mismatched pair"
            case let .bundledArchivePathUnsafe(platform, path):
                "the bundled schemata runtime manifest names an unsafe archive path for \(platform.rawValue): " +
                    "\"\(path)\" (absolute, contains a \".\"/\"..\" path component, or resolves outside " +
                    "lib/mutantkit/schemata/) — refusing to trust it"
            }
        }
    }

    /// - Parameters:
    ///   - platform: which archive to resolve. No default value on purpose — a default of
    ///     `.macOS` would let a future call site silently reintroduce the bug this type
    ///     exists to prevent (an iOS-Simulator build linking a macOS archive), so every call
    ///     site must say explicitly which platform it means.
    ///   - sourceDirectory: where to look for `Sources/MutantKitSchemataRuntimeC` when
    ///     checking the override path's staleness — defaults to this checkout's own source
    ///     tree (`nil` when running a binary with no checkout available, which skips the
    ///     check entirely; see `SchemataRuntimeSourceLocation`). Overridable so tests can
    ///     point it at a controlled fixture instead of depending on this repo's own real
    ///     file timestamps. Never consulted on the bundled path.
    ///   - executableURL: where the running `mutantkit` executable lives, for resolving a
    ///     bundled runtime — defaults to `MutantKitInstallLocation.executableURL()`.
    ///     Overridable so tests can point a bundled-runtime lookup at a controlled fixture
    ///     directory instead of this test binary's own real location. Never consulted when
    ///     an override is set.
    public static func locate(
        for platform: SchemataRuntimePlatform,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourceDirectory: URL? = SchemataRuntimeSourceLocation.checkoutSourceDirectory,
        executableURL: URL? = MutantKitInstallLocation.executableURL()
    ) throws -> Located {
        if let raw = environment[overrideEnvironmentVariable], !raw.isEmpty {
            return try locateOverride(for: platform, overrideDirectory: URL(fileURLWithPath: raw), sourceDirectory: sourceDirectory)
        }
        return try locateBundled(for: platform, executableURL: executableURL)
    }

    private static func locateOverride(
        for platform: SchemataRuntimePlatform, overrideDirectory: URL, sourceDirectory: URL?
    ) throws -> Located {
        let directory = platform == .macOS ? overrideDirectory : overrideDirectory.appendingPathComponent(platform.rawValue)
        let libraryPath = directory.appendingPathComponent(libraryFileName)
        guard FileManager.default.isReadableFile(atPath: libraryPath.path) else {
            if platform == .macOS {
                throw LocatorError.libraryNotFound(directory: directory.path)
            }
            throw LocatorError.platformLibraryNotFound(platform: platform, searched: directory.path)
        }

        let stale = SchemataRuntimeStalenessGuard.staleSources(archivePath: libraryPath, sourceDirectory: sourceDirectory)
        guard stale.isEmpty else {
            throw LocatorError.staleArchive(platform: platform, archivePath: libraryPath.path, staleSourcePaths: stale.map(\.path))
        }

        return Located(libraryDirectory: directory, archivePath: libraryPath, provenance: .override)
    }

    private static func locateBundled(for platform: SchemataRuntimePlatform, executableURL: URL?) throws -> Located {
        guard let executableURL else {
            throw LocatorError.bundledRuntimeUnavailable(reason: "could not determine the running mutantkit executable's own location")
        }
        let schemataRoot = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent(bundledRelativeRoot, isDirectory: true)
        let manifestPath = schemataRoot.appendingPathComponent(manifestFileName)
        guard FileManager.default.isReadableFile(atPath: manifestPath.path) else {
            throw LocatorError.bundledRuntimeUnavailable(reason: "no bundled schemata runtime manifest at \(manifestPath.path)")
        }

        let manifest: SchemataRuntimeManifest
        do {
            manifest = try JSONDecoder().decode(SchemataRuntimeManifest.self, from: try Data(contentsOf: manifestPath))
        } catch {
            throw LocatorError.bundledManifestInvalid(path: manifestPath.path, reason: "\(error)")
        }
        guard manifest.schemaVersion == SchemataRuntimeManifest.supportedSchemaVersion else {
            throw LocatorError.bundledManifestInvalid(
                path: manifestPath.path,
                reason: "manifest schemaVersion \(manifest.schemaVersion) is not supported by this mutantkit build " +
                    "(expects \(SchemataRuntimeManifest.supportedSchemaVersion))"
            )
        }
        guard let archive = manifest.archives.first(where: { $0.platform == platform.rawValue }) else {
            throw LocatorError.bundledArchiveMissingForPlatform(platform: platform, manifestPath: manifestPath.path)
        }
        guard manifest.runtimeABIVersion == expectedRuntimeABIVersion else {
            throw LocatorError.bundledRuntimeABIMismatch(
                platform: platform, manifestVersion: manifest.runtimeABIVersion, expectedVersion: expectedRuntimeABIVersion
            )
        }
        guard let archivePath = confinedArchiveURL(relativePath: archive.path, root: schemataRoot) else {
            throw LocatorError.bundledArchivePathUnsafe(platform: platform, path: archive.path)
        }
        guard FileManager.default.isReadableFile(atPath: archivePath.path) else {
            throw LocatorError.bundledArchiveFileMissing(platform: platform, path: archivePath.path)
        }
        let actualDigest = try SHA256Digest.ofFile(at: archivePath).rawValue
        guard actualDigest == archive.sha256.lowercased() else {
            throw LocatorError.bundledArchiveDigestMismatch(
                platform: platform, path: archivePath.path, expectedSHA256: archive.sha256, actualSHA256: actualDigest
            )
        }

        return Located(libraryDirectory: archivePath.deletingLastPathComponent(), archivePath: archivePath, provenance: .bundled)
    }

    /// Resolves a manifest-declared `relativePath` under `root`, refusing anything
    /// that is not genuinely confined to it — see `LocatorError.bundledArchivePathUnsafe`'s
    /// own doc comment for why this is checked rather than assumed.
    ///
    /// Three layers, deliberately not just one:
    /// 1. A syntactic reject of any empty, `.`, or `..` path component catches the
    ///    ordinary case before touching the filesystem at all.
    /// 2. A component-wise prefix check of the plain joined path against `root`'s
    ///    own standardized components (defense against a naive string-prefix
    ///    check's own false-negative: a sibling directory like `root-evil` would
    ///    satisfy `path.hasPrefix(root.path)` while never actually being confined
    ///    to `root`).
    /// 3. The identical prefix check again, this time against both sides fully
    ///    symlink-resolved — review finding: layers 1/2 alone are lexical only, so
    ///    a manifest naming a path through a symlinked intermediate directory
    ///    (`escape -> /tmp/outside`) or a symlinked archive file itself, whose
    ///    real target sits outside `root`, would pass them while resolving
    ///    somewhere else entirely at open() time. Resolved with
    ///    `resolvingSymlinksInPath()` on the *full* candidate when it already
    ///    exists (the only way that call resolves the leaf's own symlink, not
    ///    just an intermediate one — confirmed empirically in
    ///    `AdapterSupport.swift`'s own `resolveWriteURL`); when it does not exist
    ///    yet, only the parent is resolved (a leaf that cannot yet be reached
    ///    still fails the caller's own readability check right after this
    ///    returns, so under-resolving a not-yet-real leaf costs nothing).
    ///
    /// Returns the original (layer 1/2) candidate, not the resolved one — this is
    /// a confinement *check*, not a canonicalization; every real file operation
    /// downstream (`isReadableFile`, `SHA256Digest.ofFile(at:)`, and the archive
    /// path handed to the linker) already follows symlinks transparently at
    /// open() time, so returning the resolved form would only change this type's
    /// own reported path string for no safety benefit.
    private static func confinedArchiveURL(relativePath: String, root: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let rawComponents = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard rawComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }

        let standardizedRoot = root.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard isConfined(candidate, to: standardizedRoot) else { return nil }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate: URL
        if FileManager.default.fileExists(atPath: candidate.path) {
            resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        } else {
            let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            resolvedCandidate = resolvedParent.appendingPathComponent(candidate.lastPathComponent).standardizedFileURL
        }
        guard isConfined(resolvedCandidate, to: resolvedRoot) else { return nil }

        return candidate
    }

    private static func isConfined(_ candidate: URL, to root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count > rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
