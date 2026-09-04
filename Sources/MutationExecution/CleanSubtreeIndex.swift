import Foundation

/// A one-time classification of every directory under a project root as
/// "clean" -- neither it nor anything nested inside it, at any depth,
/// matches `WorkspaceManager.defaultExcludes` -- or not.
///
/// A clean directory is safe for a single whole-directory `clonefile(2)`
/// call in place of `WorkspaceManager.populate`'s existing per-file walk:
/// nothing inside it would ever have been skipped, so cloning it whole
/// reproduces the same content and relative layout the walk would have
/// produced -- the same files, at the same paths, with the same bytes and
/// symlink targets -- just in one syscall instead of one per file. It does
/// **not** reproduce identical POSIX permission bits on the directories
/// themselves: `clonefile` carries a source directory's real mode along,
/// while the walk's per-entry `createDirectory` calls always create a fresh
/// directory at the process's own default mode instead. A directory that is
/// *not* clean still gets the existing per-entry walk, unchanged -- this
/// index only ever adds a faster path for content the walk would have
/// copied in full anyway, it never changes what gets copied.
///
/// See `Research/isolated-build-reuse-2026-09/README.md`'s S2 section and
/// its follow-up (`git log`, "S2 follow-up: measure whole-directory
/// clone-then-delete on real projects, don't ship it") for why the simpler
/// "clone everything, then delete whatever the exclude list matches"
/// alternative was measured and rejected instead of built: deleting a
/// cloned `.build` or an ordinary, actively-committed `.git` costs more
/// than the clone saves, because `clonefile` has no bulk-delete
/// counterpart. This index sidesteps that failure mode entirely by never
/// cloning excluded content in the first place -- it only fast-paths
/// subtrees *proven*, by a real walk, to contain none.
///
/// Built once by `WorkspaceManager.cachedCleanSubtreeIndex()` and reused
/// across every sandbox one run creates -- see that method's own doc
/// comment for why a fresh classification per sandbox would defeat the
/// point, and `ExecutionSettings.cleanSubtreeCloning`'s doc comment for why
/// this stays behind an explicit opt-in flag rather than shipping
/// unconditionally.
///
/// A pure, `Sendable` value: nothing here holds a `FileManager` or touches
/// disk again once `build` returns, so sharing one instance across
/// concurrent `createSandbox` calls needs no locking of its own.
struct CleanSubtreeIndex: Sendable {
    /// Directories proven clean, keyed by the path relative to the root
    /// this index was built from -- exactly the same `relativePath` shape
    /// `WorkspaceManager.isExcluded` already checks patterns against, and
    /// the same shape `populate`'s own recursion accumulates, so a lookup
    /// here and a pattern match there can never silently disagree about
    /// which directory is being asked about.
    ///
    /// "" (the root itself) is never a member: `populate` never treats the
    /// root as a unit to clone whole, only its entries, so the root's own
    /// cleanliness is never a question this index needs to answer.
    private let cleanRelativePaths: Set<String>

    /// Whether the directory at `relativePath` (relative to the root this
    /// index was built from) was proven clean.
    func isClean(relativePath: String) -> Bool {
        cleanRelativePaths.contains(relativePath)
    }

    /// Walks `projectRoot` once, classifying every directory reachable from
    /// it and recording every clean one.
    ///
    /// Skips exactly what `populate` itself skips, in the same order, so
    /// the two can never disagree about what "reachable" means: an
    /// excluded entry is never descended into (`WorkspaceManager
    /// .isExcluded`, the same function `populate` calls), and neither is
    /// `scratchRoot` itself, which usually lives inside the project it is
    /// testing -- without that guard this walk would descend into every
    /// sandbox this run has already created while building the very index
    /// meant to speed sandbox creation up.
    ///
    /// Errors are swallowed, not thrown: an unreadable directory cannot be
    /// proven clean, so it (and everything above it) is classified dirty
    /// instead, falling back to the per-entry walk -- which will hit the
    /// same unreadable directory for real and raise a genuine
    /// `WorkspaceError.unreadable` at that point, exactly as it does today
    /// without this index at all. Building the index never fails, and
    /// never invents a success the real walk would not also have reached.
    static func build(
        projectRoot: URL,
        excludes: [String],
        scratchRootPath: String,
        fileManager: FileManager = .default
    ) -> CleanSubtreeIndex {
        var clean = Set<String>()
        _ = scanDirectory(
            at: projectRoot,
            relativePath: "",
            excludes: excludes,
            scratchRootPath: scratchRootPath,
            fileManager: fileManager,
            clean: &clean
        )
        return CleanSubtreeIndex(cleanRelativePaths: clean)
    }

    /// Returns whether `directory` -- already known by the caller not to be
    /// excluded itself -- is clean, and records every clean directory found
    /// while answering that, including `directory` itself when it
    /// qualifies.
    private static func scanDirectory(
        at directory: URL,
        relativePath: String,
        excludes: [String],
        scratchRootPath: String,
        fileManager: FileManager,
        clean: inout Set<String>
    ) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return false
        }

        var directoryIsClean = true
        for entry in entries {
            let name = entry.lastPathComponent
            let relative = relativePath.isEmpty ? name : relativePath + "/" + name

            // An excluded entry is proof *of* dirtiness, not exemption from
            // it: a whole-directory clone would include it, where the
            // per-entry walk (which checks this exact same condition,
            // `WorkspaceManager.isExcluded`) never would. It is also never
            // descended into here, matching `populate`'s own "skip before
            // it is ever listed, let alone recursed into" behaviour -- so
            // an excluded directory's own contents can never taint or
            // contribute a "clean" entry of their own; they simply never
            // get looked at.
            if WorkspaceManager.isExcluded(name: name, relativePath: relative, excludes: excludes) {
                directoryIsClean = false
                continue
            }

            // Same guard as `populate`'s own recursion: never descend into
            // the scratch root this manager writes sandboxes into -- and,
            // critically, treat its *parent* as dirty because of it, not
            // merely skip it silently. `populate` omits the scratch root
            // from its own output entirely (`continue`, no clone of any
            // kind), so a directory containing it is not something a
            // whole-directory `clonefile` of that directory could ever
            // reproduce correctly: `clonefile` has no concept of "clone
            // everything except this one entry", and would happily pull in
            // every sandbox this run has already created. Marking the
            // parent dirty forces the per-entry walk here too, which is
            // exactly what already omits the scratch root correctly today.
            if entry.resolvingSymlinksInPath().standardizedFileURL.path == scratchRootPath {
                directoryIsClean = false
                continue
            }

            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                // A symlink is always a leaf for this index, exactly as it
                // is for `populate` (`recreateSymbolicLink`, never
                // descended into): it neither taints its parent's
                // cleanliness -- a whole-directory clone reproduces an
                // internal symlink exactly as `recreateSymbolicLink` would,
                // confirmed empirically by the symlink tests in
                // `WorkspaceManagerCleanSubtreeCloningTests` -- nor is it
                // ever itself a candidate for the whole-subtree fast path:
                // `WorkspaceManager`'s per-entry dispatch checks
                // `isSymbolicLink` strictly before consulting this index, so
                // a symlinked entry is always recreated as a symlink
                // regardless of what this index records for it, and this
                // index deliberately records nothing for it at all.
                continue
            } else if values?.isDirectory == true {
                let childIsClean = scanDirectory(
                    at: entry,
                    relativePath: relative,
                    excludes: excludes,
                    scratchRootPath: scratchRootPath,
                    fileManager: fileManager,
                    clean: &clean
                )
                if childIsClean {
                    clean.insert(relative)
                } else {
                    directoryIsClean = false
                }
            }
            // A plain, non-excluded file contributes nothing to dirtiness.
        }
        return directoryIsClean
    }
}
