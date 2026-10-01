import Foundation
import MutationExecution

/// Runs `swift package dump-package`, the one way this tool reads a package
/// manifest.
///
/// The manifest is Swift, not data: only SwiftPM can say what it evaluates
/// to. `dump-package` evaluates it without resolving or fetching
/// dependencies and without writing to the package, so it is safe to run on
/// the user's tree.
enum SwiftPMManifestDump {
    static let arguments = ["swift", "package", "dump-package"]

    /// The raw JSON `dump-package` prints for the manifest in `directory`.
    ///
    /// The process runs through `xcrun` with the ambient environment, the
    /// same way `swift build` does, so a manifest that branches on the
    /// environment evaluates here as it will in the build.
    static func run(
        in directory: URL,
        timeoutSeconds: Double,
        processRunner: ProcessRunner
    ) async throws -> Data {
        var result = try await processRunner(ToolPaths.xcrun, arguments, directory, timeoutSeconds)

        // A truncated capture (`outputComplete == false`) has reached this
        // point on real CI with an empty stderr under extreme resource
        // pressure (available memory in the low single-digit GB, system load
        // many multiples of the core count) -- indistinguishable from a
        // genuine "manifest is broken" failure without this signal, and the
        // identical invocation has been observed to succeed immediately
        // afterward once pressure eases. See `ProcessResult.outputComplete`'s
        // own doc comment for the general incident class this guards
        // against (the same shape that hit `simctl uninstall` for real). One
        // bounded retry, not an open-ended loop: a manifest that is
        // genuinely unreadable fails the same way on the retry too.
        if !result.outputComplete {
            result = try await processRunner(ToolPaths.xcrun, arguments, directory, timeoutSeconds)
        }

        guard result.outputComplete else {
            throw ProjectDetectionError.manifestUnreadable(
                directory: directory.path,
                detail: "swift package dump-package exited (status \(result.exitCode)) but its output could not be " +
                    "fully captured before the subprocess ended, even after one retry"
            )
        }

        guard result.succeeded else {
            throw ProjectDetectionError.manifestUnreadable(
                directory: directory.path,
                detail: OutputRedactor.redact(String(decoding: result.standardError, as: UTF8.self))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return result.standardOutput
    }
}

/// `dump-package` output for each package directory already evaluated,
/// keyed by canonical path.
///
/// Project detection and local-dependency discovery both read the project's
/// own manifest. Sharing one of these between them evaluates it once per
/// run. A manifest does not change during a run, and a sandbox copy lives
/// at a different canonical path, so it is never served from here.
public actor SwiftPMManifestDumps {
    private var outputs: [String: Data] = [:]

    public init() {}

    func output(
        in directory: URL,
        timeoutSeconds: Double,
        processRunner: ProcessRunner
    ) async throws -> Data {
        let canonical = CanonicalPath.resolve(directory.path).map { URL(fileURLWithPath: $0) } ?? directory
        if let cached = outputs[canonical.path] {
            return cached
        }
        let output = try await SwiftPMManifestDump.run(
            in: canonical, timeoutSeconds: timeoutSeconds, processRunner: processRunner
        )
        outputs[canonical.path] = output
        return output
    }
}
