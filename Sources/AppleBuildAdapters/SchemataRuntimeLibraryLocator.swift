import Foundation

/// Finds `libMutantKitSchemataRuntime.a` so a schemata build can link
/// against it — see `SwiftPMLinkerInjector`, which turns the located
/// directory into actual `swift build`/`swift test` arguments.
///
/// V1 requires an explicit override: `MutantKit` does not yet build or
/// install this library as part of its own distribution, so there is no
/// "well-known install path" to search yet. A caller must set
/// `overrideEnvironmentVariable` to the directory containing the `.a` file
/// — for a source checkout, that is this repo's own
/// `.build/<triple>/debug` (or its `.build/debug` convenience symlink),
/// produced as a side effect of `swift build --build-tests` (see
/// `Package.swift`'s own comment on why `MutantKitTests` depends on
/// `MutantKitSchemataRuntimeC`). Missing or invalid is a fail-closed
/// configuration error, never a silent "schemata mode just does nothing."
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
        /// The override pointed at a directory with no `libMutantKitSchemataRuntime.a` in it.
        case libraryNotFound(directory: String)

        public var description: String {
            switch self {
            case .missingOverride:
                "schemata execution requires \(SchemataRuntimeLibraryLocator.overrideEnvironmentVariable) " +
                    "to point at the directory containing \(SchemataRuntimeLibraryLocator.libraryFileName); " +
                    "it is not set"
            case let .libraryNotFound(directory):
                "\(SchemataRuntimeLibraryLocator.libraryFileName) was not found in \(directory)"
            }
        }
    }

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Located {
        guard let raw = environment[overrideEnvironmentVariable], !raw.isEmpty else {
            throw LocatorError.missingOverride
        }
        let directory = URL(fileURLWithPath: raw)
        let libraryPath = directory.appendingPathComponent(libraryFileName)
        guard FileManager.default.isReadableFile(atPath: libraryPath.path) else {
            throw LocatorError.libraryNotFound(directory: directory.path)
        }
        return Located(libraryDirectory: directory)
    }
}
