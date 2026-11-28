import Darwin
import Foundation
import MutationModel

/// Something went wrong creating, populating or destroying a sandbox.
public enum WorkspaceError: Error, CustomStringConvertible {
    case invalidSandboxID(String)
    case sandboxOutsideScratchRoot(path: String, scratchRoot: String)
    case notASandboxContainer(path: String, scratchRoot: String)
    case notAProductsClone(path: String, scratchRoot: String)
    case pathOutsideSandbox(path: String, sandbox: String)
    case unreadable(path: String, underlying: String)
    case unwritable(path: String, underlying: String)
    /// The first sandbox's manifests load a local package from outside it.
    case containment(SandboxContainmentError)

    public var description: String {
        switch self {
        case let .invalidSandboxID(id):
            "\(String(reflecting: id)) is not a usable sandbox name."
        case let .sandboxOutsideScratchRoot(path, scratchRoot):
            "Refusing to delete \(path): it resolves outside the scratch root \(scratchRoot)."
        case let .notASandboxContainer(path, scratchRoot):
            "Refusing to delete \(path): it is not a sandbox directly inside the scratch root \(scratchRoot)."
        case let .notAProductsClone(path, scratchRoot):
            "Refusing to delete \(path): it is not a products clone directly inside the scratch root \(scratchRoot)."
        case let .pathOutsideSandbox(path, sandbox):
            "Refusing to touch \(path): it resolves outside the sandbox \(sandbox)."
        case let .unreadable(path, underlying):
            "Could not read \(path): \(underlying)"
        case let .unwritable(path, underlying):
            "Could not write \(path): \(underlying)"
        case let .containment(error):
            error.description
        }
    }
}

/// Creates and destroys the throwaway project copies that mutants are built in.
///
/// A mutation is a destructive edit to a source file, and the user's working tree
/// is never where one gets made: a run that is killed halfway through must not be
/// able to leave mutated code behind. Every mutant therefore gets its own copy of
/// the project under the tool's scratch root, and `WorkspaceManager` itself —
/// every method in this file — only ever reads `projectRoot`, never writes to it.
/// The same holds for the local packages outside the project that the
/// layout names (see `SandboxLayout`): each sandbox is a container holding a
/// copy of every one of them beside the project copy, at their original
/// relative positions, so relative package paths resolve inside it.
///
/// That is a narrower claim than "the original tree is only ever read by
/// this tool," which does not hold without qualification: with
/// `Configuration.execution.retestKilledMutants` on for a SwiftPM project,
/// `RunCommand`'s own dependency-resolution preflight
/// (`PackageManifestConfirmationRetesting
/// .resolveDependenciesForConfirmationRetest`) deliberately runs `swift
/// package resolve` against `projectRoot` once, up front, and logs doing
/// so — a real, intentional, narrowly-scoped exception to keep a later
/// confirmation retest from performing that same first-ever resolution
/// unexpectedly, mid-run, instead (see that method's own doc comment for
/// why). `WorkspaceManager` has no part in that and remains read-only.
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
    /// Where the project and its local packages sit in every sandbox.
    public nonisolated let layout: SandboxLayout
    private var projectRoot: URL {
        layout.projectRoot
    }

    /// Canonical (symlink-resolved). Every deletion is checked against this.
    let scratchRoot: URL
    let excludes: [String]
    let fileManager = FileManager.default
    private var cloneSupport: Bool?
    /// See `ExecutionSettings.cleanSubtreeCloning`'s doc comment for what
    /// this turns on and why it defaults off.
    private let cleanSubtreeCloning: Bool
    /// Built lazily, on the first `createSandbox` that needs it, and cached
    /// for the rest of this instance's lifetime -- see
    /// `cachedCleanSubtreeIndex()`.
    private var cleanSubtreeIndex: CleanSubtreeIndex?
    /// Run on the first sandbox this instance creates; see
    /// `proveContainmentOnce(_:)`.
    private let containmentProof: (any SandboxContainmentProving)?
    /// Called once, after `containmentProof` has accepted the layout and
    /// before the first sandbox is returned (or, with no proof, when the first
    /// sandbox is created). Never called on a refusal.
    private let onContainmentProven: (@Sendable () -> Void)?
    /// The one evaluation of `containmentProof`, shared by every sandbox
    /// created while it runs and remembered, success or failure, after.
    private var containmentProofRun: Task<Void, any Error>?
    private var announcedWithoutProof = false
    /// What every sandbox of this manager is built from. Given at init, or
    /// captured once by the first sandbox; immutable afterwards.
    private var inputClosure: SandboxInputClosure?
    /// The verified, pristine copy of `inputClosure` under the scratch root,
    /// built (and every byte proven) once by the first sandbox. Every later
    /// sandbox and `restoreFile` clones from it, so the live tree is read and
    /// hashed once per manager, not once per sandbox, and a source edited
    /// afterwards cannot reach any sandbox.
    var staged: StagedInputs?
    /// Root-level resolution-state names the previous materialization of the
    /// sandbox being reused took from its closure (see `retainedOnReuse`).
    var previouslyFromClosure: Set<String> = []
    /// This manager's own staging directory under the scratch root: unique per
    /// manager, so no other manager (or run) ever builds over or deletes it.
    /// Removed when the manager goes away.
    nonisolated let stagingRoot: URL

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

    /// A manager whose sandboxes are copies of `projectRoot` alone.
    public init(
        projectRoot: URL,
        scratchRoot: URL,
        excludes: [String] = WorkspaceManager.defaultExcludes,
        cleanSubtreeCloning: Bool = false
    ) throws {
        try self.init(
            layout: .projectOnly(projectRoot),
            scratchRoot: scratchRoot,
            excludes: excludes,
            cleanSubtreeCloning: cleanSubtreeCloning
        )
    }

    /// A manager whose sandboxes reproduce `layout`: the project and every
    /// external local package at their original relative positions.
    ///
    /// `excludes` applies to every root alike, matched against paths
    /// relative to that root.
    ///
    /// `containmentProof`, when given, runs on the first sandbox before
    /// `createSandbox` returns it; see `proveContainmentOnce(_:)`.
    public init(
        layout: SandboxLayout,
        scratchRoot: URL,
        excludes: [String] = WorkspaceManager.defaultExcludes,
        cleanSubtreeCloning: Bool = false,
        containmentProof: (any SandboxContainmentProving)? = nil,
        onContainmentProven: (@Sendable () -> Void)? = nil,
        inputClosure: SandboxInputClosure? = nil
    ) throws {
        self.layout = layout
        self.inputClosure = inputClosure
        self.containmentProof = containmentProof
        self.onContainmentProven = onContainmentProven
        self.excludes = excludes
        self.cleanSubtreeCloning = cleanSubtreeCloning

        // The scratch root must exist before it can be canonicalized: symlink
        // resolution only resolves the parts of a path that are really there,
        // and a half-resolved root would make the containment check below
        // compare two spellings of the same directory and reject them.
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        self.scratchRoot = scratchRoot.resolvingSymlinksInPath().standardizedFileURL
        stagingRoot = self.scratchRoot
            .appendingPathComponent("\(Self.stagingDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)

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
        // lazily on first use (confirmed empirically), so there is
        // nothing useful to recreate here.
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

    /// The staged copy of the inputs belongs to this manager and goes with it.
    deinit {
        try? removeStaging(stagingRoot)
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

    /// `moduleCacheDirectoryName` above, namespaced by a real toolchain
    /// fingerprint (see `SharedModuleCacheFingerprint`) -- the real,
    /// on-disk directory name `moduleCachePath(underScratchRoot:fingerprint:)`
    /// resolves to. A second, independent layer of protection on top of
    /// `init`'s own wipe-at-construction of the plain, unnamespaced
    /// directory above: that wipe is `try?`-guarded best-effort and only
    /// ever runs once, so it cannot by itself guarantee a toolchain change
    /// (mid-session, or between two invocations that reuse a path) can
    /// never collide with an old cache's own contents -- namespacing by
    /// fingerprint makes that guarantee structural instead. The plain
    /// directory name is still wiped, unchanged, purely for backward-
    /// compatible cleanup of a cache directory an older, pre-fingerprint
    /// version of this tool may have left behind; nothing writes there
    /// going forward.
    ///
    /// `fingerprint` is a short digest a caller already computed (see
    /// `SharedModuleCacheFingerprint.digest`), never re-derived here: this
    /// function does no probing of its own and stays exactly as easy to
    /// call from a pure, synchronous, sandbox-path-only context as
    /// `directoryName(for:)`/`productsCloneDirectoryName(for:)` above.
    public static func moduleCacheDirectoryName(forFingerprint fingerprint: String) -> String {
        ".module-cache-" + fingerprint
    }

    /// Where the fingerprint-namespaced shared module cache lives under
    /// `scratchRoot`.
    ///
    /// The scratch root is always given, never guessed from a sandbox path:
    /// a workspace can sit several components inside its container (see
    /// `SandboxLayout`), so a build adapter recovers it with
    /// `SandboxLayout.scratchRoot(ofWorkspace:)`, which fails loudly for a
    /// path that is not a sandbox workspace. `mutantkit doctor` previews the
    /// path from the scratch root a real run would use.
    public nonisolated static func moduleCachePath(underScratchRoot scratchRoot: URL, fingerprint: String) -> URL {
        scratchRoot.appendingPathComponent(moduleCacheDirectoryName(forFingerprint: fingerprint), isDirectory: true)
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
    public func restoreFile(relativePath: String, in sandbox: Sandbox) async throws {
        let closure = try capturedClosure()
        guard let entry = closure.project.entry(at: relativePath), entry.kind == .file else {
            throw SandboxInputClosureError.notInClosure(path: relativePath)
        }
        let staged = try stagedRoot(for: closure.project, closure: closure)
        let source = try Self.resolveSourceURL(in: staged, relativePath: relativePath)
        let destination = try resolveSourceURL(in: sandbox, relativePath: relativePath)
        // One file: cheap enough to prove against the closure, not just its stat.
        try verifyStaged(source, against: entry)
        try materialize(source, at: destination, entry: entry, proving: false)
    }

    /// The closure every sandbox of this manager is built from, captured on
    /// first use when none was given.
    private func capturedClosure() throws -> SandboxInputClosure {
        if let inputClosure { return inputClosure }
        let captured = try SandboxInputClosure.capture(
            layout: layout, excludes: excludes, scratchRoots: [scratchRoot]
        )
        inputClosure = captured
        return captured
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
    /// see `XcodeBuildDriver`'s own `productsDirectory(in:)` and `XCTestRunLocator`.
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

        if supportsAPFSClone(), Self.clone(resolvedProductsDirectory, to: destination) {
            return destination
        }

        do {
            try fileManager.copyItem(at: resolvedProductsDirectory, to: destination)
        } catch {
            throw WorkspaceError.unwritable(path: destination.path, underlying: error.localizedDescription)
        }
        return destination
    }

    /// Clones a just-built products directory the same way `cloneProducts`
    /// does, but nested under `<destination>/<triple>/<configuration>/`
    /// instead of flattened directly into `destination` — the shape
    /// `SwiftPackageMacOSAdapter`'s confirmation retest needs `swift test
    /// --scratch-path` to find pre-built products under.
    ///
    /// A sibling function, not a parameter on `cloneProducts`: that
    /// function's flat shape is load-bearing for its other caller
    /// (`Configuration.execution.testBatchSize`'s batching path, both the
    /// plain and the pipelined-incremental variants — see `MutationRunner
    /// .relocating`) and for `XcodeBuildAdapter`'s own confirmation retest,
    /// whose `.xctestrun`'s `__TESTROOT__`-relative paths need the flat
    /// directory unchanged (see `cloneProducts`'s own doc comment). Nesting
    /// it for every caller would break both; this function exists so only
    /// the one caller that actually needs the nested shape
    /// (`MutationConfirmationCoordinator.confirmKill`, for an adapter that
    /// conforms to `PackageManifestConfirmationRetesting`) pays for it.
    ///
    /// Confirmed empirically against a real toolchain: `swift test
    /// --scratch-path X` does not accept a flat products directory at
    /// all — it computes its own triple/configuration path internally
    /// and looks for pre-built products at exactly
    /// `X/<triple>/<configuration>/`, failing with a `dlopen` "no such
    /// file" if that nesting is not there, regardless of what `X`
    /// itself otherwise contains.
    ///
    /// The nested location is the resolved products directory's path relative
    /// to the scratch directory that holds it (`productsDirectory`'s parent,
    /// which is where SwiftPM puts its `debug` symlink) — the same value
    /// SwiftPM itself computed when it built these products. That is
    /// `<triple>/<configuration>` for the classic layout and
    /// `out/Products/<Configuration>` for the Swift 6.4 layout; nothing about
    /// either shape is hardcoded, so it stays correct across architectures,
    /// cross-compilation destinations, configurations and layouts.
    public func cloneProductsForConfirmation(from productsDirectory: URL, id: String) async throws -> URL {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WorkspaceError.invalidSandboxID(id)
        }

        let destination = scratchRoot
            .appendingPathComponent(Self.productsCloneDirectoryName(for: id))
            .standardizedFileURL
        guard destination.path.hasPrefix(scratchRoot.path + "/") else {
            throw WorkspaceError.sandboxOutsideScratchRoot(path: destination.path, scratchRoot: scratchRoot.path)
        }

        // Resolved for the same reason `cloneProducts` resolves it — see
        // that function's own doc comment: `productsDirectory` itself is
        // routinely a relative symlink (SwiftPM's own `.build/debug`), and
        // this is also where `<triple>`/`<configuration>` are read from, so
        // resolution has to happen before anything else uses this path.
        let resolvedProductsDirectory = productsDirectory.resolvingSymlinksInPath()

        guard fileManager.fileExists(atPath: resolvedProductsDirectory.path) else {
            throw WorkspaceError.unreadable(
                path: resolvedProductsDirectory.path,
                underlying: "no such directory"
            )
        }

        let nestedDestination = Self.nestedProductsDestination(
            under: destination, productsDirectory: productsDirectory, resolved: resolvedProductsDirectory
        )

        // Same reasoning as `cloneProducts`: refuses an existing
        // destination, so a stale prior clone under a reused `id` is
        // discarded wholesale rather than reconciled file-by-file.
        try? fileManager.removeItem(at: destination)

        do {
            // Only the `<triple>` level, not `nestedDestination` itself:
            // `clonefile`/`copyItem` both refuse an existing destination,
            // matching `cloneProducts`'s own contract.
            try fileManager.createDirectory(
                at: nestedDestination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            throw WorkspaceError.unwritable(path: nestedDestination.path, underlying: error.localizedDescription)
        }

        if supportsAPFSClone(), Self.clone(resolvedProductsDirectory, to: nestedDestination) {
            return destination
        }

        do {
            try fileManager.copyItem(at: resolvedProductsDirectory, to: nestedDestination)
        } catch {
            throw WorkspaceError.unwritable(path: nestedDestination.path, underlying: error.localizedDescription)
        }
        return destination
    }

    /// Clones a just-built products directory for a confirmation retest,
    /// choosing `cloneProducts`'s flat shape or `cloneProductsForConfirmation`'s
    /// nested `<triple>/<configuration>` shape depending on whether `adapter`
    /// conforms to `PackageManifestConfirmationRetesting` — the one decision
    /// `MutationRunner.establishConfirmationSandbox` and
    /// `MutationConfirmationCoordinator.confirmTimeout`'s own inner retest
    /// both need to make identically, factored out here so it cannot drift
    /// between the two call sites.
    ///
    /// Resolved via `packageManifestConfirmationRetesting(for:)`, never a
    /// bare `adapter is any PackageManifestConfirmationRetesting` — the
    /// latter only ever sees `adapter`'s own outermost declared
    /// conformances, so it fails silently for a `TestAdapterWrapping`
    /// wrapper (`PrioritizingTestAdapter`) around a genuinely-conforming
    /// SwiftPM adapter and this method would then produce the flat shape —
    /// wrong for `MutationConfirmationCoordinator.confirmKill`'s own
    /// identically-resolved dispatch, which would still correctly pick the
    /// manifest-aware retest path and hand it a flat clone `swift test
    /// --scratch-path` cannot use. Sharing the one resolution function is
    /// what keeps the sandbox's shape and the retest's dispatch from ever
    /// disagreeing.
    public func cloneProductsForConfirmationRetest(
        from productsDirectory: URL, id: String, for adapter: any TestAdapter
    ) async throws -> URL {
        try await packageManifestConfirmationRetesting(for: adapter) != nil
            ? cloneProductsForConfirmation(from: productsDirectory, id: id)
            : cloneProducts(from: productsDirectory, id: id)
    }

    /// Locates a plan-relative source file inside a sandbox.
    ///
    /// `MutationApplication` writes wherever it is pointed and says so; this is
    /// the layer that owns the guarantee it relies on. A plan is data, and data
    /// does not get to name `../../../etc/passwd` — nor to reach outside through
    /// a symlink that happens to live in the tree we copied.
    ///
    /// Resolved against the sandbox's workspace: plan paths are
    /// project-relative, so a local package copied beside the project can
    /// never be named, and so never mutated.
    public nonisolated func resolveSourceURL(in sandbox: Sandbox, relativePath: String) throws -> URL {
        try Self.resolveSourceURL(in: sandbox.workspaceRoot, relativePath: relativePath)
    }

    private nonisolated static func resolveSourceURL(in directory: URL, relativePath: String) throws -> URL {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
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
        let supported = Self.probeAPFSCloneSupport(at: scratchRoot, fileManager: fileManager)
        cloneSupport = supported
        return supported
    }

    /// The real `clonefile(2)` probe `supportsAPFSClone()` runs against
    /// this manager's own `scratchRoot`, pulled out as a reusable,
    /// side-effect-scoped-to-`directory` function so a caller with no
    /// `WorkspaceManager` instance -- `mutantkit doctor`'s module-cache
    /// diagnostic, in particular -- can ask the identical, real question
    /// about an arbitrary directory. Deliberately not routed through a
    /// throwaway `WorkspaceManager` instead: construction has its own side
    /// effects (creating the scratch root, wiping any pre-existing shared
    /// module cache there -- see `init`'s own doc comment) that a
    /// read-only diagnostic has no business triggering.
    public nonisolated static func probeAPFSCloneSupport(at directory: URL, fileManager: FileManager = .default) -> Bool {
        let source = directory.appendingPathComponent(".mutantkit-clone-probe")
        let destination = directory.appendingPathComponent(".mutantkit-clone-probe-clone")
        try? fileManager.removeItem(at: source)
        try? fileManager.removeItem(at: destination)
        defer {
            try? fileManager.removeItem(at: source)
            try? fileManager.removeItem(at: destination)
        }

        guard fileManager.createFile(atPath: source.path, contents: Data("probe".utf8)) else { return false }
        return clone(source, to: destination)
    }

    /// Copies `source` entry by entry, following `SandboxCopyWalk`, rather
    /// than cloning the tree whole. The run fingerprint hashes local packages
    /// outside the project through the same walk.
    ///
    /// `clonefile` would happily clone `projectRoot` in a single call, but the
    /// exclusions have to be honoured *before* the entries exist, not deleted
    /// afterwards — unlinking a cloned DerivedData costs more than never cloning
    /// it. Recursing keeps the exclusions exact; each file is still a clone, so
    /// no file data is duplicated either way.
    ///
    /// When `cleanSubtreeCloning` is on, a directory entry the clean-subtree
    /// index has *proven* contains no excluded content anywhere inside it
    /// skips this recursion entirely in favour of one whole-directory clone
    /// (`materializeWholeSubtree`) — see `CleanSubtreeIndex`'s own doc
    /// comment. Every other entry — dirty directories, files, symlinks —
    /// takes exactly the path it always has. Only the project root may use
    /// the index (`usesCleanSubtreeIndex`), which is keyed on its paths.
    /// Materializes `root` at `destination` from the closure's entries, not
    /// from a fresh walk: every file is checked against the identity recorded
    /// at capture, and anything below `destination` that the closure does not
    /// contain (and no exclude protects) is removed.
    func populate(
        _ root: SandboxInputClosure.Root, from base: URL, to destination: URL,
        usesCleanSubtreeIndex: Bool, proving: Bool
    ) throws {
        var clonedWhole: String?
        var clonedDirs: [String] = []
        var modes = DirectoryModes()
        for entry in root.entries {
            let target = destination.appendingPathComponent(entry.relativePath)
            if let prefix = clonedWhole {
                if entry.relativePath.hasPrefix(prefix) {
                    // Cloned with its directory: only the bytes need proving.
                    if proving { try verifyClonedDescendant(entry, at: target) }
                    continue
                }
                clonedWhole = nil
            }
            let source = base.appendingPathComponent(entry.relativePath)
            switch entry.kind {
            case .symbolicLink:
                // Recreated, never followed: following one turns a link into
                // a copy of whatever it points at, which is both wrong and
                // unbounded when it points at a parent.
                try recreateSymbolicLink(to: target, target: entry.linkTarget ?? "")
            case .directory:
                if usesCleanSubtreeIndex, cachedCleanSubtreeIndex().isClean(relativePath: entry.relativePath) {
                    try cloneWholeDirectory(entry, from: source, to: target)
                    clonedDirs.append(entry.relativePath)
                    clonedWhole = entry.relativePath + "/"
                    continue
                }
                try createEntryDirectory(at: target)
                modes.record(source: source, target: target, enabled: proving)
            case .file:
                try materialize(source, at: target, entry: entry, proving: proving)
            }
        }
        try modes.apply()
        try pruneStale(destination, root: root, relativePath: "", strict: false)
        // A whole clone carries whatever the live subtree holds now, excluded names included.
        for dir in clonedDirs {
            try pruneStale(destination.appendingPathComponent(dir), root: root, relativePath: dir, strict: true)
        }
    }

    private func cloneWholeDirectory(_ entry: SandboxInputClosure.Entry, from source: URL, to target: URL) throws {
        try materializeWholeSubtree(source, at: target)
        guard try existingType(at: target) == .typeDirectory else {
            throw SandboxInputClosureError.contentChanged(path: entry.relativePath)
        }
    }

    private func createEntryDirectory(at target: URL) throws {
        if let type = try existingType(at: target), type != .typeDirectory { try removeIfPresent(target) }
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceError.unwritable(path: target.path, underlying: error.localizedDescription)
        }
    }

    private func cachedCleanSubtreeIndex() -> CleanSubtreeIndex {
        if let existing = cleanSubtreeIndex { return existing }
        let index = CleanSubtreeIndex.build(
            projectRoot: projectRoot,
            excludes: excludes,
            scratchRootPath: scratchRoot.path,
            fileManager: fileManager
        )
        cleanSubtreeIndex = index
        return index
    }

    /// Materializes a whole subtree the clean-subtree index has proven safe
    /// to clone in one call, instead of walking it entry-by-entry.
    ///
    /// Mirrors `materialize`'s clone-first, copy-as-fallback strategy
    /// exactly, just for a directory instead of one file — the same shape
    /// `cloneProducts` already uses for its own whole-directory case, reusing
    /// the same `clone(_:to:)` helper (`CLONE_NOFOLLOW`, so an internal
    /// symlink is reproduced as a symlink, never dereferenced — confirmed
    /// empirically by `WorkspaceManagerCleanSubtreeCloningTests`'s own
    /// symlink tests, for both this clone path and the `copyItem` fallback
    /// below).
    ///
    /// `destination` is removed first, unconditionally: `clonefile` refuses
    /// an existing destination, and a stale leftover here — a `--resume`
    /// against an already-partially-populated sandbox path, matching
    /// `ReproduceCommand`'s own comment about `createSandbox` being
    /// "intentionally incremental" — is safe to discard and re-clone whole
    /// rather than reconciled file-by-file: the end state has the same
    /// file-content bytes and relative-path layout either way (permission
    /// metadata is not guaranteed — see this type's own doc comment on
    /// `cleanSubtreeCloning`), this path just does not attempt
    /// `materialize`'s unchanged-file reuse for content the index has
    /// already proven can be cloned in one call regardless.
    private func materializeWholeSubtree(_ source: URL, at destination: URL) throws {
        try removeIfPresent(destination)
        if supportsAPFSClone(), Self.clone(source, to: destination) { return }
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw WorkspaceError.unwritable(path: destination.path, underlying: error.localizedDescription)
        }
    }

    /// Puts `source`'s contents at `destination` by the cheapest means available.
    nonisolated static func clone(_ source: URL, to destination: URL) -> Bool {
        // CLONE_NOFOLLOW keeps a symlink a symlink rather than cloning its target.
        clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0
    }

    private func recreateSymbolicLink(to destination: URL, target: String) throws {
        try removeIfPresent(destination)
        do {
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        } catch {
            throw WorkspaceError.unwritable(path: destination.path, underlying: error.localizedDescription)
        }
    }

    /// The test `isExcluded(name:relativePath:)` applies against this
    /// instance's own `excludes`, factored out as `static` — and therefore
    /// `nonisolated`, callable without `await` — so `CleanSubtreeIndex.build`
    /// can classify a subtree using the *exact* same rule `populate` itself
    /// checks entries against, rather than a second implementation that
    /// could quietly drift from this one.
    static func isExcluded(name: String, relativePath: String, excludes: [String]) -> Bool {
        excludes.contains { pattern in
            fnmatch(pattern, name, 0) == 0 || fnmatch(pattern, relativePath, 0) == 0
        }
    }
}

// MARK: - Containers over the layout

extension WorkspaceManager {
    /// Builds a fresh sandbox for `id`: a container directly below the
    /// scratch root holding the project copy and a copy of every external
    /// root, each at its position in the layout.
    ///
    /// Reusing a container is intentionally incremental for the project
    /// copy: files whose copy is still current are kept. Entries of a
    /// reused container that are no longer on a layout path (a dependency
    /// dropped since) are removed first, so nothing the current layout does
    /// not name can be read, and each external root's copy is rebuilt whole.
    public func createSandbox(id: String) async throws -> Sandbox {
        // `id` reaches us from a plan file, which is data we did not write. It is
        // hashed below rather than used as a path component, which already
        // neutralizes separators and `..` — but a malformed id is still a bug
        // worth reporting rather than quietly hashing into a valid-looking name.
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WorkspaceError.invalidSandboxID(id)
        }

        let container = scratchRoot
            .appendingPathComponent(Self.directoryName(for: id), isDirectory: true)
            .standardizedFileURL
        guard container.path.hasPrefix(scratchRoot.path + "/") else {
            throw WorkspaceError.sandboxOutsideScratchRoot(path: container.path, scratchRoot: scratchRoot.path)
        }
        let sandbox = layout.sandbox(containerRoot: container)

        // A container that already exists must be a real directory below the
        // scratch root. Following a symlink here would make the prune below,
        // and every copy after it, act on whatever the link points at.
        try requireRealContainer(container, beforeCreation: true)
        try createDirectory(container)
        try requireRealContainer(container, beforeCreation: false)
        if !layout.externalRoots.isEmpty {
            try pruneContainer(container)
        }

        try createDirectory(sandbox.workspaceRoot)
        let closure = try capturedClosure()
        let retainedManifest = container.appendingPathExtension("retained")
        previouslyFromClosure = Self.readRetainedManifest(retainedManifest)
        try populate(
            closure.project, from: stagedRoot(for: closure.project, closure: closure), to: sandbox.workspaceRoot,
            usesCleanSubtreeIndex: cleanSubtreeCloning, proving: false
        )
        Self.writeRetainedManifest(retainedManifest, names: Self.retainedOnReuse.filter { closure.project.entry(at: $0) != nil })
        // The clean-subtree index is keyed on project-relative paths, so it
        // says nothing about an external root: those always take the walk.
        // Each root copy is rebuilt from nothing: `populate` only visits
        // entries the package still has, so a file deleted from it since a
        // reused container was filled would otherwise stay and be compiled.
        // A package's copy holds no build state (that lives in the
        // workspace's `.build`), so rebuilding costs only the clones.
        for root in closure.roots.dropFirst() {
            let destination = container.appendingPathComponent(root.containerRelativePath, isDirectory: true)
            try removeIfPresent(destination)
            try createDirectory(destination)
            try populate(
                root, from: stagedRoot(for: root, closure: closure), to: destination,
                usesCleanSubtreeIndex: false, proving: false
            )
        }
        try await proveContainmentOnce(sandbox)
        return sandbox
    }

    /// Runs the containment proof on the first sandbox this instance
    /// creates, before any sandbox is handed out.
    ///
    /// Once is enough: every later sandbox is a copy of the same layout at
    /// an equal-length path, and no mutation touches a manifest. Sandboxes
    /// requested while the proof runs wait for it, and its verdict holds
    /// for the rest of this instance's lifetime, so after a refusal no
    /// sandbox is ever returned. A refused sandbox's container is removed.
    private func proveContainmentOnce(_ sandbox: Sandbox) async throws {
        guard let containmentProof else {
            // Nothing can be refused later, so the first accepted sandbox is
            // the moment the layout is known good.
            if !announcedWithoutProof {
                announcedWithoutProof = true
                onContainmentProven?()
            }
            return
        }
        let run: Task<Void, any Error>
        if let containmentProofRun {
            run = containmentProofRun
        } else {
            let layout = layout
            let onProven = onContainmentProven
            run = Task {
                try await containmentProof.proveContainment(of: sandbox, layout: layout)
                onProven?()
            }
            containmentProofRun = run
        }
        do {
            try await run.value
        } catch let refusal as SandboxContainmentError {
            try? removeIfPresent(sandbox.containerRoot)
            throw WorkspaceError.containment(refusal)
        } catch {
            try? removeIfPresent(sandbox.containerRoot)
            throw error
        }
    }

    /// Deletes a sandbox's container, with every copy in it.
    ///
    /// The container must be exactly one `sbx_` directory directly below the
    /// scratch root once symlinks are resolved: a workspace inside a
    /// container, the scratch root itself or anything elsewhere is refused.
    /// A recursive delete gets exactly one chance to be wrong.
    public func destroySandbox(_ sandbox: Sandbox) async throws {
        let canonical = sandbox.containerRoot.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.deletingLastPathComponent().path == scratchRoot.path,
              canonical.lastPathComponent.hasPrefix("sbx_")
        else {
            throw WorkspaceError.notASandboxContainer(path: canonical.path, scratchRoot: scratchRoot.path)
        }
        try removeIfPresent(canonical)
        // The reuse manifest lives next to the container, not in it.
        try removeIfPresent(canonical.appendingPathExtension("retained"))
    }

    /// Deletes whatever an earlier process left at `id`'s sandbox, external
    /// copies included, so the next `createSandbox(id:)` starts from nothing
    /// instead of reusing it incrementally. Nothing there is not an error.
    public func destroyExistingSandbox(id: String) async throws {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WorkspaceError.invalidSandboxID(id)
        }
        let container = scratchRoot.appendingPathComponent(Self.directoryName(for: id), isDirectory: true)
        guard fileManager.fileExists(atPath: container.path) else { return }
        try await destroySandbox(layout.sandbox(containerRoot: container))
    }

    /// Deletes a products clone `cloneProducts*` made.
    ///
    /// Same rule as `destroySandbox(_:)`, for the other kind of directory
    /// this manager creates: exactly one `prd_` directory directly below the
    /// scratch root once symlinks are resolved.
    public func destroyProductsClone(at clone: URL) async throws {
        let canonical = clone.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.deletingLastPathComponent().path == scratchRoot.path,
              canonical.lastPathComponent.hasPrefix("prd_")
        else {
            throw WorkspaceError.notAProductsClone(path: canonical.path, scratchRoot: scratchRoot.path)
        }
        try removeIfPresent(canonical)
    }

    func removeIfPresent(_ directory: URL) throws {
        guard (try? fileManager.attributesOfItem(atPath: directory.path)) != nil else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            throw WorkspaceError.unwritable(path: directory.path, underlying: error.localizedDescription)
        }
    }

    /// Refuses a container that is a symbolic link, or that resolves anywhere
    /// but directly below the scratch root.
    ///
    /// `beforeCreation` tolerates a container that does not exist yet; after
    /// creation it must exist and resolve to exactly `scratchRoot/<name>`.
    private func requireRealContainer(_ container: URL, beforeCreation: Bool) throws {
        let type = (try? fileManager.attributesOfItem(atPath: container.path))?[.type] as? FileAttributeType
        if type == nil, beforeCreation { return }
        let scratch = CanonicalPath.resolve(scratchRoot.path) ?? CanonicalPath.lexical(scratchRoot.path)
        let expected = scratch + "/" + container.lastPathComponent
        guard type == .typeDirectory, CanonicalPath.resolve(container.path) == expected else {
            throw WorkspaceError.sandboxOutsideScratchRoot(path: container.path, scratchRoot: scratchRoot.path)
        }
    }

    func createDirectory(_ directory: URL) throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceError.unwritable(path: directory.path, underlying: error.localizedDescription)
        }
    }

    /// Removes whatever a reused container holds off the layout's paths.
    ///
    /// Walks only the directories that lead to a root (`Apps` for
    /// `Apps/Core`). A root's own copy is left to `populate`, and an entry
    /// that should be a directory on the way but is not one is removed too.
    private func pruneContainer(_ container: URL) throws {
        let roots = Set([layout.workspaceRelativePath] + layout.externalRoots.map(\.relativePath))
        try prune(directory: container, relativePath: "", roots: roots)
    }

    private func prune(directory: URL, relativePath: String, roots: Set<String>) throws {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw WorkspaceError.unreadable(path: directory.path, underlying: error.localizedDescription)
        }
        for name in names {
            let relative = relativePath.isEmpty ? name : relativePath + "/" + name
            let entry = directory.appendingPathComponent(name)
            let isDirectory = (try? fileManager.attributesOfItem(atPath: entry.path))?[.type] as? FileAttributeType
                == .typeDirectory
            if isDirectory, roots.contains(relative) { continue }
            if isDirectory, roots.contains(where: { $0.hasPrefix(relative + "/") }) {
                try prune(directory: entry, relativePath: relative, roots: roots)
                continue
            }
            do {
                try fileManager.removeItem(at: entry)
            } catch {
                throw WorkspaceError.unwritable(path: entry.path, underlying: error.localizedDescription)
            }
        }
    }
}
