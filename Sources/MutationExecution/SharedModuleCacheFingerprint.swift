import Foundation
import MutationModel

/// Hardening pass for `Configuration.execution.sharedModuleCache`: a real,
/// actually-queried snapshot of the toolchain identity the shared module
/// cache directory is namespaced under -- see `WorkspaceManager
/// .moduleCachePath(forSandbox:fingerprint:)`.
///
/// `WorkspaceManager.init`'s own unconditional wipe-at-construction (see its
/// doc comment) already makes the shared cache run-scoped in the common
/// case, but that wipe is deliberately `try?`-guarded best-effort -- a
/// permission-denied or file-busy removal is silently swallowed, not
/// surfaced -- and it only ever runs once, at construction. Namespacing the
/// directory itself by a real toolchain fingerprint is a second, independent
/// layer on top of that: even when a wipe silently fails, or a toolchain
/// changes between two invocations that reuse a path -- exactly the
/// possibly-different-toolchain-cache risk `init`'s own doc comment names
/// -- a different toolchain always resolves to a different directory:
/// there is no shared name left for a stale entry to survive under.
///
/// Every field is read from the toolchain itself, never assumed or
/// hardcoded. This type cannot reuse `ToolchainProbe` directly -- that probe
/// lives in the `CLI` target, which depends on `MutationExecution` (where
/// `WorkspaceManager`, and therefore this cache-directory-naming concern,
/// lives), never the other way around -- so it re-probes the same kind of
/// real values independently, scoped to exactly what a cache identity
/// needs. It does, however, reuse `ToolchainProbe`'s own tested distinction
/// for what an absent-or-failed probe is allowed to fold into (see
/// `ToolchainCacheFingerprintProbe.ProbeOutcome`/`resolvedValue(for:)`
/// below): a genuinely reproducible absence (the executable is not on this
/// machine) is safe to record as the fixed string `"unknown"`, but a probe
/// that ran and could not be trusted -- launch failure, timeout, truncated
/// capture, or a successful exit with nothing parseable -- is never folded
/// into that same fixed string, because two *different* toolchains that
/// each happen to hit an untrustworthy probe would otherwise collapse onto
/// the identical fingerprint digest and therefore the identical, wrongly
/// shared cache directory -- exactly the collision this whole fingerprinting
/// pass exists to rule out. See `ToolchainProbeResult.identityEvidenceComplete`
/// (`Sources/CLI/ToolchainProbe.swift`) and `ToolchainCacheIdentityCompletenessTests`
/// for the identical invariant already tested elsewhere in this codebase --
/// "a wrong fingerprint is worse than an absent one" only holds if a lost-
/// evidence probe and a genuine absence are never allowed to look identical.
public struct SharedModuleCacheFingerprint: Sendable, Hashable {
    public let swiftVersion: String
    public let xcodeVersion: String
    public let sdkVersion: String
    public let targetTriple: String

    public init(swiftVersion: String, xcodeVersion: String, sdkVersion: String, targetTriple: String) {
        self.swiftVersion = swiftVersion
        self.xcodeVersion = xcodeVersion
        self.sdkVersion = sdkVersion
        self.targetTriple = targetTriple
    }

    /// The literal string every field folds into before hashing -- kept
    /// separate from `digest` and exposed so a human-facing report
    /// (`mutantkit doctor`'s module-cache diagnostic) can show exactly what
    /// was hashed, not just the opaque digest.
    public var canonicalDescription: String {
        "swift=\(swiftVersion); xcode=\(xcodeVersion); sdk=\(sdkVersion); triple=\(targetTriple)"
    }

    /// The short digest `WorkspaceManager.moduleCacheDirectoryName(
    /// forFingerprint:)` namespaces the shared module cache directory name
    /// with. Same digest shape (`ContentHash.shortDigest`) `WorkspaceManager
    /// .directoryName(for:)` already uses for sandbox names, for the same
    /// reason: deterministic, filesystem-safe, and short enough to read on
    /// disk while debugging.
    public var digest: String {
        ContentHash.shortDigest(of: canonicalDescription, length: 16)
    }
}

/// Probes the four real values `SharedModuleCacheFingerprint` is built from
/// -- `swift --version`, `xcodebuild -version`, the resolved SDK version,
/// and the target triple -- and memoizes the result for this process's
/// lifetime.
///
/// A process-wide singleton (`shared`), deliberately memoized rather than
/// re-probed per build: every field here is a property of the toolchain
/// currently installed on this machine, not of any one mutant's build, and
/// nothing this tool does can change what `xcode-select`/Xcode itself points
/// at mid-process. Spawning four subprocesses before every single mutant's
/// build for an answer that cannot change within one process would be pure,
/// unnecessary overhead -- exactly the kind of per-mutant cost
/// `Configuration.execution.sharedModuleCache` exists to avoid in the first
/// place.
///
/// An actor, not a plain class with a lock: `fingerprint(workingDirectory:)`
/// is the only mutating operation (the memoization write), and it is always
/// reached through one `await` call, so actor isolation is the simplest
/// correct way to serialize it. Two concurrent first callers can still both
/// observe `cached == nil` and both issue a redundant probe (actor
/// reentrancy across the inner `await Self.probe(...)`) -- accepted rather
/// than guarded with a single-flight continuation: it can happen at most
/// once per process, resolves itself as soon as either probe returns, and
/// both probes read the identical, unchanging toolchain, so the redundant
/// work costs a few extra subprocesses once, never a wrong or inconsistent
/// answer.
public actor ToolchainCacheFingerprintProbe {
    public static let shared = ToolchainCacheFingerprintProbe()

    private var cached: SharedModuleCacheFingerprint?

    public init() {}

    public func fingerprint(workingDirectory: URL) async -> SharedModuleCacheFingerprint {
        if let cached { return cached }
        let value = await Self.probe(workingDirectory: workingDirectory)
        cached = value
        return value
    }

    /// `internal`, not `private`: exercised directly by
    /// `SharedModuleCacheFingerprintProbeTests` so the real-subprocess path
    /// can be pinned without going through the memoizing actor wrapper.
    static func probe(workingDirectory: URL) async -> SharedModuleCacheFingerprint {
        async let swiftOutcome = firstLine(
            of: "/usr/bin/xcrun", arguments: ["swift", "--version"], workingDirectory: workingDirectory
        )
        async let xcodeOutcome = firstLine(
            of: "/usr/bin/xcodebuild", arguments: ["-version"], workingDirectory: workingDirectory
        )
        // `SwiftPackageMacOSAdapter` -- the only adapter this flag applies to
        // (see `ExecutionSettings.sharedModuleCache`'s own doc comment) --
        // only ever builds for the host, `macosx`, so that is the one SDK
        // this probe resolves; matches `ToolchainProbe.buildSDKIdentity`'s
        // own `xcrun --sdk <name> --show-sdk-version` shape for the
        // equivalent platform.
        async let sdkOutcome = firstLine(
            of: "/usr/bin/xcrun", arguments: ["--sdk", "macosx", "--show-sdk-version"], workingDirectory: workingDirectory
        )
        // Named distinctly from the static `targetTriple(workingDirectory:)`
        // function called on the right — deliberately, not merely by
        // convention: an `async let name = name(...)` self-shadow is a real
        // ambiguity risk worth avoiding outright rather than relying on
        // Swift resolving it the intended way.
        async let tripleOutcome = targetTriple(workingDirectory: workingDirectory)

        return SharedModuleCacheFingerprint(
            swiftVersion: resolvedValue(for: await swiftOutcome),
            xcodeVersion: resolvedValue(for: await xcodeOutcome),
            sdkVersion: resolvedValue(for: await sdkOutcome),
            targetTriple: resolvedValue(for: await tripleOutcome)
        )
    }

    /// What a single probe subprocess (`swift --version`, `xcodebuild
    /// -version`, `xcrun --show-sdk-version`, `swift -print-target-info`)
    /// actually found -- the same three-way split `ToolchainProbe
    /// .VersionProbeOutcome` (`Sources/CLI/ToolchainProbe.swift`) already
    /// makes and this codebase already tests
    /// (`ToolchainCacheIdentityCompletenessTests`), re-expressed here rather
    /// than imported because this type cannot depend on the `CLI` target
    /// (see this file's own top-level doc comment).
    enum ProbeOutcome: Equatable {
        /// The subprocess ran, exited successfully, and printed something parseable.
        case value(String)
        /// The executable simply is not on this machine (`FileManager
        /// .isExecutableFile` found nothing at the fixed path) -- a clean,
        /// reproducible absence. Re-running the identical probe on the
        /// identical, unchanged machine reports the identical outcome,
        /// because nothing was ever launched that could time out, be
        /// signalled, or answer differently on a retry.
        case notPresent
        /// The subprocess was launched but its outcome proves nothing
        /// reproducible about this machine: it could not be spawned, it
        /// timed out, it was signalled, it exited non-zero, its output could
        /// not be proven fully captured (`ProcessResult.outputComplete ==
        /// false`), or it exited `0` with nothing parseable. Every one of
        /// these is a fact about *this run of the probe*, not a stable fact
        /// about the machine -- the identical probe against the identical,
        /// unchanged machine could easily answer differently next time.
        case untrustworthy
    }

    /// Folds one `ProbeOutcome` into the string
    /// `SharedModuleCacheFingerprint` hashes -- `internal`, not `private`,
    /// so the collision-safety invariant below is pinned directly
    /// (`ToolchainCacheFingerprintProbeTests
    /// .untrustworthyProbeNeverCollapsesToTheSameUnknown`) without needing
    /// to fake an actual subprocess failure.
    ///
    /// `.notPresent` resolves to the fixed string `"unknown"`: a genuine,
    /// reproducible absence is safe for two machines that both genuinely
    /// lack the same tool to share. `.untrustworthy` deliberately does
    /// NOT: folding it into that same fixed string would let two
    /// *different* toolchains -- or the same toolchain on two separate,
    /// unrelated invocations -- that each merely happen to hit an
    /// untrustworthy probe collapse onto the identical fingerprint digest,
    /// and therefore the identical shared cache directory, which is exactly
    /// the false-collision shape `SharedModuleCacheFingerprint` exists to
    /// rule out (see this file's own top-level doc comment). Each
    /// untrustworthy outcome instead resolves to its own fresh, per-call
    /// unique value: within this one process the memoizing `fingerprint(
    /// workingDirectory:)` wrapper still computes it only once, so every
    /// sandbox in *this run* still shares one consistent (if degraded)
    /// cache directory; a *different* process hitting the identical
    /// untrustworthy condition gets its own, different directory rather
    /// than silently reusing this one's.
    static func resolvedValue(for outcome: ProbeOutcome) -> String {
        switch outcome {
        case let .value(value): value
        case .notPresent: "unknown"
        case .untrustworthy: "unknown-untrustworthy-\(UUID().uuidString)"
        }
    }

    private static func firstLine(of executable: String, arguments: [String], workingDirectory: URL) async -> ProbeOutcome {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return .notPresent }
        guard let result = try? await ProcessSupervisor.run(
            executable: executable, arguments: arguments, workingDirectory: workingDirectory, timeoutSeconds: 30
        ), result.succeeded, result.outputComplete else { return .untrustworthy }
        guard let line = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n")
            .first
            .map({ $0.trimmingCharacters(in: .whitespaces) }), !line.isEmpty
        else { return .untrustworthy }
        return .value(line)
    }

    /// `swift -print-target-info`'s own JSON `target.triple` field -- real,
    /// direct evidence of the exact code-generation target this toolchain
    /// resolves to (e.g. `"arm64-apple-macosx26.0"`), not inferred from the
    /// version strings above. The version strings tie the cache to the
    /// *compiler build*; the triple additionally ties it to the
    /// *architecture* that compiler actually targets -- an axis a universal
    /// (arm64/x86_64) toolchain running under Rosetta, or a future
    /// destination-target variant of this same build shape, could otherwise
    /// leave unguarded even though `swift --version`/`xcodebuild -version`
    /// read identically either way.
    ///
    /// Confirmed live against this machine's real toolchain (not assumed):
    /// `xcrun swift -print-target-info` prints a JSON object with a top-level
    /// `"target"` object whose `"triple"` field is exactly this string.
    private static func targetTriple(workingDirectory: URL) async -> ProbeOutcome {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return .notPresent }
        guard let result = try? await ProcessSupervisor.run(
            executable: "/usr/bin/xcrun", arguments: ["swift", "-print-target-info"],
            workingDirectory: workingDirectory, timeoutSeconds: 30
        ), result.succeeded, result.outputComplete else { return .untrustworthy }

        guard let triple = Self.parseTargetTriple(fromTargetInfoJSON: result.standardOutput) else { return .untrustworthy }
        return .value(triple)
    }

    /// Split out of `targetTriple(workingDirectory:)` purely so the parsing
    /// half — the part with no subprocess involved — can be pinned directly
    /// against a captured real `swift -print-target-info` payload
    /// (`SharedModuleCacheFingerprintProbeTests`) without spawning a
    /// toolchain.
    static func parseTargetTriple(fromTargetInfoJSON data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = json["target"] as? [String: Any],
              let triple = target["triple"] as? String
        else { return nil }
        return triple
    }
}

/// Resolves the concrete, on-disk shared module cache directory for a
/// sandbox, namespaced by `ToolchainCacheFingerprintProbe`'s real toolchain
/// fingerprint -- and, the first time this process resolves a path for a
/// given scratch root, resets (deletes) whatever already exists there, so
/// every fingerprint-namespaced directory this process ever points a build
/// at starts empty exactly once per run, the same run-scoping contract
/// `WorkspaceManager.init` already provides for the plain, unnamespaced
/// legacy directory (see its own doc comment).
///
/// A process-wide singleton, deliberately independent of any one
/// `WorkspaceManager` instance: every sandbox under a given scratch root
/// shares the identical toolchain regardless of how many `WorkspaceManager`s
/// this process happens to construct (`RunCommand` alone constructs two --
/// the isolated run's own, and a second for schemata's shared chunk build)
/// -- there is exactly one right answer for a given scratch root, not one
/// per `WorkspaceManager` instance, and threading a per-instance cache
/// through every adapter-construction call site is exactly what
/// `WorkspaceManager.moduleCachePath(forSandbox:fingerprint:)`'s own doc
/// comment already rejected doing for the sandbox path itself.
public actor SharedModuleCacheNamespace {
    public static let shared = SharedModuleCacheNamespace()

    private var resetScratchRoots: Set<String> = []

    /// This process's exclusive claim on a specific fingerprinted cache
    /// directory, keyed by that directory's own `.path` -- held for as long
    /// as this process might be pointing a build at it, i.e. from the first
    /// resolution for that path until process exit. Exists purely so
    /// `forceRemove(_:)` below can refuse to delete a directory some
    /// *other*, still-live process also claims -- see that method's own doc
    /// comment. A process that never successfully claims a given path (the
    /// claim below lost to another live process) still builds against it
    /// normally: ordinary concurrent access to a shared module cache is
    /// already safe by construction (`ExecutionSettings.sharedModuleCache`'s
    /// own doc comment, Clang's per-module `llvm::LockFileManager`) --
    /// holding no claim only ever forecloses this process's own right to
    /// delete the directory out from under whoever does hold it.
    private var claims: [String: RunIsolationLock] = [:]

    public init() {}

    /// The path a build in `sandbox` should point `-module-cache-path` at.
    ///
    /// Reset-once semantics: the *first* call this process makes for a given
    /// scratch root deletes any pre-existing directory at the resolved path
    /// before returning it (best-effort, `try?` -- matching `init`'s own
    /// wipe); every later call for the identical scratch root returns the
    /// same path untouched. Never reset on a later call, even if the
    /// resolved fingerprint were somehow to change mid-process (it does
    /// not -- see `ToolchainCacheFingerprintProbe`'s own doc comment) --
    /// resetting again mid-run would destroy a warm cache other, already-
    /// completed mutants in *this run* are relying on, which is precisely
    /// the failure this task exists to prevent, not reintroduce.
    ///
    /// Actor-serialized, so two sandboxes under the same scratch root
    /// resolving this concurrently (`SharedModuleCacheTests
    /// .concurrentSandboxesStayIsolated`'s own shape) can never both decide
    /// they are "first" and race a double delete, nor can either one's build
    /// observe the directory before the reset (if any) has already
    /// completed -- see this type's own file-level doc comment.
    ///
    /// This same "first call for this scratch root" moment is also when this
    /// process attempts to claim `path` (see `claims` above and
    /// `forceRemove(_:)` below) -- one attempt per path, made right
    /// alongside the reset it is meant to protect the *next* one of, not
    /// repeated on every call.
    public func moduleCachePath(forSandbox sandbox: URL, workingDirectory: URL) async -> URL {
        let scratchRoot = sandbox.deletingLastPathComponent()
        let fingerprint = await ToolchainCacheFingerprintProbe.shared.fingerprint(workingDirectory: workingDirectory)
        let path = WorkspaceManager.moduleCachePath(forSandbox: sandbox, fingerprint: fingerprint.digest)

        if resetScratchRoots.insert(scratchRoot.path).inserted {
            acquireClaim(for: path, scratchRoot: scratchRoot)
            try? FileManager.default.removeItem(at: path)
        }
        return path
    }

    /// Attempts to claim `path` for this process, reusing `RunIsolationLock`
    /// -- the identical inter-process, PID-liveness-checked, stale-owner-
    /// reclaiming primitive `RunCommand`/`DryRunCommand` already use to keep
    /// two whole mutation runs from colliding -- rather than inventing a
    /// second locking mechanism for what is the same underlying problem one
    /// level down: two processes, not two whole runs this time, contending
    /// for one shared, on-disk resource.
    ///
    /// The lock file itself lives beside `path`, one level up under
    /// `scratchRoot` (never inside `path`), deliberately: `forceRemove(_:)`
    /// deletes exactly `path`, and a lock recording this process's own claim
    /// on `path` must survive that deletion, not be destroyed by the very
    /// operation it exists to gate.
    ///
    /// Failure to claim -- `RunIsolationLock.acquire` throwing because
    /// another live process already holds this exact claim -- is not an
    /// error worth surfacing: it only means this process will never attempt
    /// `forceRemove(_:)` against this path (see that method), which is
    /// exactly the correct, conservative outcome when someone else is
    /// already using it.
    private func acquireClaim(for path: URL, scratchRoot: URL) {
        guard claims[path.path] == nil else { return }
        let lockRoot = scratchRoot.appendingPathComponent(".mutantkit-module-cache-locks", isDirectory: true)
        claims[path.path] = try? RunIsolationLock.acquire(projectRoot: path, lockRoot: lockRoot, destination: "shared-module-cache")
    }

    /// Deletes the shared module cache directory at `path` -- but *only*
    /// when this process itself holds the exclusive claim on it acquired in
    /// `moduleCachePath(forSandbox:workingDirectory:)` above. Otherwise a
    /// no-op.
    ///
    /// This exists for `SwiftPackageMacOSAdapter`'s corruption-recovery
    /// retry (see its own doc comment), which has *positive evidence* that
    /// the directory at `path` specifically needs to go. That evidence is
    /// about the directory's *contents*, never about whether some other
    /// process is *currently relying on those contents existing* -- two
    /// concurrent mutation runs that happen to share a scratch root (a real,
    /// documented risk: see `ExecutionSettings.sharedModuleCache`'s own
    /// "Known limitation" paragraph) could otherwise race exactly the way
    /// that paragraph describes: one detects corruption and starts deleting
    /// while the other reads/writes the identical directory mid-build. The
    /// claim check below is what closes that race for the deletion path
    /// specifically -- a process that never claimed `path` (because another
    /// live process already had) refuses to delete it here, full stop,
    /// leaving the retry in `buildWithSharedCacheRecovery` to run against
    /// the directory unwiped rather than risk destroying it out from under
    /// its actual, live owner.
    ///
    /// Deliberately bypasses `resetScratchRoots`' own once-per-scratch-root
    /// bookkeeping (unrelated to the claim check above): recording this
    /// deletion there would be redundant (that scratch root was already
    /// marked reset by the original resolution that produced `path`, which
    /// is also where the claim this method checks was acquired), not
    /// incorrect either way, so this simply performs the removal directly
    /// rather than re-deriving and re-checking the scratch-root key for no
    /// behavioral difference.
    public func forceRemove(_ path: URL) {
        guard claims[path.path] != nil else { return }
        try? FileManager.default.removeItem(at: path)
    }
}
