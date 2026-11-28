import ArgumentParser
@testable import CLI
import Foundation
import MutationModel
import Testing

/// `reproduce` writes a mutation into a sandbox file named by the plan. A plan is
/// data: a crafted or stale `point.file` must not reach outside the sandbox, the
/// same guarantee `WorkspaceManager.resolveSourceURL` gives `mutantkit run`.
@Suite("Reproduce source containment")
struct ReproduceSourceContainmentTests {
    private static let source = """
    struct Example {
        func isReady() -> Bool { return true }
    }
    """

    @Test("A plan path that leaves the sandbox through a symlink is rejected before anything is written")
    func symlinkEscapeIsRejectedAndNothingOutsideChanges() async throws {
        try await assertEscapeRejected { _ in "Sources/App/link/victim.swift" }
    }

    @Test("A plan path that leaves the sandbox by traversal is rejected before anything is written")
    func traversalEscapeIsRejectedAndNothingOutsideChanges() async throws {
        try await assertEscapeRejected { victim in String(repeating: "../", count: 40) + victim.path }
    }

    private func assertEscapeRejected(planFile: (URL) -> String) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-ReproduceContainment-\(UUID().uuidString)")
        let project = dir.appendingPathComponent("project")
        let outside = dir.appendingPathComponent("outside")
        let fm = FileManager.default
        try fm.createDirectory(at: project.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let manifest = "// swift-tools-version: 5.9\nimport PackageDescription\n"
            + "let package = Package(name: \"App\", targets: [.target(name: \"App\")])\n"
        try Data(manifest.utf8)
            .write(to: project.appendingPathComponent("Package.swift"))
        try Data(Self.source.utf8).write(to: project.appendingPathComponent("Sources/App/App.swift"))
        try Data("version: 1\nproject:\n  kind: swiftPackageMacOS\nsources:\n  include: [Sources/**]\n".utf8)
            .write(to: project.appendingPathComponent("mutantkit.yml"))

        let victim = outside.appendingPathComponent("victim.swift")
        try Data(Self.source.utf8).write(to: victim)
        try fm.createSymbolicLink(
            at: project.appendingPathComponent("Sources/App/link"), withDestinationURL: outside
        )

        let point = try makeAnchoredPoint(file: planFile(victim))
        let planURL = dir.appendingPathComponent("plan.json")
        try makePlan(mutations: [point]).encoded().write(to: planURL)

        let command = try ReproduceCommand.parse([
            point.id.rawValue, "--plan", planURL.path, "--project-root", project.path
        ])
        await #expect(throws: ExitCode(MutantKitExit.integrityFailure)) {
            try await command.run()
        }

        #expect(try Data(contentsOf: victim) == Data(Self.source.utf8), "a file outside the sandbox was modified")
    }
}
