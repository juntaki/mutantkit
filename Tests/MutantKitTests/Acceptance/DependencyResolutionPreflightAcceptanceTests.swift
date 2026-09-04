import AppleBuildAdapters
@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Real-toolchain proof for adversarial-review finding #3 on the
/// `retestKilledMutants`/`PackageManifestConfirmationRetesting` fix.
///
/// The reviewer constructed a fixture with a real manifest, real sources,
/// and a real (never-before-resolved) dependency, and found that
/// `swift test --skip-build --package-path <pristine> --scratch-path
/// <clone>` — `PackageManifestConfirmationRetesting.runConfirmationRetest`'s
/// own invocation shape — performs SwiftPM's *first-ever* dependency
/// resolution directly against `--package-path`, writing a fresh
/// `Package.resolved` into the tool's own stable, read-only original
/// project copy: a real, unexpected write to the user's live tree, and the
/// opposite of "the original tree is only ever read"
/// (`WorkspaceManager.populate`'s own stated contract).
///
/// `RunCommand.resolveDependenciesForConfirmationRetestIfNeeded` fixes this
/// by resolving once, explicitly, and up front — this suite proves that
/// fix for real: a pristine project (real remote dependency, genuinely
/// never resolved before this test staged it) gets its `Package.resolved`
/// written by the *preflight*, before any mutation testing could possibly
/// begin, not by a later confirmation retest.
///
/// A real remote dependency (`swift-numerics`, already used elsewhere in
/// this project's own benchmark corpora — see `Benchmarks/manifest.json`)
/// is required to reproduce the reviewer's own finding faithfully: a local
/// `.package(path:)` dependency never produces a `Package.resolved` at
/// all (confirmed empirically while building this fix), so it cannot stand
/// in for the real, reachable bug. Acceptance-gated, like every other
/// suite in this directory, specifically because of the network
/// dependency — SwiftPM's own local package cache makes a repeat resolve
/// fast (a few seconds) once fetched once, but a fetch should never be
/// forced on the default, always-on `swift test` run.
/// `.subprocessExclusive`: spawns a real `swift package resolve`.
@Suite(
    "Acceptance: dependency-resolution preflight writes Package.resolved up front, not inside a deferred confirmation retest",
    .enabled(if: Acceptance.isEnabled), .subprocessExclusive
)
struct DependencyResolutionPreflightAcceptanceTests {
    private func stagePristinePackageWithRealDependency() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-dep-resolve-preflight-\(UUID().uuidString)")
        let sourcesDirectory = directory.appendingPathComponent("Sources/DepResolvePreflightFixture")
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "DepResolvePreflightFixture",
            platforms: [.macOS(.v14)],
            dependencies: [.package(url: "https://github.com/apple/swift-numerics.git", from: "1.0.0")],
            targets: [
                .target(name: "DepResolvePreflightFixture", dependencies: [.product(name: "Numerics", package: "swift-numerics")])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data("import Numerics\npublic func f() {}\n".utf8)
            .write(to: sourcesDirectory.appendingPathComponent("Widget.swift"))
        return directory
    }

    @Test("retestKilledMutants: true resolves a pristine project's dependencies up front, writing Package.resolved into projectRoot")
    func preflightResolvesUpFrontForAPristineProject() async throws {
        let projectDirectory = try stagePristinePackageWithRealDependency()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let resolvedManifestPath = projectDirectory.appendingPathComponent("Package.resolved")
        #expect(
            !FileManager.default.fileExists(atPath: resolvedManifestPath.path),
            "sanity check: this fixture must genuinely be pristine, or this test proves nothing"
        )

        let configuration = Configuration(execution: ExecutionSettings(retestKilledMutants: true))
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)

        try await RunCommand.resolveDependenciesForConfirmationRetestIfNeeded(
            configuration, testAdapter: adapter, root: projectDirectory
        )

        #expect(
            FileManager.default.fileExists(atPath: resolvedManifestPath.path),
            "the preflight must have resolved and written Package.resolved into projectRoot itself"
        )
        let resolvedContents = try String(contentsOf: resolvedManifestPath, encoding: .utf8)
        #expect(
            resolvedContents.contains("swift-numerics"),
            "must be a genuine resolution of the real declared dependency, not an incidental empty file: \(resolvedContents)"
        )
    }

    @Test("retestKilledMutants: false never resolves — a project with no confirmation retest in its future stays untouched")
    func noPreflightWhenRetestKilledMutantsIsOff() async throws {
        let projectDirectory = try stagePristinePackageWithRealDependency()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let resolvedManifestPath = projectDirectory.appendingPathComponent("Package.resolved")
        let configuration = Configuration(execution: ExecutionSettings(retestKilledMutants: false))
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)

        try await RunCommand.resolveDependenciesForConfirmationRetestIfNeeded(
            configuration, testAdapter: adapter, root: projectDirectory
        )

        #expect(
            !FileManager.default.fileExists(atPath: resolvedManifestPath.path),
            "must be a true no-op when nothing downstream could ever trigger a confirmation retest against projectRoot"
        )
    }
}
