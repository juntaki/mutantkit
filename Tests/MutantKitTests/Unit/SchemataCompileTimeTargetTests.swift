@testable import AppleBuildAdapters
import Foundation
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// A source in a target the build itself executes (a SwiftPM macro
/// implementation) must never reach a schemata chunk. Isolated measures
/// "clients compiled with the mutated macro"; schemata would measure only the
/// macro's own unit tests at runtime — two different experiments under one
/// MutationID.
@Suite("Compile-time executed targets stay isolated")
struct SchemataCompileTimeTargetTests {
    private static let describeJSON = """
    {
      "targets": [
        {"name": "Client", "path": "Sources/Client", "sources": ["Client.swift"],
         "type": "library", "product_memberships": ["Client"], "target_dependencies": ["ClientMacros"]},
        {"name": "ClientMacros", "path": "Sources/ClientMacros", "sources": ["Macro.swift"],
         "type": "macro", "product_memberships": ["Client"]},
        {"name": "ClientMacrosTests", "path": "Tests/ClientMacrosTests", "sources": ["MacroTests.swift"],
         "type": "test", "target_dependencies": ["ClientMacros"]},
        {"name": "MacroHelpers", "path": "Sources/MacroHelpers", "sources": ["Helpers.swift"],
         "type": "library", "product_memberships": ["MacroHelpers"]}
      ],
      "products": []
    }
    """

    private static func targetInfo() throws -> [String: [SchemataTargetInfo]] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(SwiftPMTargetResolver.DescribeOutput.self, from: Data(describeJSON.utf8))
        return SwiftPMTargetResolver.targetInfo(from: decoded, projectRoot: URL(fileURLWithPath: "/tmp/example"))
    }

    private static let backend = SchemataBackendInfo(
        backendID: "swiftpm-process-executor", backendVersion: 1,
        toolchainHash: "sha256:toolchain", buildArgumentsHash: "sha256:args"
    )

    @Test("Only SwiftPM type \"macro\" maps to compileTime; a library merely named Macro* stays runtime")
    func roleMapping() throws {
        let info = try Self.targetInfo()
        #expect(info["Sources/ClientMacros/Macro.swift"]?.first?.executionRole == .compileTime)
        #expect(info["Sources/MacroHelpers/Helpers.swift"]?.first?.executionRole == .runtime)
        #expect(info["Sources/Client/Client.swift"]?.first?.executionRole == .runtime)
    }

    @Test("A macro-target site falls back with compileTimeExecutedTarget; library sites still embed")
    func plannerRoutesMacroToIsolated() throws {
        let source = "func flag() -> Bool { true }\n"
        let macroFile = "Sources/ClientMacros/Macro.swift"
        let helperFile = "Sources/MacroHelpers/Helpers.swift"
        let id = BoolLiteralInversionOperator.descriptor.id
        let macroPoints = try CoreOperatorExpansionTestSupport.discover(source, operatorID: id, relativePath: macroFile)
        let helperPoints = try CoreOperatorExpansionTestSupport.discover(source, operatorID: id, relativePath: helperFile)
        let result = try SchemataChunkPlanner.plan(
            mutationPlan: makePlan(mutations: macroPoints + helperPoints),
            registry: try SchemataLowererRegistry(),
            sources: [macroFile: Data(source.utf8), helperFile: Data(source.utf8)],
            targetInfo: try Self.targetInfo(),
            backend: Self.backend
        )

        let macroIDs = Set(macroPoints.map(\.id))
        for entry in result.schemataPlan.entries where macroIDs.contains(entry.mutationID) {
            #expect(!entry.isEmbedded)
            #expect(entry.fallbackReason == .compileTimeExecutedTarget(target: "ClientMacros"))
        }
        for entry in result.schemataPlan.entries where !macroIDs.contains(entry.mutationID) {
            #expect(entry.isEmbedded, "a library named MacroHelpers is an ordinary runtime target")
        }
        let chunked = Set(result.programs.flatMap { $0.entries.map(\.mutationID) })
        #expect(chunked.isDisjoint(with: macroIDs), "no macro-target MutationID enters any schemata chunk")
        #expect(!macroIDs.isEmpty && !chunked.isEmpty)
    }

    @Test("A source shared with a compile-time target stays isolated for the whole MutationID")
    func sharedWithMacroTargetStaysIsolated() throws {
        let source = "func flag() -> Bool { true }\n"
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Shared.swift"
        )
        let runtime = SchemataTargetInfo(projectIdentity: "p", target: "App", module: "App", product: "App")
        let macro = SchemataTargetInfo(
            projectIdentity: "p", target: "AppMacros", module: "AppMacros", product: "AppMacros", executionRole: .compileTime
        )
        let result = try SchemataChunkPlanner.plan(
            mutationPlan: makePlan(mutations: points),
            registry: try SchemataLowererRegistry(),
            sources: ["Shared.swift": Data(source.utf8)],
            targetInfo: ["Shared.swift": [runtime, macro]],
            backend: Self.backend
        )
        #expect(result.programs.isEmpty)
        let entry = try #require(result.schemataPlan.entries.first)
        #expect(entry.fallbackReason == .compileTimeExecutedTarget(target: "AppMacros"))
    }

    @Test("The new reason round-trips through JSON")
    func reasonRoundTrips() throws {
        let reason = SchemataUnsupportedReason.compileTimeExecutedTarget(target: "ClientMacros")
        let data = try JSONEncoder().encode(reason)
        #expect(try JSONDecoder().decode(SchemataUnsupportedReason.self, from: data) == reason)
    }
}
