@testable import AppleBuildAdapters
import Foundation
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// On a REAL SwiftPM resolution: the unit suite (`SchemataCompileTimeTargetTests`) feeds the planner a
/// hand-written `swift package describe` JSON. This one writes an actual package — a client library, a
/// `.macro` target and the macro's unit test — runs the real `swift package describe` through
/// `SwiftPMTargetResolver.resolveTargetInfo`, and hands that to `SchemataChunkPlanner`.
///
/// The macro implementation here is deliberately a plain Swift file: `describe` only reads the manifest, so
/// the fixture needs no swift-syntax checkout and no network, yet SwiftPM still reports the target as
/// `type: "macro"` — which is the only thing `executionRole(forSwiftPMType:)` keys on.
@Suite("Acceptance: compile-time macro target stays isolated on a real SwiftPM resolution", .enabled(if: Acceptance.isEnabled))
struct SchemataCompileTimeTargetRealResolutionAcceptanceTests {
    private static let macroFile = "Sources/ClientMacros/Macro.swift"
    private static let clientFile = "Sources/Client/Client.swift"

    private static func writeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-macro-fixture-\(UUID().uuidString)", isDirectory: true)
        let files: [String: String] = [
            "Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            import CompilerPluginSupport
            let package = Package(
                name: "ClientKit",
                products: [.library(name: "Client", targets: ["Client"])],
                targets: [
                    .macro(name: "ClientMacros"),
                    .target(name: "Client", dependencies: ["ClientMacros"]),
                    .testTarget(name: "ClientMacrosTests", dependencies: ["ClientMacros"])
                ]
            )
            """,
            macroFile: "func expandsToTrue() -> Bool { true }\n",
            clientFile: "public func isEnabled() -> Bool { true }\n",
            "Tests/ClientMacrosTests/MacroTests.swift": """
            import XCTest
            final class MacroTests: XCTestCase { func testNothing() {} }
            """
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("A site in the real .macro target falls back with compileTimeExecutedTarget; the client library still embeds")
    func macroSiteFallsBackOnRealResolution() async throws {
        let root = try Self.writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let targetInfo = try await SwiftPMTargetResolver.resolveTargetInfo(projectRoot: root)
        #expect(
            targetInfo[Self.macroFile]?.first?.executionRole == .compileTime,
            "real describe must report the macro target as compile-time"
        )
        #expect(targetInfo[Self.clientFile]?.first?.executionRole == .runtime)

        let operatorID = BoolLiteralInversionOperator.descriptor.id
        let macroPoints = try CoreOperatorExpansionTestSupport.discover(
            "func expandsToTrue() -> Bool { true }\n", operatorID: operatorID, relativePath: Self.macroFile
        )
        let clientPoints = try CoreOperatorExpansionTestSupport.discover(
            "public func isEnabled() -> Bool { true }\n", operatorID: operatorID, relativePath: Self.clientFile
        )
        let result = try SchemataChunkPlanner.plan(
            mutationPlan: makePlan(mutations: macroPoints + clientPoints),
            registry: try SchemataLowererRegistry(),
            sources: [
                Self.macroFile: Data("func expandsToTrue() -> Bool { true }\n".utf8),
                Self.clientFile: Data("public func isEnabled() -> Bool { true }\n".utf8)
            ],
            targetInfo: targetInfo,
            backend: SchemataBackendInfo(
                backendID: "swiftpm-process-executor", backendVersion: 1,
                toolchainHash: "sha256:toolchain", buildArgumentsHash: "sha256:args"
            )
        )

        let macroIDs = Set(macroPoints.map(\.id))
        #expect(!macroIDs.isEmpty && !clientPoints.isEmpty)
        for entry in result.schemataPlan.entries where macroIDs.contains(entry.mutationID) {
            #expect(!entry.isEmbedded)
            #expect(entry.fallbackReason == .compileTimeExecutedTarget(target: "ClientMacros"))
        }
        for entry in result.schemataPlan.entries where !macroIDs.contains(entry.mutationID) {
            #expect(entry.isEmbedded)
        }
        let chunked = Set(result.programs.flatMap { $0.entries.map(\.mutationID) })
        #expect(chunked.isDisjoint(with: macroIDs))
    }
}
