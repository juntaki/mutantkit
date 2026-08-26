import Foundation

/// Where to find `Sources/MutantKitSchemataRuntimeC` for the staleness check
/// below — derived from this very file's own on-disk location, the same
/// technique `AcceptanceSupport.packageRoot` uses so tests do not depend on
/// the working directory `swift test`/`mutantkit` happens to be invoked
/// from.
///
/// Valid only when running a `mutantkit` built from this checkout: `#filePath`
/// bakes in an absolute path from the machine that *compiled* this file, so
/// a released binary built on one machine and copied to another (or a
/// binary built from a checkout that was later deleted) resolves to a path
/// that no longer exists. `checkoutSourceDirectory` is `nil` in that case —
/// deliberately, not an error: `scripts/release-build.sh` ships only the
/// `mutantkit` binary and `LICENSE`, never `Sources/MutantKitSchemataRuntimeC`
/// (see its own header comment), so iOS-Simulator schemata mode already
/// requires a source checkout for an unrelated reason
/// (`scripts/build-schemata-runtime.sh` needs the C source to compile it) —
/// this is not a new limitation, just a fact `SchemataRuntimeStalenessGuard`
/// also has to know about to avoid failing on a question it cannot answer.
public enum SchemataRuntimeSourceLocation {
    /// `nil` when no MutantKit source checkout can be found from this binary's own build
    /// location — see this type's own doc comment for why that is an expected, non-error
    /// case rather than something callers need to guard against explicitly.
    public static var checkoutSourceDirectory: URL? {
        let candidate = URL(fileURLWithPath: #filePath) // .../Sources/AppleBuildAdapters/SchemataRuntimeStalenessGuard.swift
            .deletingLastPathComponent() // AppleBuildAdapters
            .deletingLastPathComponent() // Sources
            .appendingPathComponent("MutantKitSchemataRuntimeC", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return candidate
    }
}

/// Fail-closed protection against linking a `MutantKitSchemataRuntime`
/// archive that predates a source change nobody rebuilt against.
///
/// Neither the macOS nor the iOS-Simulator archive carries a build ID
/// checked by anything else. The macOS slice's freshness is *usually*
/// guaranteed for free by SwiftPM's own incremental build graph
/// (`MutantKitTests` depends directly on the `MutantKitSchemataRuntimeC`
/// target — see `Package.swift`'s own comment on why), but a developer
/// pointing `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` at an old build
/// directory sidesteps that entirely, and the iOS-Simulator slice is
/// produced by the wholly separate `scripts/build-schemata-runtime.sh`,
/// which SwiftPM's build graph does not know exists at all — nothing
/// re-invokes it automatically when the C source changes. A developer who
/// edits `mutantkit_protocol_v3.c`, forgets to re-run the relevant build
/// step, and then runs an iOS-Simulator (or macOS) schemata smoke test would
/// otherwise silently link the *old* object code: the runtime's behavior,
/// not only its ABI layout, changing without anyone re-running anything.
///
/// The check: does any `.c`/`.h` file under `Sources/MutantKitSchemataRuntimeC`
/// have a modification time newer than the archive itself? If so, refuse —
/// the same staleness test `make` has used for decades, applied here to
/// *both* platforms uniformly, at the one production choke point
/// (`SchemataRuntimeLibraryLocator.locate(for:)`) every schemata build
/// already goes through, rather than as a sidecar file "only CI reads" (an
/// earlier draft of this mechanism did exactly that, and it protected
/// nothing about a local developer's own edit/rebuild loop — the residual
/// gap an adversarial review of that draft called out by name). A false
/// positive (a checkout operation touching a source file's mtime without
/// changing its content) forces one extra, harmless rebuild; a false
/// negative would silently run stale runtime behavior and misreport a
/// mutation's verdict, which is the worse failure mode by a wide margin.
///
/// Only runs when the MutantKit source checkout can actually be found (see
/// `SchemataRuntimeSourceLocation`) — a released binary's user has nothing
/// to compare against, so this lets that case through unchecked, exactly
/// matching today's (unprotected) behavior for it. `LocatorError`'s own
/// messages are what tell that user iOS-Simulator schemata mode needs a
/// checkout in the first place.
enum SchemataRuntimeStalenessGuard {
    struct StaleSource: Equatable {
        let path: String
        let modified: Date
    }

    static func staleSources(
        archivePath: URL,
        sourceDirectory: URL?,
        fileManager: FileManager = .default
    ) -> [StaleSource] {
        guard let sourceDirectory,
              let archiveModified = modificationDate(of: archivePath, fileManager: fileManager)
        else { return [] }

        guard let enumerator = fileManager.enumerator(
            at: sourceDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var stale: [StaleSource] = []
        for case let url as URL in enumerator {
            guard ["c", "h"].contains(url.pathExtension.lowercased()) else { continue }
            guard let modified = modificationDate(of: url, fileManager: fileManager), modified > archiveModified else { continue }
            stale.append(StaleSource(path: url.path, modified: modified))
        }
        return stale.sorted { $0.path < $1.path }
    }

    private static func modificationDate(of url: URL, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
