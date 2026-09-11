@testable import AppleBuildAdapters
import Foundation
import Testing

/// Lane D external-proof discovery, root-caused 2026-09-10: a real,
/// independent SwiftPM package whose library source lived at a custom path
/// (not the `Sources/<TargetName>` convention) got `sources.include:
/// [Sources/**]` unconditionally from `mutantkit init`/`setup` — silently
/// including one unrelated, untested file that happened to live under
/// `Sources/` and excluding the real 35 files the actual test target
/// covered. `plan` still found a plausible-looking non-zero mutation count,
/// so nothing caught the mismatch — worse than a zero-discovery warning.
///
/// `SwiftPMDependencyGraph.sourcePaths(reachableFrom:)` is the fix: the
/// real, resolved `path:` SwiftPM's own `swift package describe` reports
/// per target, not a directory-convention guess. These tests decode a
/// realistic `describe --type json`-shaped payload (mirroring the real
/// package's structure) directly, exercising the same parse
/// `SwiftPMTargetResolver.dependencyGraph(from:projectRoot:)` uses in
/// production.
@Suite("SwiftPMDependencyGraph.sourcePaths(reachableFrom:)")
struct SwiftPMDependencyGraphSourcePathsTests {
    private static func graph(_ json: String) throws -> SwiftPMDependencyGraph {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(SwiftPMTargetResolver.DescribeOutput.self, from: Data(json.utf8))
        return SwiftPMTargetResolver.dependencyGraph(from: decoded, projectRoot: URL(fileURLWithPath: "/tmp/example"))
    }

    @Test("A test target's real, custom-path dependency is used, not a Sources/<name> guess")
    func customPathDependencyIsResolved() throws {
        let graph = try Self.graph("""
        {
          "targets": [
            {
              "name": "ExampleLibServices", "path": "ExampleLib/Services", "sources": ["Model.swift"],
              "type": "library", "product_memberships": ["ExampleLibServices"]
            },
            {
              "name": "HeuristicEvalCLI", "path": "Sources/HeuristicEvalCLI", "sources": ["main.swift"],
              "type": "executable", "product_memberships": ["HeuristicEvalCLI"]
            },
            {
              "name": "ExampleLibTests", "path": "Tests/ExampleLibTests", "sources": ["ModelTests.swift"],
              "type": "test", "target_dependencies": ["ExampleLibServices"]
            }
          ],
          "products": []
        }
        """)

        let testTargets = graph.targets.keys.filter { graph.isTestTarget($0) }
        let paths = graph.sourcePaths(reachableFrom: Array(testTargets))

        #expect(paths == ["ExampleLib/Services"])
        #expect(!paths.contains("Sources/HeuristicEvalCLI"), "the untested CLI target must not be included")
    }

    @Test("Multiple, transitively-reachable production targets are all included, sorted")
    func transitiveDependenciesAreAllIncluded() throws {
        let graph = try Self.graph("""
        {
          "targets": [
            {
              "name": "Networking", "path": "Sources/Networking", "sources": ["Client.swift"],
              "type": "library", "product_memberships": ["Networking"]
            },
            {
              "name": "Core", "path": "Sources/Core", "sources": ["Types.swift"],
              "type": "library", "product_memberships": ["Core"], "target_dependencies": ["Networking"]
            },
            {
              "name": "AppTests", "path": "Tests/AppTests", "sources": ["Tests.swift"],
              "type": "test", "target_dependencies": ["Core"]
            }
          ],
          "products": []
        }
        """)

        let paths = graph.sourcePaths(reachableFrom: ["AppTests"])
        #expect(paths == ["Sources/Core", "Sources/Networking"])
    }

    @Test("The conventional Sources/<TargetName> layout still resolves correctly (no regression)")
    func conventionalLayoutStillWorks() throws {
        let graph = try Self.graph("""
        {
          "targets": [
            {
              "name": "MutationModel", "path": "Sources/MutationModel", "sources": ["Types.swift"],
              "type": "library", "product_memberships": ["MutationModel"]
            },
            {
              "name": "MutationModelTests", "path": "Tests/MutationModelTests", "sources": ["Tests.swift"],
              "type": "test", "target_dependencies": ["MutationModel"]
            }
          ],
          "products": []
        }
        """)

        let paths = graph.sourcePaths(reachableFrom: ["MutationModelTests"])
        #expect(paths == ["Sources/MutationModel"])
    }
}
