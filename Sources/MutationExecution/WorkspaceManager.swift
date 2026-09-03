import Darwin
import Foundation
import MutationModel

/// Something went wrong creating, populating or destroying a sandbox.
public enum WorkspaceError: Error, CustomStringConvertible {
    case invalidSandboxID(String)
    case sandboxOutsideScratchRoot(path: String, scratchRoot: String)
    case pathOutsideSandbox(path: String, sandbox: String)
    case unreadable(path: String, underlying: String)
    case unwritable(path: String, underlying: String)

    public var description: String {
        switch self {
        case let .invalidSandboxID(id):
            "\(String(reflecting: id)) is not a usable sandbox name."
        case let .sandboxOutsideScratchRoot(path, scratchRoot):
            "Refusing to delete \(path): it resolves outside the scratch root \(scratchRoot)."
        case let .pathOutsideSandbox(path, sandbox):
            "Refusing to touch \(path): it resolves outside the sandbox \(sandbox)."
        case let .unreadable(path, underlying):
            "Could not read \(path): \(underlying)"
        case let .unwritable(path, underlying):
            "Could not write \(path): \(underlying)"
        }
    }
}

/// Creates and destroys the throwaway project copies that mutants are built in.
///
/// A mutation is a destructive edit to a source file, and the user's working tree
/// is never where one gets made: a run that is killed halfway through must not be
/// able to leave mutated code behind. Every mutant therefore gets its own copy of
/// the project under the tool's scratch root, and the original tree is only ever
/// read.
///
/// Copies are made with `clonefile(2)` where the filesystem allows it. On APFS
/// that is copy-on-write, so a sandbox costs directory entries rather than a
/// duplicate of the tree, which is what makes one-sandbox-per-mutant affordable
/// at all.
///
/// `git worktree` would be the obvious alternative and is deliberately not used:
/// it materializes committed state, so it would silently test something other
/// than the code the user is looking at.
public actor WorkspaceManager {
    private let projectRoot: URL
    /// Canonical (symlink-resolved). Every deletion is checked against this.
    private let scratchRoot: URL
    private let excludes: [String]
    private let fileManager = FileManager.default
    private var cloneSupport: Bool?

    /// Directories that hold build output, VCS state or previous runs. Copying
    /// them is pure cost: the build regenerates them, and DerivedData alone can
    /// outweigh the source tree by an order of magnitude.
    ///
    /// Both tool-output roots are excluded: `.mutantkit` is current and
    /// `.mutare` is the prior tool name. A previous incident cloned a stale
    /// 15 GB `.mutare` into every sandbox because only the current name was
    /// listed here; keeping both prevents that from recurring for anyone whose
    /// tree still carries the old directory.
    public static let defaultExcludes = [
        ".git",
        ".build",
        "DerivedData",
        "Build",
        "Pods",
        "Carthage/Build",
        ".mutantkit",
        ".mutare",
        "*.xcresult",
        "*.log",
        "logs"
    ]

    public init(
        projectRoot: URL,
        scratchRoot: URL,
        excludes: [String] = WorkspaceManager.defaultExcludes
    ) throws {
        self.projectRoot = projectRoot.standardizedFileURL
        self.excludes = excludes

        // The scratch root must exist before it can be canonicalized: symlink
        // resolution only resolves the parts of a path that are really there,
        // and a half-resolved root would make the containment check below
        // compare two spellings of the same directory and reject them.
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        self.scratchRoot = scratchRoot.resolvingSymlinksInPath().standardizedFileURL

        // Best-effort, and unconditional: this runs whether or not the
        // caller ends up using `Configuration.execution.sharedModuleCache`
        // at all, so every process that ever constructs a `WorkspaceManager`
        // against a given scratch root -- `mutantkit run`, `reproduce`,
        // `dry-run`, `SchemataChunkBuildProbe` alike -- starts from a
        // provably empty shared module cache rather than one a previous
        // invocation (possibly under a different toolchain) left behind.
        // This is what keeps "the shared cache is stale from a prior run,
        // or was built by a compiler version that no longer matches"
        // outside this feature's own correctness surface entirely: there is
        // no cross-invocation reuse to reason about, because nothing is
        // *meant* to survive between invocations. "Best-effort" above is
        // literal, not decorative: `try?` swallows the removal's own error
        // rather than surfacing or logging it, so a failed wipe (permission
        // denied, a file busy from something else touching the same path)
        // is silently ignored, not merely unlikely. The directory is left
        // absent afterwards -- `-Xswiftc -module-cache-path` creates it
        // lazily on first use (confirmed empirically,
        // `Research/isolated-build-reuse-2026-09`), so there is nothing
        // useful to recreate here.
        //
        // This wipe is also unconditional in a second sense worth flagging
        // here, not just at `sharedModuleCache`'s own doc comment: it is
        // keyed on `scratchRoot` alone, which is stable (`<projectRoot>/
        // .mutantkit`) rather than per-run, and it races a concurrent
        // `WorkspaceManager` construction against the *same* project from a
        // *different* destination's run -- see
        // `ExecutionSettings.sharedModuleCache`'s doc comment for the full
        // shape of that limitation.
        try? FileManager.default.removeItem(
            at: self.scratchRoot.appendingPathComponent(Self.moduleCacheDirectoryName, isDirectory: true)
        )
    }

    // MARK: - Lifecycle

    /// Directory name for a sandbox: a fixed-width digest of `id`.
    ///
    /// The width is the point, and it is load-bearing for correctness rather
    /// than tidiness. The absolute build path reaches the compiled output — as
    /// `#file` strings and as constants that `__TEXT,__text` addresses — so the
    /// *length* of a sandbox's path changes the emitted code even when the
    /// source is byte-identical. Measured on this toolchain: identical sources
    /// built at two equal-length paths produce identical code, and at
    /// different-length paths produce different code.
    ///
    /// Activation evidence compares a mutant's compiled code against the
    /// baseline's. If the baseline sat at `…/baseline` and mutants at
    /// `…/mut_<16 hex>`, that comparison would report "differs" for every mutant
    /// purely because the paths differ in length — including for mutants that
    /// changed nothing. The phantom check would never fire and every mutant
    /// would carry a false proof of activation, which is worse than carrying
    /// none.
    ///
    /// Hashing rather than padding keeps the invariant true for *any* caller and
    /// any id, instead of resting on callers happening to pick equal-length
    /// names. It is deterministic, so a sandbox for the same id is always at the
    /// same path and `reproduce` stays reproducible.
    /// Public because the equal-length guarantee is part of this type's contract,
    /// not an implementation detail: activation evidence depends on it, so it is
    /// something callers may assert against.
    public static func directoryName(for id: String) -> String {
        "sbx_" + ContentHash.shortDigest(of: id, length: 20)
    }

    /// Fixed name for the shared, run-scoped Clang/Swift module cache
    /// directory every sandbox under one scratch root may point its build
    /// at -- see `Configuration.execution.sharedModuleCache`. A literal
    /// constant, not a hashed digest like `directoryName(for:)` above: there
    /// is at most one of these per scratch root, so nothing about it needs
    /// to be unique or unguessable, and a stable, greppable name makes it
    /// easy to find on disk while debugging. Dot-prefixed so it reads
    /// unmistakably as this manager's own infrastructure, never mistaken
    /// for a mutant sandbox (`sbx_...`) or a products clone (`prd_...`).
    public static let moduleCacheDirectoryName = ".module-cache"

    /// Where the shared module cache lives for a sandbox this manager
    /// created -- one path component up from the sandbox itself, i.e.
    /// directly under this manager's own `scratchRoot`.
    ///
    /// A `BuildAdapter` never sees `scratchRoot` directly, only the sandbox
    /// URL it is asked to build in -- this lets it recover the shared
    /// cache's location anyway, without threading a second path through
    /// every adapter-construction call site. Safe because `createSandbox`'s
    /// own contract (see its doc comment) guarantees every sandbox this
    /// type ever hands out is exactly one path component below its scratch
    /// root, always -- so `sandbox`'s parent directory *is* that scratch
    /// root, whichever `WorkspaceManager` produced it.
    public nonisolated static func moduleCachePath(forSandbox sandbox: URL) -> URL {
        sandbox.deletingLastPathComponent().appendingPathComponent(moduleCacheDirectoryName, isDirectory: true)
    }

    /// Builds a fresh sandbox for `id` and returns its canonical location.
    public func createSandbox(id: String) async throws -> URL {
        // `id` reaches us from a plan file, which is data we did not write. It is
        // hashed below rather than used as a path component, which already
        // neutralizes separators and `..` — but a malformed id is still a bug
        // worth reporting rather than quietly hashing into a valid-looking name.
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WorkspaceError.invalidSandboxID(id)
        }

        let sandbox = scratchRoot
            .appendingPathComponent(Self.directoryName(for: id))
            .standardizedFileURL
        guard sandbox.path.hasPrefix(scratchRoot.path + "/") else {
            throw WorkspaceError.sandboxOutsideScratchRoot(path: sandbox.path, scratchRoot: scratchRoot.path)
        }

        do {
            try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceError.unwritable(path: sandbox.path, underlying: error.localizedDescription)
        }

        try populate(from: projectRoot, to: sandbox, relativePath: "")
        return sandbox
    }

    /// Deletes a sandbox, refusing anything that is not really inside the scratch root.
    ///
    /// This runs against a path that has been through a plan file, a build
    /// adapter and a filesystem, so it re-derives the answer instead of trusting
    /// it: the path is canonicalized first, which is what catches a sandbox that
    /// is a symlink to somewhere that matters. A recursive delete gets exactly
    /// one chance to be wrong.
    public func destroySandbox(at url: URL) async throws {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path != scratchRoot.path, canonical.path.hasPrefix(scratchRoot.path + "/") else {
            throw WorkspaceError.sandboxOutsideScratchRoot(path: canonical.path, scratchRoot: scratchRoot.path)
        }
        guard fileManager.fileExists(atPath: canonical.path) else { return }

        do {
            try fileManager.removeItem(at: canonical)
        } catch {
            throw WorkspaceError.unwritable(path: canonical.path, underlying: error.localizedDescription)
        }
    }

    /// Overwrites one file inside `sandbox` with the pristine copy from
    /// `projectRoot` — the revert half of a persistent, reused sandbox.
    ///
    /// Only for sandboxes meant to survive across multiple mutants (see
    /// `Configuration.execution.incrementalBuild`): a mutation is applied
    /// in place, built and tested, and this restores exactly the one file
    /// it touched before the next mutation is applied, so the sandbox is
    /// byte-identical to a fresh clone without paying to make a fresh one.
    /// The single-mutation-per-file invariant `MutationApplication` relies
    /// on means one file is always enough; nothing else in the sandbox is
    /// ever written to.
    public func restoreFile(relativePath: String, in sandbox: URL) async throws {
        let source = try resolveSourceURL(in: projectRoot, relativePath: relativePath)
        let destination = try resolveSourceURL(in: sandbox, relativePath: relativePath)
        try materialize(source, at: destination)
    }

    /// Directory name for a cloned build-products landing spot: the same
    /// fixed-width digest shape as `directoryName(for:)` (see its doc comment
    /// for why the width matters), but under its own prefix so it can never
    /// collide with a sandbox's own directory.
    public static func productsCloneDirectoryName(for id: String) -> String {
        "prd_" + ContentHash.shortDigest(of: id, length: 20)
    }

    /// Clones a just-built products directory out to its own, uniquely
    /// identified location, independent of the sandbox that built it.
    ///
    /// Only useful alongside a persistent, reused sandbox (see
    /// `Configuration.execution.incrementalBuild`): the whole point of
    /// reusing a sandbox is that its `DerivedData` gets overwritten in place
    /// by the very next mutant's build, which would corrupt this mutant's
    /// artifact if testing it is deferred (see `Configuration.execution
    /// .testBatchSize`). Cloning it out first lets the worker move on to its
    /// next mutant immediately, while this clone survives independently
    /// until it is tested and destroyed.
    ///
    /// `id` must be unique per artifact being kept alive — a mutation ID,
    /// never a worker ID: the worker's own sandbox path has to stay stable
    /// across mutants (that is what makes it incremental), while every
    /// clone must not. Same validation as `createSandbox`: `id` is data from
    /// a plan file, hashed rather than used as a path component.
    ///
    /// Clones the whole directory in one call rather than file-by-file:
    /// `clonefile(2)` recursively clones a directory hierarchy atomically,
    /// and nothing downstream of a build (`XCTestRunLocator`, a `.xctestrun`'s
    /// own `__TESTROOT__`-relative paths) ever looks outside this directory —
    /// see `XcodeBuildAdapter.productsDirectory(in:)` and `XCTestRunLocator`.
    public func cloneProducts(from productsDirectory: URL, id: String) async throws -> URL {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WorkspaceError.invalidSandboxID(id)
        }

        let destination = scratchRoot
            .appendingPathComponent(Self.productsCloneDirectoryName(for: id))
            .standardizedFileURL
        guard destination.path.hasPrefix(scratchRoot.path + "/") else {
            throw WorkspaceError.sandboxOutsideScratchRoot(path: destination.path, scratchRoot: scratchRoot.path)
        }

        // `clone(_:to:)` below uses `CLONE_NOFOLLOW` so a symlink *inside* a
        // cloned tree is recreated as a symlink, never dereferenced into a
        // copy (see that function's own doc comment) — correct for
        // `populate`'s recursive walk, but wrong here: `productsDirectory`
        // itself, the top-level source, is routinely a symlink (SwiftPM's
        // own `.build/debug`, always a relative symlink to
        // `.build/<triple>/debug`). Cloning that top-level symlink with
        // `CLONE_NOFOLLOW` would recreate the same *relative* link text at
        // `destination` — pointing at `destination/../<triple>/debug`, which
        // does not exist, since only the products directory is cloned out,
        // never its siblings. Resolving here, once, before either the clone
        // or its existence check, makes `destination` a real, independent
        // directory whatever `productsDirectory` itself was.
        let resolvedProductsDirectory = productsDirectory.resolvingSymlinksInPath()

        guard fileManager.fileExists(atPath: resolvedProductsDirectory.path) else {
            throw WorkspaceError.unreadable(
                path: resolvedProductsDirectory.path,
                underlying: "no such directory"
            )
        }

        // clonefile refuses an existing destination — matches `materialize`'s
        // own removal-before-clone, needed here so re-cloning under a reused
        // `id` (a worker's next mutant landing on the same digest, once the
        // prior clone has already been destroyed) overwrites cleanly.
        try? fileManager.removeItem(at: destination)

        if supportsAPFSClone(), clone(resolvedProductsDirectory, to: destination) {
            return destination
        }

        do {
            try fileManager.copyItem(at: resolvedProductsDirectory, to: destination)
        } catch {
            throw WorkspaceError.unwritable(path: destination.path, underlying: error.localizedDescription)
        }
        return destination
    }

    /// Locates a plan-relative source file inside a sandbox.
    ///
    /// `MutationApplication` writes wherever it is pointed and says so; this is
    /// the layer that owns the guarantee it relies on. A plan is data, and data
    /// does not get to name `../../../etc/passwd` — nor to reach outside through
    /// a symlink that happens to live in the tree we copied.
    public nonisolated func resolveSourceURL(in sandbox: URL, relativePath: String) throws -> URL {
        let root = sandbox.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw WorkspaceError.pathOutsideSandbox(path: candidate.path, sandbox: root.path)
        }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw WorkspaceError.pathOutsideSandbox(path: resolved.path, sandbox: root.path)
        }
        return resolved
    }

    // MARK: - Copy strategy

    /// Whether this filesystem can clone, determined by cloning rather than by
    /// asking: the answer depends on the volume, and a volume that reports APFS
    /// can still refuse (a firmlink crossing, a mounted image, a case-sensitive
    /// overlay). The only reliable probe is the syscall itself.
    public func supportsAPFSClone() -> Bool {
        if let known = cloneSupport { return known }

        let source = scratchRoot.appendingPathComponent(".mutantkit-clone-probe")
        let destination = scratchRoot.appendingPathComponent(".mutantkit-clone-probe-clone")
        try? fileManager.removeItem(at: source)
        try? fileManager.removeItem(at: destination)
        defer {
            try? fileManager.removeItem(at: source)
            try? fileManager.removeItem(at: destination)
        }

        guard fileManager.createFile(atPath: source.path, contents: Data("probe".utf8)) else {
            cloneSupport = false
            return false
        }

        let supported = clone(source, to: destination)
        cloneSupport = supported
        return supported
    }

    /// Copies one directory level, recursing rather than cloning the tree whole.
    ///
    /// `clonefile` would happily clone `projectRoot` in a single call, but the
    /// exclusions have to be honoured *before* the entries exist, not deleted
    /// afterwards — unlinking a cloned DerivedData costs more than never cloning
    /// it. Recursing keeps the exclusions exact; each file is still a clone, so
    /// no file data is duplicated either way.
    private func populate(from source: URL, to destination: URL, relativePath: String) throws {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw WorkspaceError.unreadable(path: source.path, underlying: error.localizedDescription)
        }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            let relative = relativePath.isEmpty ? name : relativePath + "/" + name
            if isExcluded(name: name, relativePath: relative) { continue }

            // The scratch root usually lives inside the project it is testing;
            // descending into it would copy every other sandbox into this one.
            if entry.resolvingSymlinksInPath().standardizedFileURL.path == scratchRoot.path { continue }

            let target = destination.appendingPathComponent(name)
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

            // Symlinks are recreated, never followed: following one turns a link
            // into a copy of whatever it points at, which is both wrong and
            // unbounded when it points at a parent.
            if values?.isSymbolicLink == true {
                try recreateSymbolicLink(at: entry, to: target)
            } else if values?.isDirectory == true {
                do {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } catch {
                    throw WorkspaceError.unwritable(path: target.path, underlying: error.localizedDescription)
                }
                try populate(from: entry, to: target, relativePath: relative)
            } else {
                try materialize(entry, at: target)
            }
        }
    }

    /// Puts `source`'s contents at `destination` by the cheapest means available.
    private func materialize(_ source: URL, at destination: URL) throws {
        if supportsAPFSClone() {
            // clonefile refuses a destination that already exists.
            try? fileManager.removeItem(at: destination)
            if clone(source, to: destination) { return }
        }

        // Without cloning, the next best thing is not copying: an identical file
        // already at the destination is one a re-populated sandbox can keep.
        if isUnchanged(source, at: destination) { return }

        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw WorkspaceError.unwritable(path: destination.path, underlying: error.localizedDescription)
        }
    }

    private func clone(_ source: URL, to destination: URL) -> Bool {
        // CLONE_NOFOLLOW keeps a symlink a symlink rather than cloning its target.
        clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0
    }

    private func isUnchanged(_ source: URL, at destination: URL) -> Bool {
        guard let sourceAttributes = try? fileManager.attributesOfItem(atPath: source.path),
              let destinationAttributes = try? fileManager.attributesOfItem(atPath: destination.path),
              let sourceSize = sourceAttributes[.size] as? Int,
              let destinationSize = destinationAttributes[.size] as? Int,
              sourceSize == destinationSize,
              let sourceDate = sourceAttributes[.modificationDate] as? Date,
              let destinationDate = destinationAttributes[.modificationDate] as? Date
        else { return false }
        return sourceDate == destinationDate
    }

    private func recreateSymbolicLink(at source: URL, to destination: URL) throws {
        let target: String
        do {
            target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
        } catch {
            throw WorkspaceError.unreadable(path: source.path, underlying: error.localizedDescription)
        }

        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        } catch {
            throw WorkspaceError.unwritable(path: destination.path, underlying: error.localizedDescription)
        }
    }

    private func isExcluded(name: String, relativePath: String) -> Bool {
        excludes.contains { pattern in
            fnmatch(pattern, name, 0) == 0 || fnmatch(pattern, relativePath, 0) == 0
        }
    }
}
