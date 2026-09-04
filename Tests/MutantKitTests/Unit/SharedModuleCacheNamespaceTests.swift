@testable import MutationExecution
import Foundation
import Testing

/// Fast (one real, short toolchain probe; otherwise pure filesystem)
/// coverage for `SharedModuleCacheNamespace`'s own once-per-scratch-root
/// reset contract — the mechanism that keeps a real `swift build` (covered
/// separately, and expensively, by `SharedModuleCacheTests`'s Acceptance
/// suite) honest without needing to spawn one here.
@Suite("SharedModuleCacheNamespace: once-per-scratch-root reset")
struct SharedModuleCacheNamespaceTests {
    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    @Test("The first resolution for a scratch root deletes a pre-existing directory already at the resolved path")
    func firstResolutionResetsPreexistingDirectory() async throws {
        let namespace = SharedModuleCacheNamespace()
        let scratchRoot = Self.makeTempDir(prefix: "smc-namespace-scratch")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let sandbox = scratchRoot.appendingPathComponent("sbx_probe")

        // Pre-create the exact directory a real resolution will land on,
        // with a marker file inside, so "was it actually deleted" is
        // directly observable rather than inferred from behavior.
        let fingerprint = await ToolchainCacheFingerprintProbe.shared.fingerprint(workingDirectory: scratchRoot)
        let expectedPath = WorkspaceManager.moduleCachePath(forSandbox: sandbox, fingerprint: fingerprint.digest)
        try FileManager.default.createDirectory(at: expectedPath, withIntermediateDirectories: true)
        let marker = expectedPath.appendingPathComponent("stale-from-a-previous-invocation")
        try Data("stale".utf8).write(to: marker)
        #expect(FileManager.default.fileExists(atPath: marker.path))

        let resolved = await namespace.moduleCachePath(forSandbox: sandbox, workingDirectory: scratchRoot)

        #expect(resolved.path == expectedPath.path)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "a stale entry must not survive the first resolution")
    }

    @Test("A later resolution for the same scratch root never resets a directory this run itself already populated")
    func laterResolutionNeverResetsItsOwnWork() async throws {
        let namespace = SharedModuleCacheNamespace()
        let scratchRoot = Self.makeTempDir(prefix: "smc-namespace-scratch")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let sandboxA = scratchRoot.appendingPathComponent("sbx_a")
        let sandboxB = scratchRoot.appendingPathComponent("sbx_b")

        let firstPath = await namespace.moduleCachePath(forSandbox: sandboxA, workingDirectory: scratchRoot)
        try FileManager.default.createDirectory(at: firstPath, withIntermediateDirectories: true)
        let marker = firstPath.appendingPathComponent("warmed-by-an-earlier-mutant-this-run")
        try Data("warm".utf8).write(to: marker)

        // A second sandbox under the identical scratch root — the real
        // shape of a run's second mutant — must resolve to the identical
        // path (same toolchain, same scratch root) and must never delete
        // what the first resolution's caller already populated.
        let secondPath = await namespace.moduleCachePath(forSandbox: sandboxB, workingDirectory: scratchRoot)

        #expect(secondPath.path == firstPath.path)
        #expect(
            FileManager.default.fileExists(atPath: marker.path),
            "an already-warmed cache must survive a later sandbox's own resolution"
        )
    }

    @Test("forceRemove deletes the directory regardless of this scratch root's own reset bookkeeping")
    func forceRemoveDeletesRegardlessOfResetState() async throws {
        let namespace = SharedModuleCacheNamespace()
        let scratchRoot = Self.makeTempDir(prefix: "smc-namespace-scratch")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let sandbox = scratchRoot.appendingPathComponent("sbx_probe")

        let path = await namespace.moduleCachePath(forSandbox: sandbox, workingDirectory: scratchRoot)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        #expect(FileManager.default.fileExists(atPath: path.path))

        await namespace.forceRemove(path)

        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    // MARK: - Concurrent-process protection

    /// The regression for a real race: two concurrent mutation-testing
    /// *processes* sharing one scratch root, one of which detects
    /// (real-or-not) corruption and calls `forceRemove` while the other is
    /// still actively building against the identical directory. `forceRemove`
    /// must never delete out from under a live claim it does not itself
    /// hold — see that method's own doc comment for the full reasoning.
    ///
    /// `RunIsolationLock`'s own ownership bookkeeping is purely a live lock
    /// file on disk plus a PID-liveness check (`kill(pid, 0)`), so
    /// pre-acquiring the *identical* lock this suite's own `namespace` would
    /// try to acquire — before `namespace` ever resolves the path at all —
    /// is indistinguishable, from `acquireClaim`'s own perspective, from a
    /// genuinely separate OS process already holding it: both look like
    /// "a live lock file owned by a PID that is still alive". This is what
    /// lets a single test process stand in for two real ones without
    /// actually spawning a second `mutantkit` invocation.
    @Test("forceRemove refuses to delete a cache directory another live process already claims")
    func forceRemoveRefusesWhenAnotherProcessHoldsTheClaim() async throws {
        let namespace = SharedModuleCacheNamespace()
        let scratchRoot = Self.makeTempDir(prefix: "smc-namespace-scratch")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let sandbox = scratchRoot.appendingPathComponent("sbx_probe")

        let fingerprint = await ToolchainCacheFingerprintProbe.shared.fingerprint(workingDirectory: scratchRoot)
        let path = WorkspaceManager.moduleCachePath(forSandbox: sandbox, fingerprint: fingerprint.digest)

        // The "other process" claims this exact path *first*, before this
        // suite's own `namespace` ever resolves it — mirroring the real
        // ordering the race depends on (the other run's own build was
        // already under way).
        let lockRoot = scratchRoot.appendingPathComponent(".mutantkit-module-cache-locks", isDirectory: true)
        let foreignClaim = try RunIsolationLock.acquire(projectRoot: path, lockRoot: lockRoot, destination: "shared-module-cache")
        defer { foreignClaim.release() }

        // `namespace`'s own first resolution now loses the race for the
        // claim (the foreign one above is live), but must still succeed and
        // return the correct path — building against a shared cache this
        // process does not itself own the claim on is safe by design (see
        // `claims`'s own doc comment); only the *delete* is gated.
        let resolved = await namespace.moduleCachePath(forSandbox: sandbox, workingDirectory: scratchRoot)
        #expect(resolved.path == path.path)

        // Simulate the other process's own live build having written real
        // output into the shared directory in the meantime.
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let marker = path.appendingPathComponent("live-build-output-from-the-other-process")
        try Data("still in use".utf8).write(to: marker)

        await namespace.forceRemove(path)

        #expect(
            FileManager.default.fileExists(atPath: marker.path),
            "forceRemove must never delete a cache directory a live foreign claim still owns"
        )
    }
}
