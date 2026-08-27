import Foundation
import MutationExecution
import MutationModel

enum RunContextProbeError: Error, CustomStringConvertible {
    case gitUnavailable(String)
    case unprovableWorktreeContent(path: String, reason: String)

    var description: String {
        switch self {
        case let .gitUnavailable(detail):
            """
            Could not fingerprint the project state (\(detail)). Checkpoint \
            resume needs git to prove nothing changed since a checkpoint was \
            written; without it, resuming would risk reusing a stale result, \
            so this run will not resume from any existing checkpoint.
            """
        case let .unprovableWorktreeContent(path, reason):
            """
            Could not fingerprint '\(path)' (\(reason)). The project-state \
            digest must be a total function of the bytes of every file in \
            scope: a path whose content cannot be read is a path this run \
            cannot prove is unchanged, and hashing the rest anyway would let \
            "unreadable" and "absent" produce the same digest — a false cache \
            hit. This run therefore uses no cross-run cache and resumes from \
            no checkpoint; it recomputes everything instead.
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
        let git = try await worktreeContentState(in: projectRoot)

        let components = [
            "classificationRulesVersion=\(classificationRulesVersion)",
            "workUnitID=\(workUnitID)",
            "configurationHash=\(configuration.configurationHash)",
            "toolVersion=\(toolchain.toolVersion)",
            "toolCommitSHA=\(toolchain.toolCommitSHA ?? "unknown")",
            "swiftVersion=\(toolchain.swiftVersion)",
            "swiftSyntaxVersion=\(toolchain.swiftSyntaxVersion)",
            "xcodeVersion=\(toolchain.xcodeVersion ?? "unknown")",
            "buildSDKIdentity=\(toolchain.buildSDKIdentity ?? "unknown")",
            "destinationRuntimeIdentity=\(toolchain.destinationRuntimeIdentity ?? "unknown")",
            "worktreeContentState=\(git)"
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
    ///
    /// ## Why the version marker reads `v4`
    ///
    /// `v1` keyed on *commit identity* (`git rev-parse HEAD` plus
    /// `git diff HEAD`); `v2` moved to *content identity* — see
    /// `worktreeContentState`. `v3` additionally scopes out
    /// `execution.workers` (see below). `v4` (P4 cache-soundness gap fix)
    /// adds `toolchain.buildSDKIdentity`/`.destinationRuntimeIdentity` to
    /// the inputs below — every
    /// pre-existing entry on disk was written under a digest scheme whose
    /// inputs no longer match, so it misses cleanly and is recomputed. There
    /// is deliberately no migration: a cache entry is a claim about a
    /// context, and a context computed by a scheme this build no longer
    /// implements is a claim this build cannot check. Bumping the shared
    /// marker rather than each `purpose` tag is exact — the change is to the
    /// scheme both purposes share, not to what makes either one's payload
    /// trustworthy.
    static func computeContextDigest(
        projectRoot: URL,
        configuration: Configuration,
        toolchain: ToolchainFingerprint,
        purpose: String
    ) async throws -> String {
        let worktree = try await worktreeContentState(in: projectRoot)

        // `execution.workers` bounds chunk/mutant-level *parallelism* only —
        // it has no bearing on what a baseline build produces, what per-test
        // coverage attribution measures, or what any single mutant's own
        // build/test outcome is (both purposes this digest serves). Zeroed
        // out here, mirroring `Configuration.configurationHash`'s own
        // `qualityGate` zeroing, so a coverage-cache or result-cache entry
        // written by a `workers: 1` run is still served to an otherwise-
        // identical run configured with `workers: 4` (or left unset) —
        // `resolvedWorkerCount()` picks a different fan-out either way, but
        // measures/produces the identical thing.
        var scopedConfiguration = configuration
        scopedConfiguration.execution.workers = nil

        let components = [
            "\(purpose)=v4",
            "configurationHash=\(scopedConfiguration.configurationHash)",
            "toolVersion=\(toolchain.toolVersion)",
            "toolCommitSHA=\(toolchain.toolCommitSHA ?? "unknown")",
            "swiftVersion=\(toolchain.swiftVersion)",
            "swiftSyntaxVersion=\(toolchain.swiftSyntaxVersion)",
            "xcodeVersion=\(toolchain.xcodeVersion ?? "unknown")",
            "buildSDKIdentity=\(toolchain.buildSDKIdentity ?? "unknown")",
            "destinationRuntimeIdentity=\(toolchain.destinationRuntimeIdentity ?? "unknown")",
            "worktreeContentState=\(worktree)"
        ]

        return ContentHash.of(components.joined(separator: "\u{1F}"))
    }

    /// A content fingerprint of the project worktree: the sorted list of
    /// `relativePath=contentIdentity` over every path git reports as present
    /// and non-ignored — tracked (`git ls-files`) plus untracked
    /// (`git status --porcelain`'s `??` entries) — minus tool-owned output.
    ///
    /// ## Content identity, not commit identity
    ///
    /// This deliberately does **not** fold in `git rev-parse HEAD`, and does
    /// not read `git diff HEAD` at all. The predecessor did both, and both
    /// were defects rather than safety margin:
    ///
    /// - `HEAD` is not an input to any verdict. `git commit --allow-empty`,
    ///   an amend, a rebase, a merge commit with an identical tree, or a
    ///   commit touching only `README.md` all moved the digest, so every
    ///   cached mutant verdict and the whole cached coverage profile missed.
    ///   Since a commit is the only thing CI ever does, both cross-run
    ///   caches could never survive into a CI run at all.
    /// - Worse, `HEAD` and the diff moved *together and opposite*: with a
    ///   file edited but uncommitted the digest was `(HEAD₀, diff=the edit)`;
    ///   committing that exact edit made it `(HEAD₁, diff=empty)` — a
    ///   different digest for a byte-identical worktree. "Developer runs
    ///   locally, commits, CI runs the commit" was a guaranteed 100% miss.
    ///
    /// Dropping `HEAD` is *sound*, not merely convenient, and the reason is
    /// mechanical: `WorkspaceManager.defaultExcludes` lists `.git`, so no
    /// mutant sandbox contains a git directory. No compiler, build script or
    /// test in a mutant run can observe the commit SHA, so no verdict can
    /// depend on it. The one dimension this digest is coarser in than its
    /// predecessor is a dimension the thing being cached provably cannot see.
    ///
    /// In every other dimension it is strictly *finer*: tracked-file content
    /// is now the SHA-256 of the worktree bytes, rather than being observed
    /// second-hand through rendered `git diff` text and the abbreviated blob
    /// hashes in its `index` lines.
    ///
    /// ## Scope
    ///
    /// The scoped set is a superset of what a sandbox can read:
    /// `WorkspaceManager` builds a sandbox by copying the project root minus
    /// `defaultExcludes`, so the sandbox's files are a subset of the
    /// worktree's non-ignored files. Equal digests therefore imply equal
    /// bytes for every file the build and the tests can reach, which implies
    /// an equal verdict.
    ///
    /// The excluded-from-sandbox roots (`.build`, `DerivedData`, `Pods`, …)
    /// are deliberately **not** subtracted here even though subtracting them
    /// would also be sound. `WorkspaceManager.init` lets a caller override
    /// `excludes`, so subtracting the default list would silently couple this
    /// digest to a value that is not guaranteed to be the one in force.
    /// Keeping them is conservative, and conservative costs only hit rate.
    ///
    /// Tool-owned output (`.mutantkit/`, `.mutare/`) *is* stripped: the
    /// digest must not depend on its own output. A run creates its run lock,
    /// coverage cache, result cache and checkpoint *before* this digest is
    /// computed (they are the things the digest keys), so without this
    /// exclusion each run's lock filename and growing cache would land in the
    /// hash whenever the project's own `.gitignore` does not ignore them —
    /// changing the digest every run and silently defeating both caches.
    /// `.mutare/` is the prior tool name and is excluded for the same reason
    /// during any mixed-version transition.
    static func worktreeContentState(in root: URL) async throws -> String {
        // Both listings are made repository-root-relative and resolved
        // against the repository root, not against `root`. `git ls-files`
        // reports paths relative to the working directory while
        // `git status --porcelain` always reports them relative to the
        // repository root, so without `--full-name` the two disagree the
        // moment the project root is a subdirectory of its repository —
        // and one of them would then be resolved against the wrong base.
        let toplevel = URL(fileURLWithPath: try await run(["rev-parse", "--show-toplevel"], in: root))

        // `-z` on both: NUL-separated output is not C-quoted, so a path with
        // a quote, a newline or a non-ASCII byte in it arrives verbatim
        // instead of arriving escaped and needing to be unescaped correctly
        // to be compared correctly.
        let tracked = try await runRaw(["ls-files", "--full-name", "-z"], in: root)
        let status = try await runRaw(["status", "--porcelain=v1", "--untracked-files=all", "-z"], in: root)

        var paths = Set<String>()
        // A path in a merge conflict is listed once per stage; the set
        // collapses those, and the worktree file is hashed either way.
        for path in tracked.split(separator: "\0", omittingEmptySubsequences: true) {
            paths.insert(String(path))
        }
        for entry in status.split(separator: "\0", omittingEmptySubsequences: true) {
            // `XY <path>`: only untracked entries are collected here; every
            // tracked path, modified or not, already came from `ls-files`.
            guard entry.hasPrefix("?? ") else { continue }
            paths.insert(String(entry.dropFirst(3)))
        }

        let toolOwnedPrefix = projectRelativePrefix(of: root, within: toplevel)
        var entries: [String] = []
        entries.reserveCapacity(paths.count)
        for path in paths.sorted() where !isToolOwned(repositoryRelativePath: path, projectPrefix: toolOwnedPrefix) {
            let identity = try contentIdentity(of: toplevel.appendingPathComponent(path), path: path)
            entries.append("\(path)=\(identity)")
        }

        return entries.joined(separator: "\u{1F}")
    }

    /// Where the project root sits inside its repository, as a
    /// `/`-terminated repository-relative prefix (empty when the two are the
    /// same directory, which is the ordinary case).
    ///
    /// `nil` means the project root could not be located inside the
    /// repository at all. Every path is then treated as *not* tool-owned,
    /// which is the conservative direction: an extra entry in the digest can
    /// only cost hit rate, whereas wrongly dropping one could hide a real
    /// change.
    private static func projectRelativePrefix(of root: URL, within toplevel: URL) -> String? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let toplevelPath = toplevel.resolvingSymlinksInPath().standardizedFileURL.path
        if rootPath == toplevelPath { return "" }
        guard rootPath.hasPrefix(toplevelPath + "/") else { return nil }
        return String(rootPath.dropFirst(toplevelPath.count + 1)) + "/"
    }

    /// Tool-owned roots live under the *project* root, but git reports paths
    /// relative to the *repository* root. Re-relativize before asking, so
    /// that a project nested inside a larger repository still excludes its
    /// own `.mutantkit/` — without which every run's freshly-named lock and
    /// growing cache would enter the digest and defeat both caches.
    private static func isToolOwned(repositoryRelativePath path: String, projectPrefix: String?) -> Bool {
        guard let projectPrefix else { return false }
        guard projectPrefix.isEmpty else {
            guard path.hasPrefix(projectPrefix) else { return false }
            return isToolOwnedPath(String(path.dropFirst(projectPrefix.count)))
        }
        return isToolOwnedPath(path)
    }

    /// What this path contributes to the digest — a total function of the
    /// path's own bytes, or a thrown error.
    ///
    /// The throwing cases are the point. Skipping an entry that cannot be
    /// hashed would make "present but unreadable" and "not present at all"
    /// hash identically, which is a false cache hit — precisely the class of
    /// silent wrong answer this tool exists to rule out. So an unreadable
    /// file, a submodule gitlink (a separate repository whose contents this
    /// digest does not descend into), or any non-regular, non-symlink entry
    /// aborts the whole digest, and the caller degrades to running with no
    /// cross-run cache rather than with a cache it cannot vouch for.
    ///
    /// A symlink contributes its *link target text*, never the bytes it
    /// points at: the target may be outside the repository entirely, and it
    /// is the link itself that git tracks and that a sandbox copy reproduces.
    /// A tracked path deleted from the worktree contributes `absent`, which
    /// no readable file can collide with because every other branch returns
    /// either a `sha256:`-prefixed digest or a `symlink:` prefix.
    private static func contentIdentity(of url: URL, path: String) throws -> String {
        let fileManager = FileManager.default
        // `attributesOfItem` does not follow symlinks, so a symlink is
        // classified as one rather than as whatever it resolves to.
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return "absent"
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink:
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
                throw RunContextProbeError.unprovableWorktreeContent(
                    path: path, reason: "symlink target could not be read"
                )
            }
            return "symlink:" + ContentHash.of(target)
        case .typeRegular:
            guard let hash = try? ContentHash.ofFile(at: url) else {
                throw RunContextProbeError.unprovableWorktreeContent(
                    path: path, reason: "file could not be read"
                )
            }
            return hash
        case .typeDirectory:
            throw RunContextProbeError.unprovableWorktreeContent(
                path: path,
                reason: "tracked path is a directory — a submodule, whose contents this digest does not read"
            )
        default:
            throw RunContextProbeError.unprovableWorktreeContent(
                path: path, reason: "not a regular file or symlink"
            )
        }
    }

    /// Directories the tool itself writes under the project root. The digest
    /// folds in everything git can see, so any of these that are not covered
    /// by the project's own `.gitignore` must be dropped here, or the digest
    /// becomes a function of the tool's own output.
    private static let toolOwnedRoots = [".mutantkit", ".mutare"]

    /// True if `relativePath` — *project*-root-relative, which for a project
    /// nested inside a larger repository is not the same thing as the
    /// repository-root-relative path git reports; see `isToolOwned(
    /// repositoryRelativePath:projectPrefix:)` — lives under one of the
    /// tool-owned roots.
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
    ///
    /// `worktreeContentState` no longer produces quoted paths — it reads
    /// `-z` (NUL-separated) output from both git commands, which is never
    /// quoted, precisely so an awkward path arrives verbatim. This is kept
    /// because `isToolOwnedPath` is a public-to-the-module predicate whose
    /// contract has always been "a path as git might spell it", and
    /// unwrapping an unquoted path is a no-op.
    private static func unquotedGitPath(_ entry: String) -> String {
        guard entry.hasPrefix("\""), entry.hasSuffix("\""), entry.count >= 2 else { return entry }
        return String(entry.dropFirst().dropLast())
    }

    /// `run` without the trailing-whitespace trim. `-z` output is
    /// NUL-separated and NUL is not whitespace, so trimming would be
    /// harmless — but a path may legitimately *end* in a space or a newline,
    /// and trimming the last record's trailing bytes would silently rename
    /// it. Splitting on NUL is the only framing this output has.
    private static func runRaw(_ arguments: [String], in root: URL) async throws -> String {
        String(decoding: try await runBytes(arguments, in: root), as: UTF8.self)
    }

    private static func run(_ arguments: [String], in root: URL) async throws -> String {
        String(decoding: try await runBytes(arguments, in: root), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runBytes(_ arguments: [String], in root: URL) async throws -> Data {
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
        return result.standardOutput
    }
}
