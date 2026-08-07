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

        guard fileManager.fileExists(atPath: productsDirectory.path) else {
            throw WorkspaceError.unreadable(
                path: productsDirectory.path,
                underlying: "no such directory"
            )
        }

        // clonefile refuses an existing destination — matches `materialize`'s
        // own removal-before-clone, needed here so re-cloning under a reused
        // `id` (a worker's next mutant landing on the same digest, once the
        // prior clone has already been destroyed) overwrites cleanly.
        try? fileManager.removeItem(at: destination)

        if supportsAPFSClone(), clone(productsDirectory, to: destination) {
            return destination
        }

        do {
            try fileManager.copyItem(at: productsDirectory, to: destination)
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
