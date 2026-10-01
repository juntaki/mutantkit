import AppleBuildAdapters
@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// A local package outside the project root is an execution input on par
/// with the project's own sources, so changing it must invalidate every
/// cross-run artifact that a changed input would invalidate.
///
/// All three identities (result cache, coverage cache, checkpoint) are
/// derived from one `RunInputState`. `worktreeContentState` alone lists only
/// what git reports below the project root, so a sibling `../SwiftMapper`
/// is invisible to it whether it lives in the same repository, in another
/// one, or in none. The sandbox copies that sibling, so it is an input like
/// any project source: a stale coverage map would pick the wrong tests and
/// report a false survivor. The control test proves the harness can see a
/// change at all.
@Suite("External package inputs reach every cross-run identity", .subprocessExclusive)
struct ExternalPackageInputFingerprintTests {
    /// Where the sibling package lives relative to the project's repository.
    enum SiblingPlacement: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// `repo/Core` and `repo/SwiftMapper`: one repository, two packages.
        case sameRepository
        /// `parent/Core` is a repository; `parent/SwiftMapper` is in none.
        case outsideAnyRepository

        var testDescription: String { rawValue }
    }

    struct Identities: Equatable, CustomStringConvertible {
        let resultCache: String
        let coverageCache: String
        let checkpoint: String

        var description: String {
            "result \(resultCache.prefix(12)), coverage \(coverageCache.prefix(12)), checkpoint \(checkpoint.prefix(12))"
        }
    }

    @Test("Editing the sibling package changes the result-cache identity", arguments: SiblingPlacement.allCases)
    func siblingChangeMissesResultCache(placement: SiblingPlacement) async throws {
        let (before, after) = try await identitiesAroundSiblingEdit(placement: placement)
        #expect(before.resultCache != after.resultCache)
    }

    @Test("Editing the sibling package changes the coverage-cache identity", arguments: SiblingPlacement.allCases)
    func siblingChangeMissesCoverageCache(placement: SiblingPlacement) async throws {
        let (before, after) = try await identitiesAroundSiblingEdit(placement: placement)
        #expect(before.coverageCache != after.coverageCache)
    }

    @Test("Editing the sibling package makes an existing checkpoint incompatible", arguments: SiblingPlacement.allCases)
    func siblingChangeInvalidatesCheckpoint(placement: SiblingPlacement) async throws {
        let (before, after) = try await identitiesAroundSiblingEdit(placement: placement)
        #expect(before.checkpoint != after.checkpoint)
    }

    /// The control: the same harness does see an edit to the project's own
    /// sources, in every identity. Without it, a green "flipped" test above
    /// could mean the harness changed, not the product.
    @Test("Editing the project's own source changes all three identities", arguments: SiblingPlacement.allCases)
    func projectChangeMovesAllIdentities(placement: SiblingPlacement) async throws {
        let fixture = try Self.makeFixture(placement)
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        let before = try await Self.identities(projectRoot: fixture.projectRoot)
        try GitFixture.write("public let markerCore = 2\n", at: fixture.projectRoot.appendingPathComponent("Sources/Core/Core.swift"))
        let after = try await Self.identities(projectRoot: fixture.projectRoot)

        #expect(before.resultCache != after.resultCache)
        #expect(before.coverageCache != after.coverageCache)
        #expect(before.checkpoint != after.checkpoint)
    }

    // MARK: - Support

    private func identitiesAroundSiblingEdit(placement: SiblingPlacement) async throws -> (Identities, Identities) {
        let fixture = try Self.makeFixture(placement)
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        let before = try await Self.identities(projectRoot: fixture.projectRoot)
        // Same length, different bytes: nothing but content identity can
        // tell the two apart.
        try GitFixture.write(
            "public let markerSwiftMapper = 2\n",
            at: fixture.siblingRoot.appendingPathComponent("Sources/SwiftMapper/SwiftMapper.swift")
        )
        let after = try await Self.identities(projectRoot: fixture.projectRoot)
        return (before, after)
    }

    struct Fixture {
        let projectRoot: URL
        let siblingRoot: URL
        let cleanupRoot: URL
    }

    static func makeFixture(_ placement: SiblingPlacement) throws -> Fixture {
        switch placement {
        case .sameRepository:
            let repo = try GitFixture.makeRepository(named: "MutantKit-ExternalInput-same")
            let core = repo.appendingPathComponent("Core")
            let mapper = repo.appendingPathComponent("SwiftMapper")
            try LocalPackageFixture.writePackage(named: "Core", at: core, pathDependencies: ["../SwiftMapper"])
            try LocalPackageFixture.writePackage(named: "SwiftMapper", at: mapper)
            try GitFixture.run(["add", "."], in: repo)
            try GitFixture.run(["commit", "-m", "baseline"], in: repo)
            return Fixture(projectRoot: core, siblingRoot: mapper, cleanupRoot: repo)
        case .outsideAnyRepository:
            let parent = try LocalPackageFixture.makeLayoutRoot(label: "ExternalInput-outside")
            let core = parent.appendingPathComponent("Core")
            let mapper = parent.appendingPathComponent("SwiftMapper")
            try LocalPackageFixture.writePackage(named: "Core", at: core, pathDependencies: ["../SwiftMapper"])
            try LocalPackageFixture.writePackage(named: "SwiftMapper", at: mapper)
            try GitFixture.run(["init"], in: core)
            try GitFixture.run(["config", "user.email", "tests@mutantkit.local"], in: core)
            try GitFixture.run(["config", "user.name", "MutantKit Tests"], in: core)
            try GitFixture.run(["add", "."], in: core)
            try GitFixture.run(["commit", "-m", "baseline"], in: core)
            return Fixture(projectRoot: core, siblingRoot: mapper, cleanupRoot: parent)
        }
    }

    /// The three identities exactly as `RunCommand` derives them (see
    /// `prepareRunExecutionContext`): the layout resolved for the project,
    /// one input state over it, and every identity derived from that state.
    static func identities(projectRoot: URL) async throws -> Identities {
        let scratch = LocalPackageFixture.scratchRoot(for: projectRoot)
        let layout = try await AppleAdapterFactory.sandboxLayout(
            for: .swiftPackageMacOS, projectRoot: projectRoot, projectPath: nil, scratchRoot: scratch
        )
        let state = await RunCommand.runInputState(
            root: projectRoot, layout: layout, scratchRoots: [scratch], toolchainCacheIdentityComplete: true
        )
        let identities = RunCommand.runIdentities(
            inputState: state, configuration: Configuration(), toolchain: makeToolchain(), workUnitID: "plan"
        )
        return try Identities(
            resultCache: #require(identities.resultCacheDigest),
            coverageCache: #require(identities.coverageCacheDigest),
            checkpoint: #require(identities.checkpoint).value
        )
    }
}
