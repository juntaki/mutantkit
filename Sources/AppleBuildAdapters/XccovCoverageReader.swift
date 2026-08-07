import Foundation
import MutationExecution

/// Reads Xcode's own coverage report — `xcrun xccov view --archive <xcresult>
/// --json` — into a `CoverageMap`.
///
/// Unlike `SourceCoverageReader`, this does not touch a `.profdata` or the
/// LLVM segments export: `xccov` already resolves an `.xcresult` bundle's
/// coverage into a flat per-line report, confirmed empirically against a real
/// bundle to be
/// `{"<absolute path>": [{"line": Int, "isExecutable": Bool, "executionCount"?: Int}, ...]}` —
/// one entry per line in the file, executable or not. A line counts as
/// executed when it is marked executable *and* its count is greater than
/// zero; `executionCount` is absent entirely for non-executable lines.
///
/// The reader does not decide *when* to enable coverage or which bundle to
/// read — that is `XcodeBuildAdapter`'s call, made once it knows whether this
/// run asked for coverage at all. This type is text (or a bundle path) in,
/// data out, so it stays testable without a toolchain on disk.
public enum XccovCoverageReader {
    /// Shells out to `xccov` for one `.xcresult` bundle and parses its report.
    ///
    /// - Returns: `nil` when the bundle does not exist, `xccov` fails, or the
    ///   output does not parse — all treated as "no coverage information",
    ///   never as "the project has zero coverage".
    public static func read(archive xcresult: URL, projectRoot: URL) async -> CoverageMap? {
        guard FileManager.default.fileExists(atPath: xcresult.path) else { return nil }

        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcrun,
                arguments: ["xccov", "view", "--archive", xcresult.path, "--json"],
                workingDirectory: projectRoot,
                timeoutSeconds: 120
            )
        } catch {
            return nil
        }

        guard result.succeeded, let executed = parse(result.standardOutput, projectRoot: projectRoot) else {
            return nil
        }
        return CoverageMap(executedLines: executed, source: "xcodebuild-xccov")
    }

    /// Parses a single `xccov --json` document. Exposed for tests so a
    /// fixture string can drive the reader without a toolchain or a bundle.
    public static func parse(_ data: Data, projectRoot: URL) -> [String: Set<Int>]? {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] else {
            return nil
        }

        let rootPath = projectRoot.standardizedFileURL.path
        var executed: [String: Set<Int>] = [:]

        for (absolutePath, entries) in document {
            guard let relativePath = SourceCoverageReader.relativePath(
                from: absolutePath, droppingPrefix: rootPath
            ) else { continue }

            var lines = Set<Int>()
            for entry in entries {
                guard let line = entry["line"] as? Int,
                      entry["isExecutable"] as? Bool == true,
                      let count = entry["executionCount"] as? Int,
                      count > 0
                else { continue }
                lines.insert(line)
            }
            guard !lines.isEmpty else { continue }
            executed[relativePath, default: []].formUnion(lines)
        }

        return executed.isEmpty ? nil : executed
    }
}
