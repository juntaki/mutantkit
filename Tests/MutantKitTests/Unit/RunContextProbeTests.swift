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

    // MARK: - gitState stability across tool-owned output

    func testToolOwnedOutputDoesNotChangeGitState() async throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("let x = 1\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))
        try write("import XCTest\n", at: repo.appendingPathComponent("Tests/AppTests/FooTests.swift"))
        try write("pbx-body\n", at: repo.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        try write("<scheme/>\n", at: repo.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "baseline"], in: repo)

        let before = try await RunContextProbe.gitState(in: repo)

        // Exactly the files a run itself creates before the digest is computed.
        try write("lock\n", at: makeParent(repo, ".mutantkit/run-locks").appendingPathComponent("owner.lock"))
        try write("cache", at: makeParent(repo, ".mutantkit/result-cache").appendingPathComponent("deadbeef.json"))
        try write("done\n", at: makeParent(repo, ".mutantkit").appendingPathComponent("checkpoint-plan-deadbeef.jsonl"))
        try write("coverage", at: makeParent(repo, ".mutantkit/coverage-cache").appendingPathComponent("cov.json"))
        try write("artifacts", at: makeParent(repo, ".mutantkit/artifacts").appendingPathComponent("mut_x.bundle"))
        // Prior tool name.
        try write("legacy\n", at: makeParent(repo, ".mutare").appendingPathComponent("checkpoint.jsonl"))

        let after = try await RunContextProbe.gitState(in: repo)
        XCTAssertEqual(before, after, "tool-owned output must not enter the digest")
    }

    // MARK: - gitState must still move on real changes

    func testSourceChangeMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("let x = 2\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "source change"], in: repo)

        let after = try await RunContextProbe.gitState(in: repo)
        XCTAssertNotEqual(before, after, "a committed source change must change the digest")
    }

    func testUncommittedSourceChangeMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("let x = 2\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))

        let after = try await RunContextProbe.gitState(in: repo)
        XCTAssertNotEqual(before, after, "an uncommitted tracked-file change must change the digest")
    }

    func testNewUntrackedSourceFileMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("let y = 0\n", at: repo.appendingPathComponent("Sources/App/Bar.swift"))

        let after = try await RunContextProbe.gitState(in: repo)
        XCTAssertNotEqual(before, after, "a new untracked source file must change the digest")
    }

    func testTestChangeMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("import XCTest\nfinal class Z {}\n", at: repo.appendingPathComponent("Tests/AppTests/FooTests.swift"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "test change"], in: repo)

        let after = try await RunContextProbe.gitState(in: repo)
        XCTAssertNotEqual(before, after, "a test change must change the digest")
    }

    func testPbxprojChangeMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("pbx-body-changed\n", at: repo.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "pbxproj change"], in: repo)

        let after = try await RunContextProbe.gitState(in: repo)
        XCTAssertNotEqual(before, after, "a project.pbxproj change must change the digest")
    }

    func testSchemeChangeMovesGitState() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("<scheme version=\"2\"/>\n", at: repo.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "scheme change"], in: repo)

        let after = try await RunContextProbe.gitState(in: repo)
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

    // MARK: - Helpers

    /// Builds a repo with the committed baseline used by the "moves" tests and
    /// returns it together with its initial `gitState`, so each test only has
    /// to express what it changed.
    private func committedBaseline() async throws -> (URL, String) {
        let repo = try makeGitRepo()
        try write("let x = 1\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))
        try write("import XCTest\n", at: repo.appendingPathComponent("Tests/AppTests/FooTests.swift"))
        try write("pbx-body\n", at: repo.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        try write("<scheme/>\n", at: repo.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "baseline"], in: repo)
        let state = try await RunContextProbe.gitState(in: repo)
        return (repo, state)
    }

    private func makeGitRepo() throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-RunContextProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init"], in: repo)
        try git(["config", "user.email", "tests@mutantkit.local"], in: repo)
        try git(["config", "user.name", "MutantKit Tests"], in: repo)
        return repo
    }

    @discardableResult
    private func makeParent(_ root: URL, _ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func git(_ arguments: [String], in root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "RunContextProbeTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"]
            )
        }
    }
}
