import Foundation
import MutationExecution
import MutationModel

enum RunContextProbeError: Error, CustomStringConvertible {
    case gitUnavailable(String)

    var description: String {
        switch self {
        case let .gitUnavailable(detail):
            """
            Could not fingerprint the project state (\(detail)). Checkpoint \
            resume needs git to prove nothing changed since a checkpoint was \
            written; without it, resuming would risk reusing a stale result, \
            so this run will not resume from any existing checkpoint.
            """
        }
    }
}

/// Fingerprints everything a checkpoint's cached result depends on, so a
/// resumed run can refuse to reuse an entry written against a different
/// source, test suite, project file, or toolchain.
///
/// Lives in the CLI, not `MutationPlanner` or `MutationExecution`, for the
/// same reason `GitDiff` does: the layers underneath stay subprocess-free
/// and testable against fixtures, and only the CLI actually knows this is a
/// git checkout.
enum RunContextProbe {
    /// Bumped whenever `ResultClassifier`'s outcome-producing logic changes
    /// in a way that could make a previously-checkpointed `MutationResult`
    /// wrong under the new rules — most recently when a scorable outcome
    /// was made to require proven activation evidence (see
    /// `unprovenActivation` in `ResultClassifier.swift`). A checkpoint's
    /// fingerprint has no other way to know which classifier version wrote
    /// its entries, and this codebase's other cross-run cache
    /// (`MutationResultCache`, keyed via `computeContextDigest`'s `purpose`
    /// tag) uses the identical mechanism for the identical reason — see
    /// `RunCommand.swift`'s `resultCacheDigest`. Folding this in means a
    /// resumed run can never silently trust a stale, incorrectly-classified
    /// result just because every other input (source, tests, toolchain,
    /// config) happens to still match.
    static let classificationRulesVersion = 2

    static func compute(
        projectRoot: URL,
        configuration: Configuration,
        toolchain: ToolchainFingerprint,
        workUnitID: String
    ) async throws -> RunContextFingerprint {
        let git = try await gitState(in: projectRoot)

        let components = [
            "classificationRulesVersion=\(classificationRulesVersion)",
            "workUnitID=\(workUnitID)",
            "configurationHash=\(configuration.configurationHash)",
            "toolVersion=\(toolchain.toolVersion)",
            "toolCommitSHA=\(toolchain.toolCommitSHA ?? "unknown")",
            "swiftVersion=\(toolchain.swiftVersion)",
            "swiftSyntaxVersion=\(toolchain.swiftSyntaxVersion)",
            "xcodeVersion=\(toolchain.xcodeVersion ?? "unknown")",
            "gitState=\(git)"
        ]

        return RunContextFingerprint(value: ContentHash.of(components.joined(separator: "\u{1F}")))
    }

    /// A digest of everything a cached, per-mutation-independent artifact
    /// depends on — used for both `CoverageProfileCache` (baseline per-test
    /// coverage attribution) and `MutationResultCache` (a mutant's
    /// evaluated outcome).
    ///
    /// Same inputs as `compute(projectRoot:configuration:toolchain:workUnitID:)`
    /// except for `workUnitID`: both coverage attribution and a mutant's
    /// outcome are properties of the source tree, test suite, and toolchain,
    /// not of which mutations happen to be planned alongside them. Two
    /// different plans against the same tree share one digest and therefore
    /// reuse cached entries for anything they have in common; the same plan
    /// against a changed tree produces a different digest and recomputes
    /// from scratch.
    ///
    /// A purpose tag is folded in so the result cache and coverage cache —
    /// which share every other input but have different on-disk formats and
    /// different invalidation-worthy changes (e.g. a `PerTestCoverageMap`
    /// shape bump should not also invalidate every cached result) — maintain
    /// independent invalidation timelines under one shared computation.
    static func computeContextDigest(
        projectRoot: URL,
        configuration: Configuration,
        toolchain: ToolchainFingerprint,
        purpose: String
    ) async throws -> String {
        let git = try await gitState(in: projectRoot)

        let components = [
            "\(purpose)=v1",
            "configurationHash=\(configuration.configurationHash)",
            "toolVersion=\(toolchain.toolVersion)",
            "toolCommitSHA=\(toolchain.toolCommitSHA ?? "unknown")",
            "swiftVersion=\(toolchain.swiftVersion)",
            "swiftSyntaxVersion=\(toolchain.swiftSyntaxVersion)",
            "xcodeVersion=\(toolchain.xcodeVersion ?? "unknown")",
            "gitState=\(git)"
        ]

        return ContentHash.of(components.joined(separator: "\u{1F}"))
    }

    /// `HEAD` plus everything git can see has changed from it: staged and
    /// unstaged modifications to every tracked file (`git diff HEAD` —
    /// production source, test source, `project.pbxproj`, `.xcscheme`
    /// files, `Package.resolved`, `mutantkit.yml` itself, all of it, since none
    /// of them are excluded), and the content of every untracked file
    /// (`git status --porcelain`, which is exactly how a newly-added test
    /// file or a locally-deleted-then-restored fixture shows up before it is
    /// staged — the precise shape of the change that motivated this).
    ///
    /// Tool-owned output (`.mutantkit/`, `.mutare/`) is explicitly stripped
    /// from the untracked set: the digest must not depend on its own output.
    /// A run creates its run lock, coverage cache, result cache and
    /// checkpoint *before* this digest is computed (they are the things the
    /// digest keys), so without this exclusion each run's lock filename and
    /// growing cache would land in the hash whenever the project's own
    /// `.gitignore` does not ignore them — changing the digest every run and
    /// silently defeating both caches. `.mutare/` is the prior tool name and
    /// is excluded for the same reason during any mixed-version transition.
    static func gitState(in root: URL) async throws -> String {
        let head = try await run(["rev-parse", "HEAD"], in: root)
        let diff = try await run(["diff", "HEAD", "--no-color", "--no-ext-diff"], in: root)
        let status = try await run(["status", "--porcelain=v1", "--untracked-files=all"], in: root)

        var untrackedHashes: [String] = []
        for line in status.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("?? ") else { continue }
            let relativePath = unquotedGitPath(String(line.dropFirst(3)))
            guard !isToolOwnedPath(relativePath) else { continue }
            let fileURL = root.appendingPathComponent(relativePath)
            if let hash = try? ContentHash.ofFile(at: fileURL) {
                untrackedHashes.append("\(relativePath)=\(hash)")
            }
        }
        untrackedHashes.sort()

        return ([head, diff] + untrackedHashes).joined(separator: "\u{1F}")
    }

    /// Directories the tool itself writes under the project root. The digest
    /// folds in everything git can see, so any of these that are not covered
    /// by the project's own `.gitignore` must be dropped here, or the digest
    /// becomes a function of the tool's own output.
    private static let toolOwnedRoots = [".mutantkit", ".mutare"]

    /// True if `relativePath` (as it appears in `git status --porcelain` output)
    /// lives under one of the tool-owned roots.
    static func isToolOwnedPath(_ relativePath: String) -> Bool {
        let path = unquotedGitPath(relativePath)
        for root in toolOwnedRoots {
            if path == root || path.hasPrefix(root + "/") { return true }
        }
        return false
    }

    /// Reverses the C-style quoting `git status --porcelain` applies to paths
    /// that contain bytes needing escaping (the raw entry may be wrapped in
    /// double quotes). Only the outer quotes are unwrapped here: the tool-owned
    /// roots and the paths we compare them against are ASCII, so no further
    /// unescaping is needed to make the prefix check exact.
    private static func unquotedGitPath(_ entry: String) -> String {
        guard entry.hasPrefix("\""), entry.hasSuffix("\""), entry.count >= 2 else { return entry }
        return String(entry.dropFirst().dropLast())
    }

    private static func run(_ arguments: [String], in root: URL) async throws -> String {
        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: "/usr/bin/git",
                arguments: arguments,
                workingDirectory: root,
                timeoutSeconds: 60
            )
        } catch {
            throw RunContextProbeError.gitUnavailable("\(error)")
        }
        guard result.succeeded else {
            throw RunContextProbeError.gitUnavailable(
                String(decoding: result.standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
