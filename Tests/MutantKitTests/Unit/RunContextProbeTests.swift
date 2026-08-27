@testable import CLI
import Foundation
import MutationModel
import XCTest

final class RunContextProbeTests: XCTestCase {
    // MARK: - Pure exclusion rule

    func testToolOwnedRootsAreExcluded() {
        XCTAssertTrue(RunContextProbe.isToolOwnedPath(".mutantkit"))
        XCTAssertTrue(RunContextProbe.isToolOwnedPath(".mutantkit/run-locks/owner.lock"))
        XCTAssertTrue(RunContextProbe.isToolOwnedPath(".mutantkit/result-cache/abc.json"))
        XCTAssertTrue(RunContextProbe.isToolOwnedPath(".mutantkit/checkpoint-plan-deadbeef.jsonl"))
        XCTAssertTrue(RunContextProbe.isToolOwnedPath(".mutantkit/sandboxes/sbx_x"))
        XCTAssertTrue(RunContextProbe.isToolOwnedPath(".mutare"))
        XCTAssertTrue(RunContextProbe.isToolOwnedPath(".mutare/checkpoint.jsonl"))
    }

    func testQuotedToolOwnedEntriesAreExcluded() {
        XCTAssertTrue(RunContextProbe.isToolOwnedPath("\".mutantkit/result/cache.json\""))
        XCTAssertTrue(RunContextProbe.isToolOwnedPath("\".mutare/foo bar.jsonl\""))
    }

    func testSourceAndProjectPathsAreKept() {
        XCTAssertFalse(RunContextProbe.isToolOwnedPath("Sources/App/Foo.swift"))
        XCTAssertFalse(RunContextProbe.isToolOwnedPath("Tests/AppTests/FooTests.swift"))
        XCTAssertFalse(RunContextProbe.isToolOwnedPath("App.xcodeproj/project.pbxproj"))
        XCTAssertFalse(RunContextProbe.isToolOwnedPath("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"))
        XCTAssertFalse(RunContextProbe.isToolOwnedPath("mutantkit.yml"))
        // A file whose name merely starts with the prefix but is not under the
        // directory must not be dropped — e.g. a hand-written `.mutantkit.yml`.
        XCTAssertFalse(RunContextProbe.isToolOwnedPath(".mutantkit.yml"))
        // Nor something that looks similar but is real source.
        XCTAssertFalse(RunContextProbe.isToolOwnedPath(".mutantkit-helpers/Foo.swift"))
    }

    // MARK: - worktreeContentState stability across tool-owned output

    func testToolOwnedOutputDoesNotChangeGitState() async throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("let x = 1\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))
        try write("import XCTest\n", at: repo.appendingPathComponent("Tests/AppTests/FooTests.swift"))
        try write("pbx-body\n", at: repo.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        try write("<scheme/>\n", at: repo.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "baseline"], in: repo)

        let before = try await RunContextProbe.worktreeContentState(in: repo)

        // Exactly the files a run itself creates before the digest is computed.
        try write("lock\n", at: makeParent(repo, ".mutantkit/run-locks").appendingPathComponent("owner.lock"))
        try write("cache", at: makeParent(repo, ".mutantkit/result-cache").appendingPathComponent("deadbeef.json"))
        try write("done\n", at: makeParent(repo, ".mutantkit").appendingPathComponent("checkpoint-plan-deadbeef.jsonl"))
        try write("coverage", at: makeParent(repo, ".mutantkit/coverage-cache").appendingPathComponent("cov.json"))
        try write("artifacts", at: makeParent(repo, ".mutantkit/artifacts").appendingPathComponent("mut_x.bundle"))
        // Prior tool name.
        try write("legacy\n", at: makeParent(repo, ".mutare").appendingPathComponent("checkpoint.jsonl"))

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertEqual(before, after, "tool-owned output must not enter the digest")
    }

    // MARK: - worktreeContentState must still move on real changes

    func testSourceChangeMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("let x = 2\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "source change"], in: repo)

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(before, after, "a committed source change must change the digest")
    }

    func testUncommittedSourceChangeMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("let x = 2\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(before, after, "an uncommitted tracked-file change must change the digest")
    }

    func testNewUntrackedSourceFileMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("let y = 0\n", at: repo.appendingPathComponent("Sources/App/Bar.swift"))

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(before, after, "a new untracked source file must change the digest")
    }

    func testTestChangeMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("import XCTest\nfinal class Z {}\n", at: repo.appendingPathComponent("Tests/AppTests/FooTests.swift"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "test change"], in: repo)

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(before, after, "a test change must change the digest")
    }

    func testPbxprojChangeMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("pbx-body-changed\n", at: repo.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "pbxproj change"], in: repo)

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(before, after, "a project.pbxproj change must change the digest")
    }

    func testSchemeChangeMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("<scheme version=\"2\"/>\n", at: repo.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "scheme change"], in: repo)

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(before, after, "a scheme change must change the digest")
    }

    // MARK: - computeContextDigest purpose isolation

    /// `MutationResultCache` and `CoverageProfileCache` share every digest
    /// input except `purpose` (see `computeContextDigest`'s doc comment) —
    /// this is the entire mechanism that keeps a classifier-rule change from
    /// invalidating the coverage cache, and vice versa. It is also the exact
    /// mechanism `RunCommand.swift`'s `resultCacheDigest` relies on to
    /// invalidate stale, pre-activation-gate cached results (a codex
    /// review's finding) by bumping its purpose tag to `"resultCache2"` —
    /// were `purpose` not actually load-bearing, that fix would be a no-op.
    func testDifferentPurposesProduceDifferentDigests() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        let resultCacheDigest = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: Configuration(), toolchain: makeToolchain(), purpose: "resultCache2"
        )
        let coverageCacheDigest = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: Configuration(), toolchain: makeToolchain(), purpose: "coverageProfileCache"
        )

        XCTAssertNotEqual(resultCacheDigest, coverageCacheDigest)
    }

    /// The specific fix this pins: a stale cache entry keyed under the old
    /// `"resultCache"` purpose tag must miss under the new `"resultCache2"`
    /// tag, so an older build's unreviewed classification can never be
    /// silently trusted just because the rest of the run context matches.
    func testResultCachePurposeChangedFromV1InvalidatesOldEntries() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        let oldDigest = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: Configuration(), toolchain: makeToolchain(), purpose: "resultCache"
        )
        let newDigest = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: Configuration(), toolchain: makeToolchain(), purpose: "resultCache2"
        )

        XCTAssertNotEqual(oldDigest, newDigest, "bumping the purpose tag must miss every pre-existing cache entry")
    }

    /// `execution.workers` bounds chunk/mutant-level parallelism only — it
    /// must never gate whether a coverage-cache entry written by one
    /// `workers` value is reused by a run configured with a different one.
    /// Per-test coverage attribution depends on the source tree, tests, and
    /// toolchain, never on how many workers happen to run mutants
    /// concurrently, so `workers: 1` and `workers: 4` (all else equal) must
    /// produce the identical `coverageProfileCache` digest.
    func testWorkersDoesNotAffectCoverageCacheDigest() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        var configWithOneWorker = Configuration()
        configWithOneWorker.execution.workers = 1
        var configWithFourWorkers = Configuration()
        configWithFourWorkers.execution.workers = 4

        let oneWorkerDigest = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: configWithOneWorker, toolchain: makeToolchain(), purpose: "coverageProfileCache"
        )
        let fourWorkerDigest = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: configWithFourWorkers, toolchain: makeToolchain(), purpose: "coverageProfileCache"
        )

        XCTAssertEqual(
            oneWorkerDigest, fourWorkerDigest,
            "a coverage-cache entry must be shared across runs that differ only in execution.workers"
        )
    }

    // MARK: - P4 cache-soundness gap 2: build SDK / destination runtime identity

    /// Adversarial test A: identical everything except the *build* SDK
    /// identity must miss. `xcodeVersion` alone cannot distinguish two SDKs
    /// installed under one Xcode version — this is the exact class of false
    /// hit the gap-2 investigation confirmed as independently variable on a
    /// real machine (two iOS simulator runtimes/SDK builds coexisting under
    /// one Xcode install).
    func testDifferentBuildSDKIdentityMovesTheDigest() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        let digestA = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: Configuration(),
            toolchain: makeToolchain(buildSDKIdentity: "sdk:iphonesimulator:26.3(23D8133)"), purpose: "resultCache2"
        )
        let digestB = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: Configuration(),
            toolchain: makeToolchain(buildSDKIdentity: "sdk:iphonesimulator:26.5(23F77)"), purpose: "resultCache2"
        )

        XCTAssertNotEqual(digestA, digestB, "a different build SDK identity must never be served from a cache entry written under another")
    }

    /// Adversarial test B: identical everything except the *destination*
    /// simulator runtime identity must miss — the same real-machine finding
    /// as test A, for the test-execution side rather than the build side.
    func testDifferentDestinationRuntimeIdentityMovesTheDigest() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        let digestA = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: Configuration(),
            toolchain: makeToolchain(destinationRuntimeIdentity: "simulator:com.apple.CoreSimulator.SimRuntime.iOS-26-3"),
            purpose: "resultCache2"
        )
        let digestB = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: Configuration(),
            toolchain: makeToolchain(destinationRuntimeIdentity: "simulator:com.apple.CoreSimulator.SimRuntime.iOS-26-5"),
            purpose: "resultCache2"
        )

        XCTAssertNotEqual(
            digestA, digestB, "a different destination runtime identity must never be served from a cache entry written under another"
        )
    }

    /// Adversarial test D: the specific real-machine shape that motivated
    /// gap 2 — an *identical* `xcodeVersion` string is not enough on its
    /// own to prove two environments are interchangeable. Pins that
    /// `xcodeVersion` staying fixed while `buildSDKIdentity` moves still
    /// changes the digest, so `xcodeVersion`'s own presence in the digest
    /// can never mask this axis.
    func testIdenticalXcodeVersionWithDifferentSDKIdentityStillMovesTheDigest() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        let digestA = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: Configuration(),
            toolchain: makeToolchain(xcodeVersion: "Xcode 26.6", buildSDKIdentity: "sdk:iphonesimulator:26.3(23D8133)"),
            purpose: "resultCache2"
        )
        let digestB = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: Configuration(),
            toolchain: makeToolchain(xcodeVersion: "Xcode 26.6", buildSDKIdentity: "sdk:iphonesimulator:26.5(23F77)"),
            purpose: "resultCache2"
        )

        XCTAssertNotEqual(
            digestA, digestB,
            "two SDKs coexisting under the identical Xcode version string must not collapse to the same, falsely-reusable digest"
        )
    }

    // MARK: - Helpers

    //
    // The repository plumbing lives in `GitFixture`, shared with
    // `RunContextProbeContentIdentityTests`. These forwarders keep every call
    // site above reading the way it always has.

    private func committedBaseline() async throws -> (URL, String) {
        let fixture = try await GitFixture.committedBaseline()
        return (fixture.repo, fixture.state)
    }

    private func makeGitRepo() throws -> URL {
        try GitFixture.makeRepository(named: "MutantKit-RunContextProbeTests")
    }

    @discardableResult
    private func makeParent(_ root: URL, _ relativePath: String) throws -> URL {
        try GitFixture.makeDirectory(relativePath, in: root)
    }

    private func write(_ contents: String, at url: URL) throws {
        try GitFixture.write(contents, at: url)
    }

    private func git(_ arguments: [String], in root: URL) throws {
        try GitFixture.run(arguments, in: root)
    }
}
