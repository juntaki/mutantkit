import Foundation

/// Finds `libMutantKitSchemataRuntime.a` so a schemata build can link
/// against it — see `SwiftPMLinkerInjector`/`XcodeLinkerInjector`, which
/// turn the located directory into actual build arguments.
///
/// V1 requires an explicit override: `MutantKit` does not yet build or
/// install this library as part of its own distribution, so there is no
/// "well-known install path" to search yet. A caller must set
/// `overrideEnvironmentVariable` to the directory containing the platform's
/// `.a` file:
///
/// - `.macOS` — the directory itself, e.g. this repo's own
///   `.build/<triple>/debug` (or its `.build/debug` convenience symlink),
///   produced as a side effect of `swift build --build-tests` (see
///   `Package.swift`'s own comment on why `MutantKitTests` depends on
///   `MutantKitSchemataRuntimeC`).
/// - `.iOSSimulator` — the same directory's `iphonesimulator/` subdirectory,
///   produced by `scripts/build-schemata-runtime.sh` (which `swift build`
///   does not and cannot produce — see that script's own header comment).
///   There is deliberately no fallback to the flat macOS layout for this
///   platform: silently handing an iOS-Simulator build the macOS archive is
///   the exact bug this per-platform split exists to prevent, not a
///   degraded-but-working path.
///
/// One override, not two: the existing `.macOS` contract is unchanged, and
/// gains a sibling subdirectory rather than a second environment variable.
///
/// Missing, invalid, wrong-platform, or *stale* (see
/// `SchemataRuntimeStalenessGuard`) is a fail-closed configuration error,
/// never a silent "schemata mode just does nothing" or "schemata mode runs
/// against last week's runtime code."
public enum SchemataRuntimeLibraryLocator {
    public static let overrideEnvironmentVariable = "MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE"
    public static let libraryFileName = "libMutantKitSchemataRuntime.a"

    public struct Located: Sendable, Equatable {
        public let libraryDirectory: URL

        public init(libraryDirectory: URL) {
            self.libraryDirectory = libraryDirectory
        }
    }

    public enum LocatorError: Error, Equatable, CustomStringConvertible {
        /// `overrideEnvironmentVariable` was unset or empty.
        case missingOverride
        /// The override pointed at a directory with no `libMutantKitSchemataRuntime.a` in it
        /// (`.macOS`  — unchanged from V1's flat layout).
        case libraryNotFound(directory: String)
        /// The override directory has no archive for `platform`. Distinct from
        /// `.libraryNotFound` so the message can name the script that produces it, and
        /// can call out the source-checkout requirement that script has.
        case platformLibraryNotFound(platform: SchemataRuntimePlatform, searched: String)
        /// A destination `SchemataRuntimePlatform.resolve(destination:)` has no archive for.
        case unsupportedDestination(String)
        /// The archive at `archivePath` is older than one or more `.c`/`.h` files under
        /// `Sources/MutantKitSchemataRuntimeC` — see `SchemataRuntimeStalenessGuard`.
        case staleArchive(platform: SchemataRuntimePlatform, archivePath: String, staleSourcePaths: [String])

        public var description: String {
            switch self {
            case .missingOverride:
                "schemata execution requires \(SchemataRuntimeLibraryLocator.overrideEnvironmentVariable) " +
                    "to point at the directory containing \(SchemataRuntimeLibraryLocator.libraryFileName); " +
                    "it is not set"
            case let .libraryNotFound(directory):
                "\(SchemataRuntimeLibraryLocator.libraryFileName) was not found in \(directory)"
            case let .platformLibraryNotFound(platform, searched):
                "\(SchemataRuntimeLibraryLocator.libraryFileName) for \(platform.rawValue) was not found at " +
                    "\(searched). `swift build` only produces the macOS slice; run " +
                    "`scripts/build-schemata-runtime.sh` from a MutantKit source checkout to produce the " +
                    "\(platform.rawValue) one. iOS-Simulator schemata mode currently requires a source " +
                    "checkout (that script compiles Sources/MutantKitSchemataRuntimeC directly) and cannot " +
                    "be set up starting from a released `mutantkit` binary alone, which does not include " +
                    "that source."
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
            }
        }
    }

    /// - Parameters:
    ///   - platform: which archive to resolve. No default value on purpose — a default of
    ///     `.macOS` would let a future call site silently reintroduce the bug this type
    ///     exists to prevent (an iOS-Simulator build linking a macOS archive), so every call
    ///     site must say explicitly which platform it means.
    ///   - sourceDirectory: where to look for `Sources/MutantKitSchemataRuntimeC` when
    ///     checking staleness — defaults to this checkout's own source tree (`nil` when
    ///     running a binary with no checkout available, which skips the check entirely; see
    ///     `SchemataRuntimeSourceLocation`). Overridable so tests can point it at a
    ///     controlled fixture instead of depending on this repo's own real file timestamps.
    public static func locate(
        for platform: SchemataRuntimePlatform,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourceDirectory: URL? = SchemataRuntimeSourceLocation.checkoutSourceDirectory
    ) throws -> Located {
        guard let raw = environment[overrideEnvironmentVariable], !raw.isEmpty else {
            throw LocatorError.missingOverride
        }
        let overrideDirectory = URL(fileURLWithPath: raw)
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

        return Located(libraryDirectory: directory)
    }
}
