import ArgumentParser
@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// P11: `mutantkit doctor --json`. `BuildDiagnosis` is already fully computed
/// before either output path renders it — `DoctorCommand.run()` only branches
/// on `outcome.diagnosis.canProceed` — so `--json` just serializes it, with
/// the `schemaVersion` `BuildDiagnosis` now carries. Mirrors
/// `GateCommandJSONTests`' shape exactly, down to the reasoning for what
/// these tests do and don't cover.
///
/// The JSON-shape tests below run the real `ReadinessCheck.run` (not a
/// hand-built `BuildDiagnosis`) against two small fixture directories — one
/// with a valid `Package.swift` (ready), one empty (not ready) — the same
/// way `GateCommandJSONTests` feeds `QualityGate.evaluate`'s real output
/// into its shape assertions rather than a literal. `--skip-build` keeps
/// both fixtures fast: project *detection* needs no real `swift build`.
///
/// As with `GateCommandJSONTests`, these avoid capturing `DoctorCommand`'s
/// own stdout (no precedent for shared-fd capture in this repo); the
/// command-level tests below instead confirm `--json` doesn't disturb the
/// exit-code contract, in both directions.
@Suite("DoctorCommand: --json")
struct DoctorCommandJSONTests {
    // MARK: - JSON shape

    @Test("--json's JSON is schema-versioned and reports canProceed true for a ready project")
    func readyDiagnosisJSONShape() async throws {
        let dir = try makeMinimalPackageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = await ReadinessCheck.run(root: dir, configPath: nil, skipBuild: true)
        #expect(outcome.diagnosis.canProceed)

        let data = try MutationPlan.encoder().encode(outcome.diagnosis)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["schemaVersion"] as? Int == SchemaVersion.buildDiagnosis)
        #expect(json["canProceed"] as? Bool == true)
        let items = try #require(json["items"] as? [[String: Any]])
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0["name"] != nil && $0["status"] != nil && $0["detail"] != nil })
        #expect(!items.contains { $0["status"] as? String == "failure" })

        let decoded = try MutationPlan.decoder().decode(BuildDiagnosis.self, from: data)
        #expect(decoded.canProceed == outcome.diagnosis.canProceed)
        #expect(decoded.items.count == outcome.diagnosis.items.count)
    }

    @Test("--json's JSON is schema-versioned and reports canProceed false with a failure item for an unresolvable project")
    func notReadyDiagnosisJSONShape() async throws {
        let dir = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = await ReadinessCheck.run(root: dir, configPath: nil, skipBuild: true)
        #expect(!outcome.diagnosis.canProceed)

        let data = try MutationPlan.encoder().encode(outcome.diagnosis)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try #require(json["items"] as? [[String: Any]])

        #expect(json["schemaVersion"] as? Int == SchemaVersion.buildDiagnosis)
        #expect(json["canProceed"] as? Bool == false)
        #expect(items.contains { $0["status"] as? String == "failure" })

        let decoded = try MutationPlan.decoder().decode(BuildDiagnosis.self, from: data)
        #expect(decoded.canProceed == false)
    }

    // MARK: - Exit codes still hold with --json

    @Test("doctor --json against a ready project exits 0, same as the text path")
    func readyDoctorJSONDoesNotThrow() async throws {
        let dir = try makeMinimalPackageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let command = try DoctorCommand.parse(["--skip-build", "--json", "--project-root", dir.path])
        try await command.run()
    }

    @Test("doctor --json against an unresolvable project still exits MutantKitExit.operationalError")
    func notReadyDoctorJSONStillThrowsOperationalError() async throws {
        let dir = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let command = try DoctorCommand.parse(["--skip-build", "--json", "--project-root", dir.path])

        await #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try await command.run()
        }
    }

    // MARK: - Helpers

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DoctorCommandJSONTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEmptyFixture() throws -> URL {
        try makeScratchDirectory()
    }

    /// A minimal `Package.swift` is enough for `ProjectDetector` to resolve a
    /// real `swiftPackageMacOS` project without ever invoking `swift build` —
    /// `--skip-build` keeps the trial build itself out of the picture, so
    /// this fixture stays fast and offline.
    private func makeMinimalPackageFixture() throws -> URL {
        let dir = try makeScratchDirectory()
        let sourcesDir = dir.appendingPathComponent("Sources/Mini")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "Mini",
            platforms: [.macOS(.v13)],
            targets: [.target(name: "Mini")]
        )
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public func hello() -> String { \"hi\" }"
            .write(to: sourcesDir.appendingPathComponent("Mini.swift"), atomically: true, encoding: .utf8)
        return dir
    }
}
