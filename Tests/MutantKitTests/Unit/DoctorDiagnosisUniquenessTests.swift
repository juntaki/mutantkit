@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Pins the exact silent-duplication bug this lane's own review found:
/// `DoctorCommand.run()` appends `Self.sharedModuleCacheDiagnosis(...)` to
/// `ReadinessCheck.diagnose`'s own items *after* that function's own
/// `deduplicated(...)` pass has already run (see both call sites' own doc
/// comments) — so a `DiagnosisItem` produced by `ReadinessCheck.diagnose`
/// and a same-named one appended afterward would both survive into the
/// final `mutantkit doctor` report unless the append site re-runs dedup
/// over the combined list.
///
/// This lane originally shipped its own `sharedModuleCacheSupport`
/// execution-capabilities item, computed inside `ReadinessCheck.diagnose`
/// itself (via `ExecutionCapabilitiesDiagnosis`) — which, unnoticed until
/// review, would have collided under the same "Shared module cache" name
/// with S1's own, separately-landed `sharedModuleCache` item appended here.
/// That duplicate reimplementation is now deleted (S1's is the one real
/// implementation), so the collision cannot occur today with real code —
/// this suite instead exercises the composition mechanism directly, so a
/// *future* same-named addition on either side of the append is still
/// caught rather than silently shipping two lines with one name.
@Suite("Doctor diagnosis: no duplicate item names across a full doctor run")
struct DoctorDiagnosisUniquenessTests {
    @Test("A real doctor run (ReadinessCheck.diagnose + DoctorCommand's own append) has no two DiagnosisItems sharing a name")
    func fullDoctorRunHasUniqueDiagnosisNames() async throws {
        let dir = try makeMinimalPackageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = await ReadinessCheck.run(root: dir, configPath: nil, skipBuild: true)
        let combined = ReadinessCheck.deduplicated(
            outcome.diagnosis.items + [await DoctorCommand.sharedModuleCacheDiagnosis(root: dir, configuration: outcome.configuration)]
        )

        let names = combined.map(\.name)
        #expect(Set(names).count == names.count, "duplicate DiagnosisItem names in a real doctor run: \(names)")
        #expect(combined.filter { $0.name == "Shared module cache" }.count == 1, "\(names)")
    }

    /// The mechanism itself, independent of what real code happens to
    /// produce today: two same-named items — one standing in for
    /// whatever `ReadinessCheck.diagnose` produced, one for whatever
    /// `DoctorCommand` appends afterward — must collapse to one survivor
    /// when `deduplicated(...)` runs over the combined list, the exact
    /// composition `DoctorCommand.run()` now performs.
    @Test("deduplicated(...) collapses a same-named item appended after an earlier dedup pass, not only items dedup'd together at once")
    func deduplicatedCollapsesAcrossTwoCompositionStages() {
        let firstPassItems = ReadinessCheck.deduplicated([
            DiagnosisItem(name: "Shared module cache", status: .ok, code: .sharedModuleCache, detail: "from ReadinessCheck.diagnose"),
            DiagnosisItem(name: "Swift", status: .ok, code: .swiftToolchain, detail: "6.0")
        ])

        let appendedAfterwards = DiagnosisItem(
            name: "Shared module cache", status: .ok, code: .sharedModuleCache, detail: "from DoctorCommand's own append"
        )

        let combined = ReadinessCheck.deduplicated(firstPassItems + [appendedAfterwards])

        #expect(combined.filter { $0.name == "Shared module cache" }.count == 1, "\(combined.map(\.name))")
        // First-produced wins, matching `deduplicated`'s own documented
        // "collapse to the first, more severe report of each fact" rule.
        #expect(combined.first { $0.name == "Shared module cache" }?.detail == "from ReadinessCheck.diagnose")
    }

    // MARK: - Helpers

    /// A minimal `Package.swift` is enough for `ProjectDetector` to resolve
    /// a real `swiftPackageMacOS` project without ever invoking `swift
    /// build` — `skipBuild: true` keeps this fixture fast and offline, the
    /// same shape `DoctorCommandJSONTests` already uses.
    private func makeMinimalPackageFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoctorDiagnosisUniquenessTests-\(UUID().uuidString)")
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
