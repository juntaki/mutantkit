@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("BenchmarkPreflight")
struct BenchmarkPreflightTests {
    @Test("A project whose baseline build fails is classified projectBaselineBuildFailed")
    func baselineBuildFailureIsClassified() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mutantbench-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // No Package.swift at all — `swift build` fails immediately, a
        // real (if trivial) reproduction of a broken baseline build.
        let project = BenchmarkProject(
            id: "broken", repositoryURL: "https://example.com/x.git", commitSHA: String(repeating: "a", count: 40), projectKind: .swiftPackage
        )
        let materialized = MaterializedBenchmarkProject(project: project, directory: directory)

        let preflight = BenchmarkPreflight()
        let result = try await preflight.checkBaseline(project: materialized)
        #expect(!result.succeeded)
        #expect(result.failure == .projectBaselineBuildFailed)
        #expect(result.command == "swift build --build-tests")
    }

    @Test("BenchmarkEnvironment produces a filesystem-safe identifier")
    func environmentIdentifierIsFilesystemSafe() {
        let environment = BenchmarkEnvironment(
            macOSVersion: "14.5.0", architecture: "arm64", swiftVersion: "swift-driver version: 1.0 (swift 6.0)"
        )
        let identifier = environment.identifier
        #expect(!identifier.contains(" "))
        #expect(!identifier.contains(":"))
        #expect(!identifier.contains("("))
    }

    @Test("The real current environment resolves a non-empty Swift version")
    func currentEnvironmentResolvesRealSwiftVersion() {
        let environment = BenchmarkPreflight.currentEnvironment()
        #expect(!environment.swiftVersion.isEmpty)
        #expect(!environment.macOSVersion.isEmpty)
    }

    @Test("A PreflightStageResult failure carries the classification, command, exit code, and a bounded output excerpt")
    func failedStageCarriesDiagnostics() {
        let hugeOutput = String(repeating: "x", count: 5000)
        let result = PreflightStageResult.failed(.toolCompilationFailed, command: "swift build", exitCode: 1, output: hugeOutput)
        #expect(result.failure == .toolCompilationFailed)
        #expect(result.command == "swift build")
        #expect(result.exitCode == 1)
        #expect((result.outputExcerpt?.count ?? 0) <= 2000, "the excerpt must be bounded, not the full raw output")
    }
}
