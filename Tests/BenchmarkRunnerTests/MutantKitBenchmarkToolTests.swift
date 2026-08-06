@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("MutantKitBenchmarkTool")
struct MutantKitBenchmarkToolTests {
    private static let project = BenchmarkProject(
        id: "example", repositoryURL: "https://example.com/example.git",
        commitSHA: String(repeating: "a", count: 40), projectKind: .swiftPackage
    )
    private static let profile = BenchmarkToolchainProfile(
        id: "test", purpose: .currentEnvironment, swiftExecutable: "swift", swiftVersion: "test"
    )

    @Test("With no overrides, the generated config keeps the existing default sources.include and an empty disable list")
    func defaultsAreUnchangedWithoutOverrides() {
        let tool = MutantKitBenchmarkTool(binaryURL: URL(fileURLWithPath: "/bin/true"), toolchainProfile: Self.profile)
        let config = tool.defaultConfiguration(for: Self.project)
        #expect(config.contains(#"include: ["Sources/**"]"#))
        #expect(config.contains("disable: []"))
    }

    @Test("sourceInclude and disableOperators are reflected in the generated config, for a real calibration scoping use case")
    func overridesAreReflectedInGeneratedConfig() {
        let tool = MutantKitBenchmarkTool(
            binaryURL: URL(fileURLWithPath: "/bin/true"), toolchainProfile: Self.profile,
            sourceInclude: ["Sources/IntegerUtilities/**"], disableOperators: ["swift.core.bool-literal-inversion"]
        )
        let config = tool.defaultConfiguration(for: Self.project)
        #expect(config.contains(#"include: ["Sources/IntegerUtilities/**"]"#))
        #expect(config.contains(#"disable: ["swift.core.bool-literal-inversion"]"#))
    }

    @Test("isolatedConfiguration preserves overrides while switching the execution strategy")
    func isolatedConfigurationPreservesOverrides() {
        let tool = MutantKitBenchmarkTool(
            binaryURL: URL(fileURLWithPath: "/bin/true"), toolchainProfile: Self.profile,
            sourceInclude: ["Sources/IntegerUtilities/**"]
        )
        let config = tool.isolatedConfiguration(for: Self.project)
        #expect(config.contains(#"include: ["Sources/IntegerUtilities/**"]"#))
        #expect(config.contains("strategy: isolated"))
    }
}
