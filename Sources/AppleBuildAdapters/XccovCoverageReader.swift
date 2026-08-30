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
    /// - Parameter processRunner: `AdapterSupport.swift`'s `ProcessRunner`
    ///   seam, letting a test force `outputComplete == false` deterministically
    ///   (mirrors `XcodeBuildAdapter.uninstallStaleApp`'s identical use of it).
    ///   `internal`, not `public` (like `ProcessRunner`/`defaultProcessRunner`
    ///   themselves) — every real caller is inside this module; only `parse`,
    ///   the pure half, is meant to be called from outside it.
    static func read(
        archive xcresult: URL, projectRoot: URL, processRunner: ProcessRunner = defaultProcessRunner
    ) async -> CoverageMap? {
        guard FileManager.default.fileExists(atPath: xcresult.path) else { return nil }

        let result: ProcessResult
        do {
            result = try await processRunner(
                ToolPaths.xcrun,
                ["xccov", "view", "--archive", xcresult.path, "--json"],
                projectRoot,
                120
            )
        } catch {
            return nil
        }

        // See `ProcessResult.outputComplete`'s own doc comment: a coverage
        // JSON document is exactly the kind of evidence that must never be
        // trusted when the drain that produced it may have been truncated —
        // a real line's `executionCount` silently missing from the tail of
        // a cut-off document reads as "no coverage information for this
        // line" to `parse` below, not as "this file's evidence is
        // incomplete", the same partial-evidence-as-complete failure class
        // `measurePerTestCoverage`'s own `return nil` conversion (see this
        // adapter's `measurePerTestCoverage`) exists to close one layer up.
        guard result.succeeded, result.outputComplete,
              let executed = parse(result.standardOutput, projectRoot: projectRoot)
        else {
            return nil
        }
        return CoverageMap(executedLines: executed, source: "xcodebuild-xccov")
    }

    /// Parses a single `xccov --json` document. Exposed for tests so a
    /// fixture string can drive the reader without a toolchain or a bundle.
    ///
    /// All-or-nothing, matching `SourceCoverageReader.executedLines`: a
    /// malformed entry for an executable line invalidates the whole
    /// document, never just that one entry. `xccov` always emits an
    /// `executionCount` for every line it reports `isExecutable: true` — its
    /// absence, or a wrong-typed `line`/`isExecutable`/`executionCount`, is
    /// not a shape a well-formed report ever takes, so it is treated the
    /// same as a corrupted document rather than "this line has no coverage".
    /// A non-executable line legitimately carries no `executionCount` at
    /// all; that absence alone is not malformation.
    ///
    /// A document that parses cleanly but legitimately covers nothing is
    /// still conservatively treated as unavailable today: `executed.isEmpty
    /// ? nil : executed` below folds a valid empty result into the same
    /// `nil` a malformed one produces, so `measurePerTestCoverage` falls
    /// back to the full suite either way. Safe (a fallback is never wrong,
    /// only slower), so left unchanged; distinguishing the two is a
    /// performance question for later, not a correctness gap now.
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
                guard let line = entry["line"] as? Int, line >= 1,
                      let isExecutable = entry["isExecutable"] as? Bool
                else { return nil }

                guard isExecutable else { continue }

                guard let count = entry["executionCount"] as? Int, count >= 0 else { return nil }

                if count > 0 { lines.insert(line) }
            }
            guard !lines.isEmpty else { continue }
            executed[relativePath, default: []].formUnion(lines)
        }

        return executed.isEmpty ? nil : executed
    }
}
