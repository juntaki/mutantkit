import Foundation
import MutationExecution
import MutationModel
import SwiftFrontend

/// Absolute paths to the tools these adapters spawn.
///
/// Absolute because `ProcessSupervisor` hands the executable straight to
/// `posix_spawn`, which does not search `PATH`. Everything Apple ships is reached
/// through `xcrun`, so the active toolchain — not this process's environment —
/// decides which `swift` or `simctl` actually runs.
enum ToolPaths {
    static let xcrun = "/usr/bin/xcrun"
    static let xcodebuild = "/usr/bin/xcodebuild"
}

public enum SchemataWriteError: Error, Equatable, CustomStringConvertible {
    case pathOutsideWorkspace(path: String, workspace: String)

    public var description: String {
        switch self {
        case let .pathOutsideWorkspace(path, workspace):
            "lowered source path \(path) resolves outside workspace \(workspace)"
        }
    }
}

/// Writes a `SchemataLowerer`-produced source into a workspace — shared by
/// every `SchemataBuildable` adapter (`SwiftPackageMacOSAdapter`,
/// `XcodeBuildAdapter`), since none of this is build-system-specific.
enum SchemataSourceWriter {
    static func write(_ source: SchemataSourceFile, in workspace: URL) throws {
        let destination = try resolveWriteURL(in: workspace, relativePath: source.relativePath)
        try Data(source.contents.utf8).write(to: destination, options: .atomic)
    }

    /// The same directory-traversal discipline `WorkspaceManager
    /// .resolveSourceURL` already applies to isolated-mode mutation
    /// application: a lowered source's `relativePath` is data, and data
    /// does not get to name its way outside the sandbox, nor through a
    /// symlink that happens to resolve outside it. Not implemented by
    /// calling into `WorkspaceManager` directly — no `SchemataBuildable`
    /// adapter holds an instance of it.
    ///
    /// Deliberately resolves symlinks on the candidate's *parent*
    /// directory, not the candidate itself, unlike a naive port of
    /// `resolveSourceURL`'s own two-stage check: `URL
    /// .resolvingSymlinksInPath()` only resolves an intermediate symlink
    /// when the *full* path, including the last component, already
    /// exists on disk — confirmed empirically, not assumed. A lowered
    /// source in practice always overwrites a file the sandbox already
    /// has (every `relativePath` a chunk touches names a real file from
    /// the checked-out project), so that gap is not reachable from
    /// `buildSchemataChunk`'s real call pattern — but writing this check
    /// so it only defends the reachable case would be exactly the kind
    /// of narrow, assumption-laden safety check this codebase does not
    /// trust elsewhere. Resolving the *parent* directory (which does
    /// exist, being part of the sandbox's own tree) and re-appending the
    /// leaf catches a malicious intermediate symlink regardless of
    /// whether the leaf file itself exists yet.
    private static func resolveWriteURL(in workspace: URL, relativePath: String) throws -> URL {
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw SchemataWriteError.pathOutsideWorkspace(path: candidate.path, workspace: root.path)
        }

        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolved = resolvedParent.appendingPathComponent(candidate.lastPathComponent).standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw SchemataWriteError.pathOutsideWorkspace(path: resolved.path, workspace: root.path)
        }
        return resolved
    }
}

/// Strips credentials from output before it is stored in a diagnosis.
///
/// Build logs quote the environment they ran with, and CI environments routinely
/// carry signing secrets and registry tokens. A diagnosis is written to disk and
/// pasted into issues, so it must never be the thing that leaks them.
enum OutputRedactor {
    /// Environment variables whose *values* are removed wherever they appear.
    /// Matching by name is not enough — the value gets echoed inside compiler
    /// invocations where the name is nowhere nearby.
    private static let sensitiveNamePattern =
        "(?:TOKEN|SECRET|PASSWORD|PASSWD|APIKEY|API_KEY|KEY|CREDENTIAL|AUTH|SESSION|COOKIE|PRIVATE)"

    private static let patterns: [(NSRegularExpression, String)] = {
        let specifications: [(String, String)] = [
            // `SOME_TOKEN=value` / `SOME_TOKEN: value` in echoed environments.
            ("(?i)\\b([A-Z0-9_]*\(sensitiveNamePattern)[A-Z0-9_]*)\\s*[=:]\\s*(\"[^\"]*\"|'[^']*'|\\S+)", "$1=<redacted>"),
            // `--password value`, `-token value` on recorded command lines.
            ("(?i)(--?[a-z0-9-]*\(sensitiveNamePattern)[a-z0-9-]*)[= ]+(\"[^\"]*\"|'[^']*'|\\S+)", "$1 <redacted>"),
            // Bearer tokens in any quoted header.
            ("(?i)\\b(bearer|basic)\\s+[A-Za-z0-9._~+/=-]{8,}", "$1 <redacted>"),
            // Credentials embedded in a URL's authority.
            ("(?i)([a-z][a-z0-9+.-]*://)[^/@\\s:]+:[^/@\\s]+@", "$1<redacted>@")
        ]
        return specifications.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    static func redact(_ text: String) -> String {
        patterns.reduce(text) { partial, entry in
            entry.0.stringByReplacingMatches(
                in: partial,
                range: NSRange(partial.startIndex..., in: partial),
                withTemplate: entry.1
            )
        }
    }

    /// Redacts, then keeps the tail.
    ///
    /// The tail, because a compiler's first error is followed by hundreds of
    /// cascading ones and the summary that names the real problem is printed last.
    static func redactAndTruncate(_ text: String, limit: Int = 16000) -> String {
        let redacted = redact(text)
        guard redacted.count > limit else { return redacted }
        return "<earlier output truncated>\n" + String(redacted.suffix(limit))
    }
}

/// Hashes built test products so a mutant's binary can be proven different
/// from the baseline's.
///
/// Only the executable code inside each test bundle is hashed — not the bundle,
/// and not even the whole binary. `MachOCodeHash` explains why in detail; the
/// short version is that two builds of identical source differ in their UUID,
/// embedded `#file` paths and coverage tables, so any broader hash would report
/// every mutant as activated and prove nothing.
enum TestProductHasher {
    /// Combines the code in every test bundle under `directory` into one hash.
    ///
    /// Returns `nil` when no test binary is found or none can be read, which the
    /// caller must treat as "activation unproven" rather than as an
    /// empty-but-valid hash.
    static func hash(productsDirectory directory: URL) -> String? {
        let bundles = testBundles(in: directory)
        guard !bundles.isEmpty else { return nil }

        // Sorted by bundle-relative name so directory enumeration order, which is
        // not stable across machines, cannot change the hash.
        let componentHashes = bundles
            .compactMap { bundle -> (String, String)? in
                guard let binary = executable(inBundle: bundle),
                      let hash = MachOCodeHash.codeHash(ofBinaryAt: binary)
                else { return nil }
                return (bundle.lastPathComponent, hash)
            }
            .sorted { $0.0 < $1.0 }

        guard !componentHashes.isEmpty else { return nil }
        return ContentHash.of(componentHashes.map { "\($0.0):\($0.1)" }.joined(separator: "\n"))
    }

    /// Bundle kinds whose binary can carry the mutated code.
    ///
    /// `.xctest` alone is not enough, and assuming it was is a subtle way to get
    /// everything wrong. A Swift package statically links the module under test
    /// into the test bundle, so the test binary moves when the source does. An
    /// Xcode project does not: the code lives in its own framework or app, and
    /// the `.xctest` merely links against it. Hashing only test bundles there
    /// yields a hash identical to the baseline's for every mutant — which reads
    /// as "the mutation never ran" for the whole run.
    private static let bundleExtensions: Set<String> = ["xctest", "framework", "app", "appex", "bundle"]

    /// Xcode's "Debug Dylib" build acceleration — on by default for
    /// Debug/simulator builds on recent toolchains — moves an Xcode-project
    /// app or framework target's own compiled code out of its host executable
    /// and into a loose `<Target>.debug.dylib` sitting directly inside the
    /// `.app`/`.framework`, so an incremental rebuild can relink just that
    /// dylib instead of the whole product. The host executable left behind is
    /// a near-empty stub that loads it at runtime.
    ///
    /// Found on a real Xcode-project iOS app where
    /// every single mutant — across four different files, two different
    /// targets — reported `mutationNotActivated`: the main executable really
    /// was byte-identical every time, because none of the mutated code was
    /// ever in it. `App.debug.dylib`, sitting unnoticed beside it, was 13.5 MB
    /// against the executable's 58 KB and carried the entire app.
    /// `bundleExtensions` has no entry for a loose file, so it was invisible
    /// to the scan.
    private static let looseDylibExtension = "dylib"

    private static func testBundles(in directory: URL) -> [URL] {
        // SwiftPM publishes `.build/debug` as a symlink to the real
        // per-architecture directory, and the enumerator will not traverse a
        // symlink handed to it as its root — it silently yields nothing. That
        // reads downstream as "no test binary", which the classifier correctly
        // but uselessly reports as activation-unproven for every mutant.
        guard let enumerator = FileManager.default.enumerator(
            at: directory.resolvingSymlinksInPath(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator where bundleExtensions.contains(url.pathExtension) {
            found.append(url)
            // A debug dylib sits directly inside the bundle it belongs to, not
            // nested in a bundle of its own, so it has to be picked up here —
            // one level down is skipped below along with everything else.
            found.append(contentsOf: looseDylibs(directlyInside: url))
            // Nested bundles — a framework embedded in an app, an `.xctest`
            // inside it — are reached through their container's own binary, and
            // descending would hash the same Mach-O twice under two names.
            enumerator.skipDescendants()
        }
        return found
    }

    private static func looseDylibs(directlyInside bundle: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: bundle, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { $0.pathExtension == looseDylibExtension }
    }

    /// Finds the Mach-O inside a bundle.
    ///
    /// Layout differs by platform and bundle kind: macOS bundles nest the binary
    /// under `Contents/MacOS`, while iOS bundles and frameworks put it at the top
    /// level under the bundle's own name. A loose dylib is not a bundle at all —
    /// it already *is* the Mach-O.
    private static func executable(inBundle bundle: URL) -> URL? {
        guard bundle.pathExtension != looseDylibExtension else {
            return FileManager.default.fileExists(atPath: bundle.path) ? bundle : nil
        }

        let name = bundle.deletingPathExtension().lastPathComponent
        let candidates = [
            bundle.appendingPathComponent("Contents/MacOS/\(name)"),
            bundle.appendingPathComponent("Versions/A/\(name)"),
            bundle.appendingPathComponent(name)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Builds a `CommandRecord` from a supervised run.
///
/// Every command this module spawns is recorded, because `reproduce` must be able
/// to replay the exact invocation rather than an approximation of it.
enum CommandRecording {
    static func record(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        result: ProcessResult?
    ) -> CommandRecord {
        CommandRecord(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory.path,
            exitCode: result?.exitCode,
            durationSeconds: result?.durationSeconds
        )
    }
}

extension ProcessResult {
    /// Redacted stdout and stderr together, in the order a reader expects.
    var combinedOutput: String {
        let out = String(decoding: standardOutput, as: UTF8.self)
        let err = String(decoding: standardError, as: UTF8.self)
        return [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A production call to `ProcessSupervisor.run`, injectable — mirrors
/// `RunContextProbe.ProcessRunner` for the identical reason: a test can
/// substitute a real `ProcessResult` (e.g. one with `outputComplete ==
/// false`) without reproducing the real subprocess condition that produces
/// it. `XcodeBuildAdapter.uninstallStaleApp` is the one caller today.
typealias ProcessRunner = @Sendable (
    _ executable: String, _ arguments: [String], _ workingDirectory: URL, _ timeoutSeconds: Double
) async throws -> ProcessResult

let defaultProcessRunner: ProcessRunner = { executable, arguments, workingDirectory, timeoutSeconds in
    try await ProcessSupervisor.run(
        executable: executable, arguments: arguments, workingDirectory: workingDirectory, timeoutSeconds: timeoutSeconds
    )
}

/// Free space on the volume holding `url`, in bytes.
func availableDiskSpace(at url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
