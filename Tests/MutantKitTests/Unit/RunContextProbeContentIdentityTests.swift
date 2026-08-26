@testable import CLI
import Foundation
import MutationModel
import XCTest

/// The guarantee this change exists to create: a cross-run cache key that is
/// a function of the project's *content*, not of its position in git history.
///
/// Split from `RunContextProbeTests` (which covers the exclusion rules and
/// the "a real change must still invalidate" side) because this is a distinct
/// guarantee with its own failure mode — a false cache *hit* rather than a
/// pointless miss — and because one class carrying both would exceed
/// SwiftLint's type-body-length threshold.
///
/// See `Research/cache-key-granularity/README.md` for the correctness
/// argument these tests pin.
final class RunContextProbeContentIdentityTests: XCTestCase {
    // MARK: - The point of the exercise: surviving across commits

    //
    // Every test in this section failed before `worktreeContentState`
    // replaced the old `gitState`, because that digest folded in
    // `git rev-parse HEAD` — so *any* commit moved it and both cross-run
    // caches missed 100% of the time in CI, which only ever runs on commits.

    /// An empty commit changes `HEAD` and changes nothing else. The tree is
    /// byte-identical, so every mutant's verdict is by definition identical,
    /// so the digest must be identical.
    func testEmptyCommitDoesNotChangeDigest() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try git(["commit", "--allow-empty", "-m", "empty"], in: repo)

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertEqual(before, after, "a commit that changes no file must not invalidate a cache entry")
    }

    /// The shape that motivated this whole change: a developer runs MutantKit
    /// locally against edited-but-uncommitted work, commits exactly that, and
    /// CI runs on the commit. The worktree bytes are identical either side of
    /// the `git commit`, so CI must get cache hits.
    ///
    /// The old digest was `(HEAD, git diff HEAD, untracked hashes)`, whose
    /// first two terms moved *together and opposite* across a commit —
    /// `(HEAD₀, diff=the edit)` became `(HEAD₁, diff=empty)`. Two different
    /// digests for one tree, and therefore a guaranteed total miss.
    func testCommittingAnAlreadyPresentEditDoesNotChangeDigest() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("let x = 99\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))
        let beforeCommit = try await RunContextProbe.worktreeContentState(in: repo)

        try git(["add", "."], in: repo)
        try git(["commit", "-m", "commit the edit that was already on disk"], in: repo)
        let afterCommit = try await RunContextProbe.worktreeContentState(in: repo)

        XCTAssertEqual(
            beforeCommit, afterCommit,
            "committing an edit that was already in the worktree changes no byte the build can read"
        )
    }

    /// "Unrelated changes elsewhere in the repo", in the only form MutantKit
    /// can *prove* is unrelated: paths git ignores. Build output, IDE state,
    /// local scratch — none of it is copied into a sandbox, none of it can
    /// reach a verdict, and none of it may move the digest, even across a
    /// commit.
    func testIgnoredFileChurnAcrossACommitDoesNotChangeDigest() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("build-output/\nlocal-scratch.txt\n", at: repo.appendingPathComponent(".gitignore"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "add ignore rules"], in: repo)
        try write("v1\n", at: repo.appendingPathComponent("build-output/artifact.o"))
        try write("v1\n", at: repo.appendingPathComponent("local-scratch.txt"))
        let before = try await RunContextProbe.worktreeContentState(in: repo)

        try write("v2-totally-different\n", at: repo.appendingPathComponent("build-output/artifact.o"))
        try write("v2-totally-different\n", at: repo.appendingPathComponent("local-scratch.txt"))
        try git(["commit", "--allow-empty", "-m", "a new commit, with only ignored churn beside it"], in: repo)

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertEqual(before, after, "ignored paths never enter a sandbox and must never enter the digest")
    }

    /// Two branches whose trees are byte-identical must agree, however
    /// different their histories. This is the `git checkout` / fresh-clone /
    /// rebase case: the same content reached by a different route.
    func testIdenticalTreesOnDifferentBranchesAgree() async throws {
        let (repo, onMain) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try git(["checkout", "-q", "-b", "feature"], in: repo)
        try write("let x = 2\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "diverge"], in: repo)
        // ...and back to the original content, by a second commit rather than
        // by resetting: a different history arriving at the identical tree.
        try write("let x = 1\n", at: repo.appendingPathComponent("Sources/App/Foo.swift"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "revert the content, keep the history"], in: repo)

        let onFeature = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertEqual(onMain, onFeature, "identical bytes must produce an identical digest whatever the history")
    }

    // MARK: - The conservative fallback: unproven dependencies still miss

    /// The dependency-safety fallback, pinned deliberately.
    ///
    /// `README.md` is not a Swift file, is not a test, and is almost
    /// certainly not a build input — but MutantKit has **no per-file
    /// dependency graph** (no import parsing, no `.swiftdeps`, and the only
    /// target graph that exists is SwiftPM-only while per-test coverage is
    /// xcodebuild-only), so it cannot *prove* that. A test can read any file
    /// in the sandbox at runtime, and `README.md` is copied into every
    /// sandbox.
    ///
    /// So this must still miss. A tool that guessed "docs can't matter" would
    /// be trading a provable answer for a plausible one, which is the exact
    /// failure mode this project exists to rule out. Narrowing this
    /// conservatively — per mutant, by a real dependency closure — is the
    /// follow-on work described in `Research/cache-key-granularity/README.md`;
    /// until it exists, the answer is a miss, never a guess.
    func testTrackedNonSourceChangeStillMissesConservatively() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("# App\n\nNow with a second paragraph.\n", at: repo.appendingPathComponent("README.md"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "docs"], in: repo)

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(
            before, after,
            "a tracked file whose irrelevance cannot be proven must invalidate, not be assumed harmless"
        )
    }

    /// A covering test's own source changing must invalidate — across a
    /// commit, which is where it actually matters. A mutant's verdict is a
    /// statement about what the tests do; change the tests and the statement
    /// is no longer backed by anything.
    func testCoveringTestSourceChangeAcrossACommitMisses() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write(
            "import XCTest\nfinal class FooTests: XCTestCase { func testX() { XCTAssertEqual(x, 1) } }\n",
            at: repo.appendingPathComponent("Tests/AppTests/FooTests.swift")
        )
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "strengthen the assertion"], in: repo)

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(before, after, "a change to test source must invalidate every cached verdict")
    }

    // MARK: - Fail closed rather than hash an incomplete picture

    /// Deleting a tracked file must be visible. The hazard this pins is
    /// specific: if an unhashable path were silently *skipped* rather than
    /// recorded, "file present but unreadable" and "file absent" would hash
    /// identically — a false hit. `absent` is an explicit entry, and it
    /// cannot collide with any real file's identity, which is always
    /// `sha256:`- or `symlink:`-prefixed.
    func testDeletingATrackedFileChangesDigest() async throws {
        let (repo, before) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try FileManager.default.removeItem(at: repo.appendingPathComponent("Sources/App/Foo.swift"))

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(before, after, "a deleted source file must invalidate")
    }

    /// An unreadable tracked file aborts the whole digest rather than
    /// contributing nothing to it. The caller then runs with no cross-run
    /// cache — slower, and correct — instead of with a digest that quietly
    /// says "these two trees are the same" about a file it never read.
    func testUnreadableTrackedFileRefusesToProduceADigest() async throws {
        let (repo, _) = try await committedBaseline()
        let secret = repo.appendingPathComponent("Sources/App/Foo.swift")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path)
            try? FileManager.default.removeItem(at: repo)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)

        do {
            _ = try await RunContextProbe.worktreeContentState(in: repo)
            XCTFail("an unreadable file in scope must abort the digest, not be skipped")
        } catch let error as RunContextProbeError {
            guard case let .unprovableWorktreeContent(path, _) = error else {
                return XCTFail("expected .unprovableWorktreeContent, got \(error)")
            }
            XCTAssertEqual(path, "Sources/App/Foo.swift")
        }
    }

    /// A submodule is a separate repository this digest does not descend
    /// into, so its content cannot be proven unchanged. Refuse rather than
    /// hash the rest and imply the submodule matched.
    func testSubmoduleGitlinkRefusesToProduceADigest() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        // Register a gitlink (mode 160000) directly, which is what a
        // submodule is in the index, without needing a second real repo.
        let head = try gitOutput(["rev-parse", "HEAD"], in: repo)
        try git(["update-index", "--add", "--cacheinfo", "160000,\(head),Vendor/Dependency"], in: repo)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("Vendor/Dependency"), withIntermediateDirectories: true
        )

        do {
            _ = try await RunContextProbe.worktreeContentState(in: repo)
            XCTFail("a submodule in scope must abort the digest")
        } catch let error as RunContextProbeError {
            guard case let .unprovableWorktreeContent(path, _) = error else {
                return XCTFail("expected .unprovableWorktreeContent, got \(error)")
            }
            XCTAssertEqual(path, "Vendor/Dependency")
        }
    }

    /// A symlink contributes its link target text, not the bytes it resolves
    /// to — the target may be outside the repository, and it is the link that
    /// git tracks and that a sandbox copy reproduces. Repointing it is a real
    /// change and must invalidate.
    func testRepointingASymlinkChangesDigest() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        try write("a\n", at: repo.appendingPathComponent("Sources/App/A.swift"))
        try write("b\n", at: repo.appendingPathComponent("Sources/App/B.swift"))
        let link = repo.appendingPathComponent("Sources/App/Current.swift")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "A.swift")
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "link"], in: repo)
        let before = try await RunContextProbe.worktreeContentState(in: repo)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "B.swift")

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(before, after, "a symlink now pointing somewhere else is a changed build input")
    }

    /// Paths are read from `-z` (NUL-separated) git output specifically so a
    /// path needing C-quoting under plain `--porcelain` arrives verbatim.
    /// A quoted path that was never unescaped would be hashed under the wrong
    /// name — or, worse, read as a different file.
    func testPathsNeedingQuotingAreFingerprintedByContent() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        let awkward = repo.appendingPathComponent("Sources/App/naïve \"quoted\" name.swift")
        try write("let a = 1\n", at: awkward)
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "awkward path"], in: repo)
        let before = try await RunContextProbe.worktreeContentState(in: repo)

        try write("let a = 2\n", at: awkward)

        let after = try await RunContextProbe.worktreeContentState(in: repo)
        XCTAssertNotEqual(before, after, "content of an awkwardly-named tracked file must still be observed")
    }

    // MARK: - Project root nested inside a larger repository

    /// `git ls-files` reports paths relative to the working directory;
    /// `git status --porcelain` always reports them relative to the
    /// repository root. When the project root is a subdirectory — a package
    /// inside a monorepo — those two path spaces diverge, and resolving one
    /// against the wrong base would fingerprint the wrong files or none.
    ///
    /// The second half is the load-bearing part: the project's own
    /// `.mutantkit/` must still be excluded even though git spells it
    /// `App/.mutantkit/...` from the repository root. If it were not,
    /// every run's freshly-named lock file and growing cache would enter the
    /// digest, changing it on every run and silently defeating both caches —
    /// the precise failure the tool-owned exclusion exists to prevent.
    func testProjectRootNestedInRepositoryFingerprintsContentAndStillExcludesToolOutput() async throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let project = repo.appendingPathComponent("App")
        try write("let x = 1\n", at: project.appendingPathComponent("Sources/App/Foo.swift"))
        try write("elsewhere\n", at: repo.appendingPathComponent("Docs/notes.md"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "monorepo baseline"], in: repo)

        let before = try await RunContextProbe.worktreeContentState(in: project)

        // The project's own tool output, spelled `App/.mutantkit/...` from
        // the repository root.
        try write("lock\n", at: makeParent(project, ".mutantkit/run-locks").appendingPathComponent("owner.lock"))
        try write("cache", at: makeParent(project, ".mutantkit/result-cache").appendingPathComponent("deadbeef.json"))
        let afterToolOutput = try await RunContextProbe.worktreeContentState(in: project)
        XCTAssertEqual(before, afterToolOutput, "a nested project's own tool output must still be excluded")

        // Real content still has to be observed.
        try write("let x = 2\n", at: project.appendingPathComponent("Sources/App/Foo.swift"))
        let afterSourceChange = try await RunContextProbe.worktreeContentState(in: project)
        XCTAssertNotEqual(before, afterSourceChange, "a nested project's source change must still invalidate")
    }

    // MARK: - Helpers

    private func committedBaseline() async throws -> (URL, String) {
        let fixture = try await GitFixture.committedBaseline()
        return (fixture.repo, fixture.state)
    }

    private func write(_ contents: String, at url: URL) throws {
        try GitFixture.write(contents, at: url)
    }

    @discardableResult
    private func makeParent(_ root: URL, _ relativePath: String) throws -> URL {
        try GitFixture.makeDirectory(relativePath, in: root)
    }

    private func git(_ arguments: [String], in root: URL) throws {
        try GitFixture.run(arguments, in: root)
    }

    private func gitOutput(_ arguments: [String], in root: URL) throws -> String {
        try GitFixture.output(arguments, in: root)
    }

    private func makeGitRepo() throws -> URL {
        try GitFixture.makeRepository(named: "MutantKit-RunContextProbeTests")
    }
}
