@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Local-package discovery on hand-written `dump-package` output.
///
/// The walk still touches the disk (every reported package needs a
/// `Package.swift`, and symlinks are judged on the real tree), so each test
/// lays out empty packages in a temporary directory and scripts what
/// `dump-package` prints for each of them.
@Suite("SwiftPM local dependency resolver: decoding and walk")
struct SwiftPMLocalDependencyResolverTests {
    // MARK: - Fail-closed decoding

    @Test("Output that is not a JSON object is unreadable, not 'no local packages'")
    func nonObjectOutputFailsClosed() async throws {
        try await expectUnreadable(rootDump: "[]")
    }

    @Test("A manifest dump without `dependencies` is unreadable, not 'no local packages'")
    func missingDependenciesFailsClosed() async throws {
        try await expectUnreadable(rootDump: #"{"name":"Core"}"#)
    }

    @Test("An unknown dependency kind is unreadable: a future local kind would look exactly like this")
    func unknownDependencyKindFailsClosed() async throws {
        try await expectUnreadable(rootDump: #"{"dependencies":[{"localArchive":[{"path":"/tmp/x"}]}]}"#)
    }

    @Test("A dependency entry with more than one key is unreadable")
    func multiKeyEntryFailsClosed() async throws {
        try await expectUnreadable(
            rootDump: #"{"dependencies":[{"fileSystem":[{"path":"/tmp/x"}],"sourceControl":[{}]}]}"#
        )
    }

    @Test("An empty fileSystem entry is unreadable")
    func emptyFileSystemEntryFailsClosed() async throws {
        try await expectUnreadable(rootDump: #"{"dependencies":[{"fileSystem":[]}]}"#)
    }

    @Test("A fileSystem entry with more than one element is unreadable")
    func multiElementFileSystemEntryFailsClosed() async throws {
        try await expectUnreadable(
            rootDump: #"{"dependencies":[{"fileSystem":[{"path":"/tmp/a"},{"path":"/tmp/b"}]}]}"#
        )
    }

    @Test("A fileSystem path that is not a string is unreadable")
    func nonStringPathFailsClosed() async throws {
        try await expectUnreadable(rootDump: #"{"dependencies":[{"fileSystem":[{"path":3}]}]}"#)
    }

    @Test("A fileSystem path that is not absolute is unreadable")
    func relativePathFailsClosed() async throws {
        try await expectUnreadable(rootDump: #"{"dependencies":[{"fileSystem":[{"path":"../SwiftMapper"}]}]}"#)
    }

    @Test("Remote dependencies are skipped: they are resolved by the build, not copied")
    func remoteDependenciesAreSkipped() async throws {
        let tree = try PackageTree()
        defer { tree.remove() }
        let dumps = DumpScript([
            tree.path("Core"): .success(#"""
            {"dependencies":[
              {"sourceControl":[{"identity":"yams","location":{"remote":[{"urlString":"https://example.invalid/y.git"}]}}]},
              {"registry":[{"identity":"scope.name"}]}
            ]}
            """#)
        ])

        let closure = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))

        #expect(closure.isEmpty)
    }

    // MARK: - Walk

    @Test("Core -> SwiftMapper -> Logging: the transitive package is found by walking each manifest")
    func walksTransitively() async throws {
        let tree = try PackageTree(packages: ["Core", "SwiftMapper", "Logging"])
        defer { tree.remove() }
        let dumps = DumpScript([
            tree.path("Core"): .success(fileSystemDump(tree.path("SwiftMapper"))),
            tree.path("SwiftMapper"): .success(fileSystemDump(tree.path("Logging"))),
            tree.path("Logging"): .success(fileSystemDump())
        ])

        let closure = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))

        #expect(closure == [
            LocalPackageRoot(
                reportedPath: tree.path("Logging"), canonicalPath: tree.path("Logging"),
                declaredBy: tree.path("SwiftMapper")
            ),
            LocalPackageRoot(
                reportedPath: tree.path("SwiftMapper"), canonicalPath: tree.path("SwiftMapper"),
                declaredBy: tree.path("Core")
            )
        ])
    }

    @Test("A cycle between packages other than the project terminates and lists each once")
    func cycleTerminates() async throws {
        let tree = try PackageTree(packages: ["Core", "Left", "Right"])
        defer { tree.remove() }
        let dumps = DumpScript([
            tree.path("Core"): .success(fileSystemDump(tree.path("Left"))),
            tree.path("Left"): .success(fileSystemDump(tree.path("Right"))),
            tree.path("Right"): .success(fileSystemDump(tree.path("Left")))
        ])

        let closure = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))

        #expect(closure.map(\.canonicalPath) == [tree.path("Left"), tree.path("Right")])
        #expect(await dumps.calls == [tree.path("Core"), tree.path("Left"), tree.path("Right")])
    }

    @Test("A dependency on the project itself is refused, not deduplicated as a cycle")
    func directSelfDependencyIsRefused() async throws {
        let tree = try PackageTree(packages: ["Core"])
        defer { tree.remove() }
        let dumps = DumpScript([tree.path("Core"): .success(fileSystemDump(tree.path("Core")))])

        await #expect(throws: LocalPackageResolutionError.localPackageCyclesToProject(
            reportedPath: tree.path("Core"), projectRoot: tree.path("Core"), declaredBy: tree.path("Core")
        )) {
            _ = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))
        }
    }

    @Test("A chain of local dependencies that leads back to the project is refused, naming who closed it")
    func cycleBackToTheProjectIsRefused() async throws {
        let tree = try PackageTree(packages: ["Core", "SwiftMapper"])
        defer { tree.remove() }
        let dumps = DumpScript([
            tree.path("Core"): .success(fileSystemDump(tree.path("SwiftMapper"))),
            tree.path("SwiftMapper"): .success(fileSystemDump(tree.path("Core")))
        ])

        await #expect(throws: LocalPackageResolutionError.localPackageCyclesToProject(
            reportedPath: tree.path("Core"), projectRoot: tree.path("Core"), declaredBy: tree.path("SwiftMapper")
        )) {
            _ = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))
        }
    }

    @Test("A diamond lists the shared package once and evaluates its manifest once")
    func diamondIsDeduplicated() async throws {
        let tree = try PackageTree(packages: ["Core", "Left", "Right", "Shared"])
        defer { tree.remove() }
        // The second spelling of Shared has a trailing slash, which SwiftPM
        // drops; the walk must still see one package.
        let dumps = DumpScript([
            tree.path("Core"): .success(fileSystemDump(tree.path("Left"), tree.path("Right"))),
            tree.path("Left"): .success(fileSystemDump(tree.path("Shared"))),
            tree.path("Right"): .success(fileSystemDump(tree.path("Shared") + "/")),
            tree.path("Shared"): .success(fileSystemDump())
        ])

        let closure = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))

        #expect(closure.map(\.canonicalPath) == [tree.path("Left"), tree.path("Right"), tree.path("Shared")])
        #expect(await dumps.calls.count(where: { $0 == tree.path("Shared") }) == 1)
    }

    @Test("A dependency without a Package.swift fails closed, naming the manifest that declared it")
    func missingPackageFailsClosed() async throws {
        let tree = try PackageTree()
        defer { tree.remove() }
        let dumps = DumpScript([tree.path("Core"): .success(fileSystemDump(tree.path("SwiftMapper")))])

        await #expect(throws: LocalPackageResolutionError.missingLocalPackage(
            reportedPath: tree.path("SwiftMapper"), declaredBy: tree.path("Core")
        )) {
            _ = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))
        }
    }

    @Test("A dependency reached through a symbolic link is refused")
    func symlinkedPackageIsRefused() async throws {
        let tree = try PackageTree(packages: ["Core", "Real/SwiftMapper"])
        defer { tree.remove() }
        try FileManager.default.createSymbolicLink(
            atPath: tree.path("SMLink"), withDestinationPath: tree.path("Real/SwiftMapper")
        )
        let dumps = DumpScript([tree.path("Core"): .success(fileSystemDump(tree.path("SMLink")))])

        await #expect(throws: LocalPackageResolutionError.symlinkedLocalPackage(
            reportedPath: tree.path("SMLink"),
            canonicalPath: tree.path("Real/SwiftMapper"),
            declaredBy: tree.path("Core")
        )) {
            _ = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))
        }
    }

    @Test("A dependency that contains the project is refused, not silently skipped")
    func packageContainingTheProjectIsRefused() async throws {
        let tree = try PackageTree(packages: ["Core"])
        defer { tree.remove() }
        // `.package(path: "..")` from Core: the directory around it is a package too.
        try Data("// empty\n".utf8).write(to: tree.url("Package.swift"))
        let dumps = DumpScript([tree.path("Core"): .success(fileSystemDump(tree.root.path))])

        await #expect(throws: LocalPackageResolutionError.localPackageContainsProject(
            reportedPath: tree.root.path, projectRoot: tree.path("Core"), declaredBy: tree.path("Core")
        )) {
            _ = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))
        }
    }

    @Test("A transitive dependency that contains the project is refused too, naming who declared it")
    func transitivePackageContainingTheProjectIsRefused() async throws {
        let tree = try PackageTree(packages: ["Core", "Mid"])
        defer { tree.remove() }
        try Data("// empty\n".utf8).write(to: tree.url("Package.swift"))
        let dumps = DumpScript([
            tree.path("Core"): .success(fileSystemDump(tree.path("Mid"))),
            tree.path("Mid"): .success(fileSystemDump(tree.root.path))
        ])

        await #expect(throws: LocalPackageResolutionError.localPackageContainsProject(
            reportedPath: tree.root.path, projectRoot: tree.path("Core"), declaredBy: tree.path("Mid")
        )) {
            _ = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))
        }
    }

    @Test("A package inside the project is not an ancestor and is listed like any other local package")
    func packageInsideTheProjectIsNotRefused() async throws {
        let tree = try PackageTree(packages: ["Core", "Core/Vendor/Inner"])
        defer { tree.remove() }
        let dumps = DumpScript([
            tree.path("Core"): .success(fileSystemDump(tree.path("Core/Vendor/Inner"))),
            tree.path("Core/Vendor/Inner"): .success(fileSystemDump())
        ])

        let closure = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))

        #expect(closure.map(\.canonicalPath) == [tree.path("Core/Vendor/Inner")])
    }

    @Test("A sibling whose name shares a prefix with the project is not an ancestor")
    func siblingWithSharedPrefixIsNotAnAncestor() async throws {
        let tree = try PackageTree(packages: ["Core", "Core2"])
        defer { tree.remove() }
        let dumps = DumpScript([
            tree.path("Core"): .success(fileSystemDump(tree.path("Core2"))),
            tree.path("Core2"): .success(fileSystemDump())
        ])

        let closure = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))

        #expect(closure.map(\.canonicalPath) == [tree.path("Core2")])
    }

    @Test("A project opened through a symlinked parent is evaluated at its canonical path, with no symlink refusal")
    func projectOpenedThroughAliasIsNotRefused() async throws {
        let tree = try PackageTree(packages: ["Core", "SwiftMapper"])
        defer { tree.remove() }
        let alias = tree.root.deletingLastPathComponent()
            .appendingPathComponent("alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: tree.root)
        defer { try? FileManager.default.removeItem(at: alias) }
        // SwiftPM reports paths below the canonical manifest directory.
        let dumps = DumpScript([
            tree.path("Core"): .success(fileSystemDump(tree.path("SwiftMapper"))),
            tree.path("SwiftMapper"): .success(fileSystemDump())
        ])

        let closure = try await tree.resolver(dumps)
            .localPackageClosure(of: alias.appendingPathComponent("Core", isDirectory: true))

        #expect(closure.map(\.canonicalPath) == [tree.path("SwiftMapper")])
        #expect(closure.map(\.declaredBy) == [tree.path("Core")])
        #expect(await dumps.calls == [tree.path("Core"), tree.path("SwiftMapper")])
    }

    // MARK: - The shared dump runner

    @Test("A truncated capture is retried once, and the retry's output is used")
    func truncatedCaptureIsRetried() async throws {
        let tree = try PackageTree(packages: ["Core", "SwiftMapper"])
        defer { tree.remove() }
        let dumps = DumpScript([
            tree.path("Core"): .truncatedThen(fileSystemDump(tree.path("SwiftMapper"))),
            tree.path("SwiftMapper"): .success(fileSystemDump())
        ])

        let closure = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))

        #expect(closure.map(\.canonicalPath) == [tree.path("SwiftMapper")])
        #expect(await dumps.calls == [tree.path("Core"), tree.path("Core"), tree.path("SwiftMapper")])
    }

    @Test("A failing dependency manifest fails the walk")
    func failingDependencyManifestFailsClosed() async throws {
        let tree = try PackageTree(packages: ["Core", "SwiftMapper"])
        defer { tree.remove() }
        let dumps = DumpScript([tree.path("Core"): .success(fileSystemDump(tree.path("SwiftMapper")))])

        await #expect(throws: ProjectDetectionError.self) {
            _ = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))
        }
    }

    @Test("Project detection and discovery share one evaluation of the project manifest")
    func projectManifestIsEvaluatedOnce() async throws {
        let tree = try PackageTree(packages: ["Core", "SwiftMapper"])
        defer { tree.remove() }
        let dumps = DumpScript([
            tree.path("Core"): .success(fileSystemDump(tree.path("SwiftMapper"))),
            tree.path("SwiftMapper"): .success(fileSystemDump())
        ])
        let shared = SwiftPMManifestDumps()

        let platforms = try await ProjectDetector.declaredPlatforms(
            in: tree.url("Core"), timeoutSeconds: 5, manifestDumps: shared, processRunner: dumps.runner
        )
        let closure = try await SwiftPMLocalDependencyResolver(
            timeoutSeconds: 5, manifestDumps: shared, processRunner: dumps.runner
        ).localPackageClosure(of: tree.url("Core"))

        #expect(platforms.isEmpty)
        #expect(closure.count == 1)
        #expect(await dumps.calls == [tree.path("Core"), tree.path("SwiftMapper")])
    }

    // MARK: - Helpers

    private func expectUnreadable(rootDump: String) async throws {
        let tree = try PackageTree()
        defer { tree.remove() }
        let dumps = DumpScript([tree.path("Core"): .success(rootDump)])

        await #expect(throws: ProjectDetectionError.self) {
            _ = try await tree.resolver(dumps).localPackageClosure(of: tree.url("Core"))
        }
    }
}

/// The resolver against the real toolchain.
@Suite("SwiftPM local dependency resolver: real dump-package", .subprocessExclusive)
struct SwiftPMLocalDependencyResolverToolchainTests {
    @Test("Core -> ../SwiftMapper -> ../Logging resolves both siblings with their declaring manifests")
    func siblingChain() async throws {
        let layoutRoot = try LocalPackageFixture.makeLayoutRoot(label: "resolver-chain")
        defer { try? FileManager.default.removeItem(at: layoutRoot) }
        let core = try LocalPackageFixture.writeSiblingChain(in: layoutRoot)
        let canonical = try #require(CanonicalPath.resolve(layoutRoot.path))

        let closure = try await SwiftPMLocalDependencyResolver().localPackageClosure(of: core)

        #expect(closure == [
            LocalPackageRoot(
                reportedPath: canonical + "/Logging", canonicalPath: canonical + "/Logging",
                declaredBy: canonical + "/SwiftMapper"
            ),
            LocalPackageRoot(
                reportedPath: canonical + "/SwiftMapper", canonicalPath: canonical + "/SwiftMapper",
                declaredBy: canonical + "/Core"
            )
        ])
    }

    @Test("A manifest that branches on the environment is evaluated with the environment the build gets")
    func environmentDependentManifest() async throws {
        let (name, value) = try #require(
            ProcessInfo.processInfo.environment.first { $0.key == "HOME" && !$0.value.isEmpty }
        )
        let layoutRoot = try LocalPackageFixture.makeLayoutRoot(label: "resolver-env")
        defer { try? FileManager.default.removeItem(at: layoutRoot) }
        let core = layoutRoot.appendingPathComponent("Core", isDirectory: true)
        try LocalPackageFixture.writePackage(named: "Core", at: core)
        try LocalPackageFixture.writePackage(named: "Extra", at: layoutRoot.appendingPathComponent("Extra"))
        let manifest = """
        // swift-tools-version:5.9
        import Foundation
        import PackageDescription

        var dependencies: [Package.Dependency] = []
        if ProcessInfo.processInfo.environment[\(String(reflecting: name))] == \(String(reflecting: value)) {
            dependencies.append(.package(path: "../Extra"))
        }

        let package = Package(
            name: "Core",
            dependencies: dependencies,
            targets: [.target(name: "Core")]
        )
        """
        try Data(manifest.utf8).write(to: core.appendingPathComponent("Package.swift"))
        let canonical = try #require(CanonicalPath.resolve(layoutRoot.path))

        let closure = try await SwiftPMLocalDependencyResolver().localPackageClosure(of: core)

        #expect(closure.map(\.canonicalPath) == [canonical + "/Extra"])
    }
}

// MARK: - Support

/// Empty packages (a `Package.swift` and nothing else) under a canonical
/// temporary root.
private struct PackageTree {
    let root: URL

    init(packages: [String] = ["Core"]) throws {
        let created = try LocalPackageFixture.makeLayoutRoot(label: "resolver")
        root = URL(fileURLWithPath: CanonicalPath.resolve(created.path) ?? created.path, isDirectory: true)
        for package in packages {
            let directory = url(package)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("// empty\n".utf8).write(to: directory.appendingPathComponent("Package.swift"))
        }
    }

    func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative, isDirectory: true)
    }

    func path(_ relative: String) -> String {
        root.path + "/" + relative
    }

    func resolver(_ dumps: DumpScript) -> SwiftPMLocalDependencyResolver {
        SwiftPMLocalDependencyResolver(
            timeoutSeconds: 5, manifestDumps: SwiftPMManifestDumps(), processRunner: dumps.runner
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// `dump-package` output with the given local path dependencies.
private func fileSystemDump(_ paths: String...) -> String {
    let entries = paths.map { path in
        #"{"fileSystem":[{"identity":"x","path":\#(String(reflecting: path)),"productFilter":null}]}"#
    }
    return #"{"name":"P","dependencies":[\#(entries.joined(separator: ","))]}"#
}

/// What `dump-package` prints in each directory, and every directory it was
/// run in, in order.
private actor DumpScript {
    enum Reply {
        case success(String)
        /// A truncated capture first, then this output.
        case truncatedThen(String)
    }

    private var replies: [String: Reply]
    private(set) var calls: [String] = []

    init(_ replies: [String: Reply]) {
        self.replies = replies
    }

    nonisolated var runner: ProcessRunner {
        { _, _, workingDirectory, _ in await self.reply(in: workingDirectory.path) }
    }

    private func reply(in directory: String) -> ProcessResult {
        calls.append(directory)
        switch replies[directory] {
        case let .success(output):
            return Self.result(exitCode: 0, output: output, complete: true)
        case let .truncatedThen(output):
            replies[directory] = .success(output)
            return Self.result(exitCode: 1, output: "", complete: false)
        case nil:
            return Self.result(exitCode: 1, output: "", complete: true)
        }
    }

    private static func result(exitCode: Int32, output: String, complete: Bool) -> ProcessResult {
        ProcessResult(
            exitCode: exitCode,
            standardOutput: Data(output.utf8),
            standardError: Data((exitCode == 0 ? "" : "error: no manifest here").utf8),
            durationSeconds: 0.01,
            timedOut: false,
            terminatingSignal: nil,
            outputComplete: complete
        )
    }
}
