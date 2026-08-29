import ArgumentParser
@testable import CLI
import Foundation
import Testing

/// `mutantkit setup --dry-run`'s exit code must genuinely reflect whether
/// the *previewed* config would pass readiness — not always report success
/// just because nothing was written. Drives the real `SetupCommand` in
/// process (`@testable import CLI`, no subprocess) against a bare directory
/// so the previewed config's own readiness diagnosis is a real one, not a
/// stand-in.
@Suite("SetupCommand --dry-run: exit code reflects the previewed config's real readiness")
struct SetupCommandDryRunReadinessTests {
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-SetupDryRun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("dry-run against a project detection cannot resolve at all exits non-zero, not silently 0")
    func dryRunFailsWhenPreviewedConfigIsNotReady() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A bare directory with no workspace, project, or Package.swift:
        // `ProjectDetectionPlan` can only write a `kind: auto` template here,
        // and readiness cannot resolve `kind: auto` against nothing on disk
        // — a real, previewed-config failure, not a contrived one.
        let command = try SetupCommand.parse(["--dry-run", "--skip-build", "--project-root", directory.path])

        do {
            try await command.run()
            Issue.record("expected setup --dry-run to fail against an unresolvable preview, but it exited 0")
        } catch let exitCode as ExitCode {
            #expect(exitCode.rawValue == MutantKitExit.operationalError)
        }

        #expect(
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent("mutantkit.yml").path),
            "--dry-run must never write, whether or not the preview is ready"
        )
    }

    @Test("dry-run against a project detection resolves cleanly does not fail spuriously")
    func dryRunSucceedsWhenPreviewedConfigIsReady() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A minimal, real SwiftPM package: `ProjectDetectionPlan` detects
        // `swiftPackageMacOS` explicitly, which resolves without touching
        // `xcodebuild`/`simctl` at all, so this stays fast and hermetic.
        try Data("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Bare", targets: [.target(name: "Bare")])
        """.utf8).write(to: directory.appendingPathComponent("Package.swift"), options: .atomic)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Sources/Bare"), withIntermediateDirectories: true
        )
        try Data("public func bare() {}".utf8)
            .write(to: directory.appendingPathComponent("Sources/Bare/Bare.swift"), options: .atomic)

        let command = try SetupCommand.parse(["--dry-run", "--skip-build", "--project-root", directory.path])
        try await command.run()

        #expect(
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent("mutantkit.yml").path),
            "--dry-run must never write"
        )
    }
}
