@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// What the run input state reads from local packages outside the project,
/// and what happens when it cannot read them.
///
/// The layouts here come from `SandboxLayout.make` with the packages given
/// directly, so no manifest is evaluated; `ExternalPackageInputFingerprintTests`
/// covers the path through real discovery.
@Suite("Run input state over local packages outside the project", .subprocessExclusive)
struct RunInputStateTests {
    /// `parent/Core` (a git repository) beside `parent/SwiftMapper`.
    struct Fixture {
        let parent: URL
        let projectRoot: URL
        let siblingRoot: URL
        let layout: SandboxLayout
        let scratchRoot: URL
    }

    static func makeFixture(siblingInGit: Bool = false) throws -> Fixture {
        let parent = try LocalPackageFixture.makeCanonicalLayoutRoot(label: "RunInputState")
        let core = parent.appendingPathComponent("Core", isDirectory: true)
        let mapper = parent.appendingPathComponent("SwiftMapper", isDirectory: true)
        try LocalPackageFixture.writePackage(named: "Core", at: core, pathDependencies: ["../SwiftMapper"])
        try LocalPackageFixture.writePackage(named: "SwiftMapper", at: mapper)
        for repository in siblingInGit ? [core, mapper] : [core] {
            try GitFixture.run(["init"], in: repository)
            try GitFixture.run(["config", "user.email", "tests@mutantkit.local"], in: repository)
            try GitFixture.run(["config", "user.name", "MutantKit Tests"], in: repository)
        }
        let scratch = LocalPackageFixture.scratchRoot(for: core)
        let layout = SandboxLayout.make(
            canonicalProjectRoot: core.path,
            localPackages: [LocalPackageRoot(reportedPath: mapper.path, canonicalPath: mapper.path, declaredBy: core.path)]
        )
        try SandboxExternalRootValidator.validate(layout: layout, excludes: WorkspaceManager.defaultExcludes, scratchRoot: scratch)
        return Fixture(parent: parent, projectRoot: core, siblingRoot: mapper, layout: layout, scratchRoot: scratch)
    }

    static func externalDigest(_ fixture: Fixture) throws -> String {
        let inputs = try RunInputState.externalPackageInputs(
            of: fixture.layout, scratchRoots: [fixture.scratchRoot], excludes: WorkspaceManager.defaultExcludes
        )
        try #require(inputs.map(\.relativeIdentity) == ["SwiftMapper"])
        return inputs[0].contentDigest
    }

    @Test("An external root in no repository is digested from its files, without git")
    func nonGitExternalRootIsDigested() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let before = try Self.externalDigest(fixture)
        try GitFixture.write(
            "public let markerSwiftMapper = 2\n",
            at: fixture.siblingRoot.appendingPathComponent("Sources/SwiftMapper/SwiftMapper.swift")
        )
        #expect(try Self.externalDigest(fixture) != before)
    }

    /// The sandbox copies ignored files too, so the digest must read them:
    /// the git listing the project root uses would miss this one.
    @Test("A git-ignored file in an external root is part of the digest")
    func ignoredFileInExternalRootIsDigested() throws {
        let fixture = try Self.makeFixture(siblingInGit: true)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try GitFixture.write("Generated.swift\n", at: fixture.siblingRoot.appendingPathComponent(".gitignore"))
        let generated = fixture.siblingRoot.appendingPathComponent("Sources/SwiftMapper/Generated.swift")
        try GitFixture.write("let generated = 1\n", at: generated)
        try GitFixture.run(["add", "."], in: fixture.siblingRoot)
        try GitFixture.run(["commit", "-m", "baseline"], in: fixture.siblingRoot)

        let before = try Self.externalDigest(fixture)
        try GitFixture.write("let generated = 2\n", at: generated)
        #expect(try Self.externalDigest(fixture) != before)
    }

    @Test("Entries the sandbox copy excludes are not part of the digest")
    func excludedEntriesAreNotDigested() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let before = try Self.externalDigest(fixture)
        try GitFixture.write("build output\n", at: fixture.siblingRoot.appendingPathComponent(".build/debug/output.o"))
        try GitFixture.write("tool state\n", at: fixture.siblingRoot.appendingPathComponent(".mutantkit/state.json"))
        #expect(try Self.externalDigest(fixture) == before)
    }

    @Test("A symlink contributes its target text, and an empty directory counts")
    func symlinksAndEmptyDirectoriesAreDigested() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let link = fixture.siblingRoot.appendingPathComponent("Sources/Alias")

        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "SwiftMapper")
        let withLink = try Self.externalDigest(fixture)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "./SwiftMapper")
        #expect(try Self.externalDigest(fixture) != withLink)

        let beforeDirectory = try Self.externalDigest(fixture)
        try FileManager.default.createDirectory(
            at: fixture.siblingRoot.appendingPathComponent("Resources"), withIntermediateDirectories: true
        )
        #expect(try Self.externalDigest(fixture) != beforeDirectory)
    }

    /// "Equal digest implies equal sandbox bytes" holds only if the digest
    /// reads exactly the entries the copy receives.
    @Test("The digest reads exactly the entries the sandbox copy of the root receives")
    func digestCoversExactlyTheSandboxCopy() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let mapper = fixture.siblingRoot
        try GitFixture.write("ignored by nothing\n", at: mapper.appendingPathComponent("notes.txt"))
        try GitFixture.write("excluded\n", at: mapper.appendingPathComponent(".build/output.o"))
        try GitFixture.write("excluded\n", at: mapper.appendingPathComponent("Sources/run.log"))
        try FileManager.default.createDirectory(at: mapper.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: mapper.appendingPathComponent("Link").path, withDestinationPath: "Sources"
        )

        let digested = try RunInputState.contentEntries(
            of: mapper, scratchRoots: [fixture.scratchRoot], excludes: WorkspaceManager.defaultExcludes
        ).map { String($0.prefix { $0 != "=" }) }

        let workspaces = try WorkspaceManager(layout: fixture.layout, scratchRoot: fixture.scratchRoot)
        let sandbox = try await workspaces.createSandbox(id: "baseline")
        let copy = sandbox.containerRoot.appendingPathComponent(fixture.layout.externalRoots[0].relativePath)
        var copied: [String] = []
        try SandboxCopyWalk.walk(root: copy, excludes: [], skippingCanonicalPaths: []) { entry in
            copied.append(entry.kind == .directory ? entry.relativePath + "/" : entry.relativePath)
            return true
        }

        #expect(digested == copied)
        #expect(digested.contains("notes.txt"))
        #expect(digested.contains("Empty/"))
        #expect(digested.contains("Link"))
        #expect(!digested.contains { $0.hasPrefix(".build") || $0.hasSuffix(".log") })
    }

    @Test("An unreadable file in an external root disables the checkpoint and both caches")
    func unreadableExternalFileDisablesAllIdentities() async throws {
        let fixture = try Self.makeFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Self.lockedPath(fixture))
            try? FileManager.default.removeItem(at: fixture.parent)
        }
        try GitFixture.run(["add", "."], in: fixture.projectRoot)
        try GitFixture.run(["commit", "-m", "baseline"], in: fixture.projectRoot)
        try GitFixture.write("secret\n", at: URL(fileURLWithPath: Self.lockedPath(fixture)))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: Self.lockedPath(fixture))

        #expect(throws: RunContextProbeError.self) {
            _ = try RunInputState.externalPackageInputs(
                of: fixture.layout, scratchRoots: [fixture.scratchRoot], excludes: WorkspaceManager.defaultExcludes
            )
        }
        let state = await RunCommand.runInputState(
            root: fixture.projectRoot, layout: fixture.layout, scratchRoots: [fixture.scratchRoot],
            toolchainCacheIdentityComplete: true
        )
        #expect(state == nil)
        #expect(
            RunCommand.runIdentities(inputState: state, configuration: Configuration(), toolchain: makeToolchain(), workUnitID: "wu")
                == RunCommand.RunIdentities(checkpoint: nil, coverageCacheDigest: nil, resultCacheDigest: nil)
        )
    }

    static func lockedPath(_ fixture: Fixture) -> String {
        fixture.siblingRoot.appendingPathComponent("Sources/SwiftMapper/Locked.swift").path
    }

    @Test("An external root that vanished fails the state instead of hashing as empty")
    func vanishedExternalRootFails() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try FileManager.default.removeItem(at: fixture.siblingRoot)

        #expect(throws: RunContextProbeError.self) {
            _ = try RunInputState.externalPackageInputs(
                of: fixture.layout, scratchRoots: [fixture.scratchRoot], excludes: WorkspaceManager.defaultExcludes
            )
        }
    }

    /// Every identity folds in the whole state, not only the worktree: the
    /// project's place in the sandbox reaches compiled paths, and each
    /// external package's content reaches the build.
    @Test("Every identity moves with the workspace path and with each external input", arguments: [
        RunInputState(worktreeContentState: "w", workspaceRelativePath: "Apps/Core", externalPackageInputs: []),
        RunInputState(
            worktreeContentState: "w", workspaceRelativePath: "",
            externalPackageInputs: [ExternalPackageInput(relativeIdentity: "SwiftMapper", contentDigest: "d")]
        ),
        RunInputState(
            worktreeContentState: "w", workspaceRelativePath: "",
            externalPackageInputs: [ExternalPackageInput(relativeIdentity: "Mapper", contentDigest: "d")]
        )
    ])
    func everyIdentityFoldsInTheWholeState(changed: RunInputState) {
        let base = RunInputState(worktreeContentState: "w", workspaceRelativePath: "", externalPackageInputs: [])
        let identities = { (state: RunInputState) in
            RunCommand.runIdentities(inputState: state, configuration: Configuration(), toolchain: makeToolchain(), workUnitID: "wu")
        }
        let before = identities(base)
        let after = identities(changed)
        #expect(before.checkpoint != nil && before.coverageCacheDigest != nil && before.resultCacheDigest != nil)
        #expect(before.checkpoint != after.checkpoint)
        #expect(before.coverageCacheDigest != after.coverageCacheDigest)
        #expect(before.resultCacheDigest != after.resultCacheDigest)
    }
}
