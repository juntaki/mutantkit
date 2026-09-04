@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Real, end-to-end coverage for `Configuration.execution.sharedModuleCache`
/// — see that property's own doc comment, `WorkspaceManager
/// .moduleCachePath(forSandbox:fingerprint:)`, `SharedModuleCacheNamespace`,
/// and `Research/isolated-build-reuse-2026-09/README.md` for the
/// measurements and reasoning this flag rests on. Every test here spawns
/// real `swift build`/`swift test` processes
/// against a throwaway two-function SwiftPM fixture (`Fixture.write`,
/// deliberately close to the research's own `probes/make-fixture.sh` —
/// same package, same tests, one extra independent function/test pair so
/// two sandboxes can carry two distinguishable mutations at once) — slow
/// (each build: several seconds to tens of seconds) but load-bearing: this
/// is what stands behind ever turning this flag on for real.
///
/// `.subprocessExclusive` (see `SubprocessTestGate`) keeps this suite from
/// overlapping any *other* real-subprocess-spawning suite in the binary;
/// `.serialized` keeps its own tests from racing each other — both matter
/// here more than usual, since several tests below deliberately run their
/// *own* concurrent builds within a single test.
///
/// Real-toolchain, real-`swift build`/`swift test` cost (several seconds to
/// tens of seconds per test, ~3 minutes for the whole suite) is why this
/// lives under `Acceptance/`, gated on `Acceptance.isEnabled`, rather than
/// in the default `swift test` run — same convention every other real-
/// build/real-toolchain suite in this repo follows; see `AcceptanceSupport
/// .swift`.
@Suite("Acceptance: SwiftPackageMacOSAdapter shared module cache", .enabled(if: Acceptance.isEnabled), .serialized, .subprocessExclusive)
struct SharedModuleCacheTests {
    private enum Fixture {
        /// Two independent, single-operator functions with their own test —
        /// `add`/`testAdd` matches the research fixture exactly; `subtract`/
        /// `testSubtract` exists only so two sandboxes can each carry a
        /// mutation that is wrong for the *other* sandbox's test, making
        /// cross-sandbox contamination (if the shared module cache ever
        /// caused any) directly observable rather than merely plausible.
        static func write(to dest: URL) throws {
            let fm = FileManager.default
            try? fm.removeItem(at: dest)
            try fm.createDirectory(at: dest.appendingPathComponent("Sources/Calc"), withIntermediateDirectories: true)
            try fm.createDirectory(at: dest.appendingPathComponent("Tests/CalcTests"), withIntermediateDirectories: true)

            try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(
                name: "Calc",
                targets: [
                    .target(name: "Calc"),
                    .testTarget(name: "CalcTests", dependencies: ["Calc"])
                ]
            )
            """.write(to: dest.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

            try calcSource(add: "+", subtract: "-")
                .write(to: dest.appendingPathComponent("Sources/Calc/Calc.swift"), atomically: true, encoding: .utf8)

            try """
            import XCTest
            @testable import Calc

            final class CalcTests: XCTestCase {
                func testAdd() { XCTAssertEqual(Calc().add(2, 3), 5) }
                func testSubtract() { XCTAssertEqual(Calc().subtract(5, 3), 2) }
            }
            """.write(to: dest.appendingPathComponent("Tests/CalcTests/CalcTests.swift"), atomically: true, encoding: .utf8)
        }

        /// `add`/`subtract`'s own operator, parameterised so a "mutation" is
        /// just writing this file again with one operator flipped — the
        /// same single-line-edit shape a real `MutationApplication` would
        /// produce, without needing that machinery (out of scope: this
        /// suite is about the build layer, not mutation application).
        static func calcSource(add: String, subtract: String) -> String {
            """
            public struct Calc {
                public init() {}
                public func add(_ a: Int, _ b: Int) -> Int { return a \(add) b }
                public func subtract(_ a: Int, _ b: Int) -> Int { return a \(subtract) b }
            }
            """
        }
    }

    private static func makeTempDir(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    /// Named result of `build(id:sourceDir:workspaces:sharedModuleCache:)` —
    /// a small struct rather than a 3-member tuple (SwiftLint's own
    /// `large_tuple`, capped at 2, is right that a bare tuple this wide
    /// stops reading as a value and starts reading as positional soup).
    private struct SandboxBuild {
        let sandbox: URL
        let artifact: BuildArtifact
        let binary: URL
    }

    /// Builds `id`'s sandbox from `sourceDir` (already written by `Fixture
    /// .write`/`Fixture.calcSource`) and returns the finished artifact plus
    /// its resolved test-binary path — `SwiftPMTestProductResolver`, not a
    /// hardcoded `.xctest` path, so this stays correct if SwiftPM's own
    /// product layout ever changes.
    @discardableResult
    private func build(
        id: String, sourceDir: URL, workspaces: WorkspaceManager, sharedModuleCache: Bool
    ) async throws -> SandboxBuild {
        let sandbox = try await workspaces.createSandbox(id: id)
        try FileManager.default.removeItem(at: sandbox)
        try FileManager.default.copyItem(at: sourceDir, to: sandbox)

        let configuration = Configuration(execution: ExecutionSettings(sharedModuleCache: sharedModuleCache))
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        let artifact = try await adapter.buildBaseline(in: sandbox)
        let binary = try #require(
            SwiftPMTestProductResolver.resolve(productsDirectory: artifact.productsDirectory),
            "SwiftPM did not produce a locatable .xctest bundle for sandbox \(id)"
        )
        return SandboxBuild(sandbox: sandbox, artifact: artifact, binary: binary)
    }

    // MARK: - Activation-evidence stability

    /// Pins `Research/isolated-build-reuse-2026-09`'s own manual `otool -s`
    /// comparison as a real regression test, through the actual production
    /// hash function (`MachOCodeHash.codeHash`, not a hand-rolled
    /// reimplementation): routing system-module compilation through an
    /// external, shared cache must never change the bytes activation
    /// evidence depends on. `WorkspaceManager.directoryName(for:)`'s own
    /// fixed-width digest already guarantees the two sandbox paths below
    /// are equal length without any extra engineering here — the precise
    /// precondition `MachOCodeHash` requires (see its own doc comment).
    @Test("MachOCodeHash is identical whether the module cache is private or externalized+shared")
    func activationEvidenceStableAcrossSharedCache() async throws {
        let projectRoot = Self.makeTempDir(prefix: "smc-activation-project")
        let scratchRoot = Self.makeTempDir(prefix: "smc-activation-scratch")
        try Fixture.write(to: projectRoot)
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)

        let privateBuild = try await build(id: "private", sourceDir: projectRoot, workspaces: workspaces, sharedModuleCache: false)
        let sharedBuild = try await build(id: "shared", sourceDir: projectRoot, workspaces: workspaces, sharedModuleCache: true)

        #expect(
            !privateBuild.artifact.command.arguments.contains("-module-cache-path"),
            "the flag must add nothing to the command when it is off"
        )
        #expect(sharedBuild.artifact.command.arguments.contains("-module-cache-path"))

        // Toolchain-fingerprint namespacing (this task's own hardening):
        // the argument the real adapter actually passed must be exactly
        // the fingerprint-namespaced path a live probe resolves for this
        // sandbox, and its own directory name must carry the namespacing
        // prefix — not merely "some path", and not the old, unnamespaced
        // `.module-cache` name.
        let fingerprint = await ToolchainCacheFingerprintProbe.shared.fingerprint(workingDirectory: sharedBuild.sandbox)
        let expectedCachePath = WorkspaceManager.moduleCachePath(forSandbox: sharedBuild.sandbox, fingerprint: fingerprint.digest)
        #expect(
            sharedBuild.artifact.command.arguments.contains(expectedCachePath.path),
            "the build must point -module-cache-path at the real, toolchain-fingerprint-namespaced directory"
        )
        #expect(expectedCachePath.lastPathComponent == ".module-cache-\(fingerprint.digest)")

        let privateHash = try #require(MachOCodeHash.codeHash(ofBinaryAt: privateBuild.binary))
        let sharedHash = try #require(MachOCodeHash.codeHash(ofBinaryAt: sharedBuild.binary))
        #expect(privateHash == sharedHash, "externalizing the module cache must never change activation-hashed bytes")
    }

    // MARK: - Concurrent safety

    /// The automated equivalent of Lane S's own manual `s1_race1`/
    /// `s1_race2` check: two sandboxes, two *different* single-line
    /// mutations, built concurrently (`async let`, not sequential awaits)
    /// against the same shared module cache, each then tested. If the
    /// shared cache — or anything about routing two concurrent builds
    /// through it — ever let one sandbox's build observe or affect the
    /// other's, it would show up here as a test outcome that does not
    /// match that sandbox's own mutation. The module cache only ever holds
    /// system-framework `.pcm`s, never project source, so this is expected
    /// to pass by construction — but "expected to" is exactly the kind of
    /// claim this task asked to be proven, not assumed.
    @Test("Two concurrent sandboxes building different mutations against the same shared cache each observe only their own mutation")
    func concurrentSandboxesStayIsolated() async throws {
        let scratchRoot = Self.makeTempDir(prefix: "smc-concurrent-scratch")
        let projectRootA = Self.makeTempDir(prefix: "smc-concurrent-project-a")
        let projectRootB = Self.makeTempDir(prefix: "smc-concurrent-project-b")
        // `add` broken in A, `subtract` broken in B — each sandbox's own
        // mutation is wrong for the *other* sandbox's covering test, so a
        // leaked mutation would flip a result that should stay correct.
        try Fixture.write(to: projectRootA)
        try Fixture.calcSource(add: "-", subtract: "-")
            .write(to: projectRootA.appendingPathComponent("Sources/Calc/Calc.swift"), atomically: true, encoding: .utf8)
        try Fixture.write(to: projectRootB)
        try Fixture.calcSource(add: "+", subtract: "+")
            .write(to: projectRootB.appendingPathComponent("Sources/Calc/Calc.swift"), atomically: true, encoding: .utf8)

        // One `WorkspaceManager`/scratch root shared by both sandboxes — the
        // real production shape: every sandbox under one run points its
        // build at the same run-scoped cache directory.
        let workspaces = try WorkspaceManager(projectRoot: projectRootA, scratchRoot: scratchRoot)
        // `parallel: true` so SwiftPM writes real per-test xunit counts (see
        // `TestSettings.parallel`'s own doc comment) — this test's whole
        // point is checking *which* test failed in each sandbox, which a
        // serial run would report no structured detail for at all.
        let configuration = Configuration(
            tests: TestSettings(parallel: true),
            execution: ExecutionSettings(sharedModuleCache: true)
        )
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)

        async let mutantA: (BuildArtifact, TestRunResult) = {
            let sandbox = try await workspaces.createSandbox(id: "mut_a_addBroken")
            try FileManager.default.removeItem(at: sandbox)
            try FileManager.default.copyItem(at: projectRootA, to: sandbox)
            let artifact = try await adapter.buildBaseline(in: sandbox)
            let run = try await adapter.runBaseline(artifact, in: sandbox, timeoutSeconds: 120)
            return (artifact, run)
        }()
        async let mutantB: (BuildArtifact, TestRunResult) = {
            let sandbox = try await workspaces.createSandbox(id: "mut_b_subtractBroken")
            try FileManager.default.removeItem(at: sandbox)
            try FileManager.default.copyItem(at: projectRootB, to: sandbox)
            let artifact = try await adapter.buildBaseline(in: sandbox)
            let run = try await adapter.runBaseline(artifact, in: sandbox, timeoutSeconds: 120)
            return (artifact, run)
        }()

        let (_, resultA) = try await mutantA
        let (_, resultB) = try await mutantB

        // A's `add` is broken: the suite must fail, and specifically not
        // report a clean pass that would mean A silently built B's source
        // (or something else entirely) instead of its own.
        #expect(resultA.status == .failed, "sandbox A's own mutation (add broken) must be observed")
        // B's `subtract` is broken, `add` is not: if B's build had somehow
        // picked up A's `add` mutation via the shared cache, this would be
        // `.failed` from the *wrong* test instead of `.failed` from
        // `testSubtract` only.
        #expect(resultB.status == .failed, "sandbox B's own mutation (subtract broken) must be observed")

        // `status == .failed` alone cannot rule out contamination: a real
        // failure from a sandbox's own mutation already flips `status`, so
        // an *extra*, wrongly-contaminated failure from the other
        // sandbox's mutation would hide behind it. Only the structured
        // per-test list can show that — which is why `parallel: true` was
        // required above rather than optional.
        let summaryA = try #require(resultA.summary, "expected structured per-test results under tests.parallel")
        let summaryB = try #require(resultB.summary, "expected structured per-test results under tests.parallel")
        #expect(summaryA.failingTests.contains { $0.contains("testAdd") })
        #expect(!summaryA.failingTests.contains { $0.contains("testSubtract") }, "B's mutation must never surface in A's own result")
        #expect(summaryB.failingTests.contains { $0.contains("testSubtract") })
        #expect(!summaryB.failingTests.contains { $0.contains("testAdd") }, "A's mutation must never surface in B's own result")
    }

    // MARK: - Corruption / staleness

    /// What actually happens if the shared cache is corrupted mid-run —
    /// verified, not assumed. Empirically established (session log, not
    /// reproduced by this test itself — the sequence below is): a system
    /// module `.pcm` truncated to garbage between two builds does not fail
    /// the next build and does not silently change the compiled program;
    /// Clang detects the invalid entry (real, documented mechanism —
    /// `llvm::LockFileManager`-guarded module builds, plus each `.pcm`'s
    /// own validity/hash check on load) and recompiles that one module in
    /// memory rather than trusting corrupt bytes. This test pins the
    /// specific, real outcome, not a guess: build succeeds, and its
    /// activation hash matches an uncorrupted reference built at an
    /// equal-length path.
    ///
    /// Scope, stated precisely rather than implied: this covers exactly one
    /// corruption shape — a `.pcm` overwritten with random bytes, Clang's
    /// easiest possible rejection case (the file's own hash/validity check
    /// fails outright). It does **not** cover the shape a real killed-mid-
    /// build process actually leaves — an orphan `<module>-<random>.pcm-
    /// <random>` temp file alongside a stale `<module>.pcm.lock-<random>` —
    /// which exercises `llvm::LockFileManager`'s stale-lock-owner detection
    /// rather than the per-file validity check this test exercises. That
    /// narrower, more realistic shape is not covered by any test in this
    /// suite yet.
    @Test("A shared module cache with a corrupted system-module .pcm still produces a correct build, not a silently wrong one")
    func corruptedCacheEntryStillBuildsCorrectly() async throws {
        let projectRoot = Self.makeTempDir(prefix: "smc-corrupt-project")
        let scratchRoot = Self.makeTempDir(prefix: "smc-corrupt-scratch")
        try Fixture.write(to: projectRoot)
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)

        // Reference: an uncorrupted private-cache build of the identical,
        // unmutated source — the "known correct" hash the corrupted-cache
        // build below must still match.
        let reference = try await build(id: "reference", sourceDir: projectRoot, workspaces: workspaces, sharedModuleCache: false)
        let referenceHash = try #require(MachOCodeHash.codeHash(ofBinaryAt: reference.binary))

        // Warm the shared cache for real, then corrupt one of the system
        // modules it just produced — not a made-up file, an actual `.pcm`
        // this run's own build wrote.
        let warm = try await build(id: "warm", sourceDir: projectRoot, workspaces: workspaces, sharedModuleCache: true)
        // Resolved through the identical `SharedModuleCacheNamespace`
        // singleton the real adapter build above just used — never a
        // hand-rederived path — so this test corrupts the exact directory
        // production code actually pointed `-module-cache-path` at,
        // fingerprint namespacing included. A second call for the same
        // scratch root is safe: `SharedModuleCacheNamespace` only resets
        // (deletes) on the *first* resolution per scratch root, and that
        // first resolution already happened inside `warm`'s own build.
        let cachePath = await SharedModuleCacheNamespace.shared.moduleCachePath(forSandbox: warm.sandbox, workingDirectory: warm.sandbox)
        // The cache root holds a mix of per-invocation bucket directories
        // and loose top-level files (e.g. a `.swiftmodule` sitting right
        // beside the bucket directories) — walk it generically instead of
        // assuming a fixed two-level shape.
        let pcmFiles = try #require(
            FileManager.default.enumerator(at: cachePath, includingPropertiesForKeys: [.isRegularFileKey])
        ).compactMap { $0 as? URL }.filter { $0.pathExtension == "pcm" }
        let victim = try #require(pcmFiles.first, "expected the shared cache to hold at least one .pcm after a real build")
        try Data((0 ..< 4096).map { _ in UInt8.random(in: 0 ... 255) }).write(to: victim)

        // A fresh, independent sandbox against the now-corrupted cache.
        let afterCorruption = try await build(
            id: "afterCorruption", sourceDir: projectRoot, workspaces: workspaces, sharedModuleCache: true
        )
        let afterCorruptionHash = try #require(MachOCodeHash.codeHash(ofBinaryAt: afterCorruption.binary))
        #expect(
            afterCorruptionHash == referenceHash,
            "a corrupted shared-cache entry must never silently change the compiled program"
        )

        // Whole-directory loss is the coarser version of the same question,
        // and this run-scoped design's own answer to it: `swift build`
        // recreates a missing `-module-cache-path` directory from nothing
        // (confirmed empirically, `Research/isolated-build-reuse-2026-09`),
        // so deleting it outright is expected to degrade to a plain cold
        // rebuild, never a wrong one — never a build failure either.
        try FileManager.default.removeItem(at: cachePath)
        let afterDeletion = try await build(id: "afterDeletion", sourceDir: projectRoot, workspaces: workspaces, sharedModuleCache: true)
        let afterDeletionHash = try #require(MachOCodeHash.codeHash(ofBinaryAt: afterDeletion.binary))
        #expect(afterDeletionHash == referenceHash, "a wholly-deleted shared cache directory must still rebuild correctly, not wrongly")
    }

    // MARK: - Corruption recovery (delete-and-retry)

    /// A level up from `corruptedCacheEntryStillBuildsCorrectly` above:
    /// that test proves Clang recovers an individually corrupted `.pcm`
    /// in-place, without the build ever failing at all. This proves the
    /// build that *does* fail for a real, cache-implicated reason still
    /// recovers, through `SwiftPackageMacOSAdapter`'s own one-shot
    /// delete-and-retry (see its `buildWithSharedCacheRecovery`/
    /// `isLikelySharedModuleCacheCorruption` doc comments for the exact,
    /// real-reproduction-backed heuristic).
    ///
    /// The failure staged here is real, not simulated: an empty, `0o555`
    /// (read+execute, no write) cache directory before a cold build is
    /// exactly what this task's own investigation reproduced live as a
    /// genuine `swift build` failure — `<unknown>:0: error: error opening
    /// '<cache-path>/Swift-<hash>.swiftmodule' for output: ...: Permission
    /// denied` — distinct from `corruptedCacheEntryStillBuildsCorrectly`'s
    /// own corrupted-`.pcm` shape, which Clang already absorbs silently.
    @Test("A build whose shared cache is unwritable before a cold build recovers via one delete-and-retry, producing the correct binary")
    func unwritableCacheDirectoryRecoversViaDeleteAndRetry() async throws {
        let projectRoot = Self.makeTempDir(prefix: "smc-recovery-project")
        let scratchRoot = Self.makeTempDir(prefix: "smc-recovery-scratch")
        try Fixture.write(to: projectRoot)
        let workspaces = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)

        // Reference: a known-good private-cache build of the identical,
        // unmutated source — what the recovered build below must still
        // match, proving recovery never quietly produces a *wrong* binary
        // that merely happens to link.
        let reference = try await build(
            id: "recovery-reference", sourceDir: projectRoot, workspaces: workspaces, sharedModuleCache: false
        )
        let referenceHash = try #require(MachOCodeHash.codeHash(ofBinaryAt: reference.binary))

        let sandbox = try await workspaces.createSandbox(id: "recovery-afflicted")
        try FileManager.default.removeItem(at: sandbox)
        try FileManager.default.copyItem(at: projectRoot, to: sandbox)

        // Resolve this sandbox's real shared-cache path first, through the
        // identical `SharedModuleCacheNamespace` singleton the real build
        // below uses — this consumes its once-per-scratch-root reset now,
        // against nothing (the directory does not exist yet), so the
        // read-only trap staged next is never silently swept away by that
        // same reset before the build gets a chance to hit it. Mirrors
        // `corruptedCacheEntryStillBuildsCorrectly`'s own "warm first, then
        // sabotage" ordering above.
        let cachePath = await SharedModuleCacheNamespace.shared.moduleCachePath(forSandbox: sandbox, workingDirectory: sandbox)
        try FileManager.default.createDirectory(at: cachePath, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cachePath.path)
        defer {
            // Best-effort: leaving a read-only directory behind is at worst
            // unclaimed disk space, but restoring it costs nothing and
            // keeps this test's own sabotage from outliving it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cachePath.path)
        }

        let configuration = Configuration(execution: ExecutionSettings(sharedModuleCache: true))
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        let artifact = try await adapter.buildBaseline(in: sandbox)

        let binary = try #require(
            SwiftPMTestProductResolver.resolve(productsDirectory: artifact.productsDirectory),
            "the recovered build did not produce a locatable .xctest bundle"
        )
        let recoveredHash = try #require(MachOCodeHash.codeHash(ofBinaryAt: binary))
        #expect(
            recoveredHash == referenceHash,
            "recovering from a broken shared cache must still produce the correct binary, never a silently wrong one"
        )
        // The retry must have actually run against a real, fresh cache —
        // not merely fallen back to a private one some other way.
        #expect(artifact.command.arguments.contains("-module-cache-path"))
    }

    // MARK: - Reset-on-construction

    /// `WorkspaceManager.init`'s own unconditional wipe (see its doc
    /// comment) is what keeps this feature run-scoped rather than
    /// cross-run-persistent — this is the fast, no-real-build half of that
    /// guarantee: a pre-existing shared cache directory must not survive a
    /// fresh `WorkspaceManager` construction against the same scratch root.
    @Test("Constructing a WorkspaceManager wipes any pre-existing shared module cache at its scratch root")
    func constructingWorkspaceManagerWipesStaleSharedCache() throws {
        let projectRoot = Self.makeTempDir(prefix: "smc-reset-project")
        let scratchRoot = Self.makeTempDir(prefix: "smc-reset-scratch")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let staleCache = scratchRoot.appendingPathComponent(WorkspaceManager.moduleCacheDirectoryName)
        try FileManager.default.createDirectory(at: staleCache, withIntermediateDirectories: true)
        try Data("stale-from-a-previous-invocation".utf8).write(to: staleCache.appendingPathComponent("SomeModule-deadbeef.pcm"))
        #expect(FileManager.default.fileExists(atPath: staleCache.path))

        _ = try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot)

        #expect(
            !FileManager.default.fileExists(atPath: staleCache.path),
            "a stale shared cache must never survive into a new process's run"
        )
    }
}
