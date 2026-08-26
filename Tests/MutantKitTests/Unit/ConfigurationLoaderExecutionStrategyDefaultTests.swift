@testable import CLI
import Foundation
import MutationModel
import Testing

/// Gate 3 Phase H18: pins the iOS execution architecture decision (Phase
/// H17, following Phase H16's own real-production-app measurement — schemata-first
/// +62.5% slower than optimized isolated at 100 mutants, a widening gap,
/// not a narrowing one) at the code level, not just as prose in a research
/// document.
///
/// The investigation behind this phase found there was nothing to
/// *implement*: `ExecutionSettings.strategy`'s own decode default is
/// already `.isolated` (`Configuration.swift`'s `Decodable` initializer:
/// `try container.decodeIfPresent(ExecutionMode.self, forKey: .strategy) ??
/// .isolated`), uniformly, for every `ProjectKind` — the type has no
/// project-kind-aware branching for this field at all — and
/// `ConfigurationLoader.template(for:...)` (what `mutantkit init` writes)
/// already emits `strategy: isolated` explicitly, again for every project
/// kind, with a comment already explaining why isolated is the reference
/// mode. `RunCommand.execute(strategy:...)` is a plain switch on whatever
/// the loaded configuration says, with no auto-detection or heuristic
/// override anywhere in between.
///
/// This suite exists to keep that fact pinned, not to fix a bug — a
/// regression guard against a future change silently making schemata the
/// default for some project kind without anyone deciding that on purpose.
@Suite("ConfigurationLoader: execution.strategy default (Gate 3 Phase H18)")
struct ConfigurationLoaderExecutionStrategyDefaultTests {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-strategy-default-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeConfig(_ yaml: String, in directory: URL) throws {
        try Data(yaml.utf8).write(to: directory.appendingPathComponent(ConfigurationLoader.fileName))
    }

    private func loadStrategy(_ yaml: String) throws -> ExecutionMode {
        let directory = makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeConfig(yaml, in: directory)
        let configuration = try ConfigurationLoader.load(explicitPath: nil, projectRoot: directory, environment: [:])
        return configuration.execution.strategy
    }

    private func projectBlock(kind: String) -> String {
        """
        version: 1
        project:
          kind: \(kind)
        """
    }

    // MARK: - Default (no execution.strategy key at all)

    @Test("Xcode project, no execution.strategy at all: defaults to isolated")
    func xcodeProjectDefaultIsIsolated() throws {
        #expect(try loadStrategy(projectBlock(kind: "xcodeProject")) == .isolated)
    }

    @Test("Xcode workspace (the same kind an iOS-Simulator project resolves through), no execution.strategy at all: defaults to isolated")
    func xcodeWorkspaceDefaultIsIsolated() throws {
        #expect(try loadStrategy(projectBlock(kind: "xcodeWorkspace")) == .isolated)
    }

    @Test("SwiftPM (macOS), no execution.strategy at all: defaults to isolated, unchanged by this decision")
    func swiftPackageMacOSDefaultIsIsolated() throws {
        #expect(try loadStrategy(projectBlock(kind: "swiftPackageMacOS")) == .isolated)
    }

    @Test("SwiftPM (Apple platform / simulator), no execution.strategy at all: defaults to isolated, unchanged by this decision")
    func swiftPackageAppleDefaultIsIsolated() throws {
        #expect(try loadStrategy(projectBlock(kind: "swiftPackageApple")) == .isolated)
    }

    @Test("Auto-detected project kind, no execution.strategy at all: defaults to isolated")
    func autoProjectKindDefaultIsIsolated() throws {
        #expect(try loadStrategy(projectBlock(kind: "auto")) == .isolated)
    }

    // MARK: - Explicit strategy is honored, whatever it says

    @Test("Xcode project, explicit execution.strategy: schemata is honored — still available as an opt-in")
    func xcodeProjectExplicitSchemataIsHonored() throws {
        let yaml = projectBlock(kind: "xcodeProject") + "\nexecution:\n  strategy: schemata\n"
        #expect(try loadStrategy(yaml) == .schemata)
    }

    @Test("Xcode project, explicit execution.strategy: isolated is honored")
    func xcodeProjectExplicitIsolatedIsHonored() throws {
        let yaml = projectBlock(kind: "xcodeProject") + "\nexecution:\n  strategy: isolated\n"
        #expect(try loadStrategy(yaml) == .isolated)
    }

    // MARK: - `mutantkit init`'s own scaffolding template

    @Test("mutantkit init's own template writes strategy: isolated explicitly, for every project kind")
    func initTemplateWritesIsolatedForEveryProjectKind() {
        for kind: ProjectKind in [.auto, .swiftPackageMacOS, .swiftPackageApple, .xcodeProject, .xcodeWorkspace] {
            let template = ConfigurationLoader.template(for: kind, scheme: nil, destination: nil, testTargets: [])
            #expect(
                template.contains("strategy: isolated"),
                "expected \(kind)'s init template to write strategy: isolated explicitly"
            )
            #expect(
                !template.contains("strategy: schemata"),
                "did not expect \(kind)'s init template to default to schemata"
            )
        }
    }
}
