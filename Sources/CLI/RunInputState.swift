import Foundation
import MutationExecution
import MutationModel

/// Everything a run's sandboxes are built from: the project worktree, where
/// the project sits in the sandbox, and every local package outside the
/// project that the sandbox copies.
///
/// Computed once per run, after the layout. The checkpoint fingerprint, the
/// result-cache digest and the coverage-cache digest all hash this one value
/// (`RunContextProbe.compute` and `.computeContextDigest` take it rather than
/// reading the worktree themselves), so none of them can see a different
/// set of inputs from the others.
struct RunInputState: Sendable, Equatable {
    /// `RunContextProbe.worktreeContentState` of the project root.
    let worktreeContentState: String
    /// `SandboxLayout.workspaceRelativePath`: the project's path inside each
    /// sandbox container, which reaches compiled paths.
    let workspaceRelativePath: String
    /// One entry per external root, sorted by `relativeIdentity`. Empty for
    /// a project with no local packages outside it.
    let externalPackageInputs: [ExternalPackageInput]

    /// Bumped whenever what this state covers changes, so a digest computed
    /// under an older scheme is never mistaken for one computed under this.
    static let closureVersion = "v1"

    /// The components every identity derived from this state folds in.
    var identityComponents: [String] {
        let externals = externalPackageInputs
            .map { "\($0.relativeIdentity):\($0.contentDigest)" }
            .joined(separator: ",")
        return [
            "inputClosure=\(Self.closureVersion)",
            "workspaceRelativePath=\(workspaceRelativePath)",
            "externalPackageInputs=\(externals)",
            "worktreeContentState=\(worktreeContentState)"
        ]
    }

    /// The state of `projectRoot` laid out as `layout`.
    ///
    /// `scratchRoots` are the run's sandbox scratch roots; the sandbox copy
    /// skips them, so the digest does too. `excludes` must be the excludes
    /// the run's `WorkspaceManager`s copy with.
    ///
    /// Throws when any input cannot be read. The caller then runs with no
    /// checkpoint resume and no cross-run cache: a partial digest could
    /// match a different set of inputs.
    static func compute(
        projectRoot: URL,
        layout: SandboxLayout,
        scratchRoots: [URL] = [],
        excludes: [String] = WorkspaceManager.defaultExcludes,
        processRunner: RunContextProbe.ProcessRunner = RunContextProbe.defaultProcessRunner
    ) async throws -> RunInputState {
        let worktree = try await RunContextProbe.worktreeContentState(in: projectRoot, processRunner: processRunner)
        return try RunInputState(
            worktreeContentState: worktree,
            workspaceRelativePath: layout.workspaceRelativePath,
            externalPackageInputs: externalPackageInputs(of: layout, scratchRoots: scratchRoots, excludes: excludes)
        )
    }

    /// The content digest of every external root in `layout`, in layout
    /// order (sorted by relative path).
    ///
    /// Each digest walks its root with `SandboxCopyWalk`, the enumeration
    /// the sandbox copy itself uses: the same excludes, the same
    /// scratch-root skip, symlinks recorded by target text. Unlike the git
    /// listing used for the project root, it covers files `.gitignore`
    /// excludes and needs no repository at all, so equal digests mean equal
    /// sandbox copies whether the package is in the project's repository,
    /// in another one, or in none.
    static func externalPackageInputs(
        of layout: SandboxLayout, scratchRoots: [URL], excludes: [String]
    ) throws -> [ExternalPackageInput] {
        try layout.externalRoots.map { root in
            let entries = try contentEntries(of: root.sourceRoot, scratchRoots: scratchRoots, excludes: excludes)
            return ExternalPackageInput(
                relativeIdentity: root.relativePath,
                contentDigest: ContentHash.of(entries.joined(separator: "\u{1F}"))
            )
        }
    }

    /// What one external root contributes, entry by entry, in walk order:
    /// `path=identity` for a file or symlink (`RunContextProbe
    /// .contentIdentity`), and `path/=directory` for a directory, since the
    /// copy recreates empty directories too.
    ///
    /// Throws `RunContextProbeError.unprovableWorktreeContent` for a root
    /// or directory that cannot be listed and for an entry that cannot be
    /// read: "unreadable" must never hash the same as "absent".
    static func contentEntries(of root: URL, scratchRoots: [URL], excludes: [String]) throws -> [String] {
        // Spelled exactly as `WorkspaceManager` spells its own scratch root
        // for the same skip.
        let skipping = Set(scratchRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        var entries: [String] = []
        do {
            try SandboxCopyWalk.walk(root: root, excludes: excludes, skippingCanonicalPaths: skipping) { entry in
                switch entry.kind {
                case .directory:
                    entries.append("\(entry.relativePath)/=directory")
                    return true
                case .file, .symbolicLink:
                    let identity = try RunContextProbe.contentIdentity(of: entry.url, path: entry.url.path)
                    entries.append("\(entry.relativePath)=\(identity)")
                    return false
                }
            }
        } catch let error as WorkspaceError {
            throw RunContextProbeError.unprovableWorktreeContent(path: root.path, reason: "\(error)")
        }
        return entries
    }
}
