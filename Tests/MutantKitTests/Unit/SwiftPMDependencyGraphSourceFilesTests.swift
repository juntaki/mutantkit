@testable import AppleBuildAdapters
import Foundation
import Testing

/// Root-caused 2026-09-17 against a real project: a target's `Package.swift`
/// declared an explicit `sources:` allow-list narrower than its own
/// directory (`ExampleApp/Services/`, which also held a file deliberately
/// left out of the compiled product). A directory-level answer still hands
/// the whole directory to `sources.include`, so `plan` would discover
/// mutations in the unlisted file too — every one of them then fails
/// `buildProductIdenticalToBaseline` during `run`, because that file was
/// never part of any build product to begin with. 28 of 50 budgeted mutants
/// failed this way before the mismatch was noticed.
///
/// `sourceFiles(reachableFrom:)` is the fix: it names the exact files
/// `swift package describe`'s own `sources` list reports per target, not
/// the target's containing directory. `SwiftPMLiveSourceResolution`
/// (`Sources/CLI`) queries this live on every `plan`, so it is always
/// current — never a stale snapshot written once by `setup`.
@Suite("SwiftPMDependencyGraph.sourceFiles(reachableFrom:)")
struct SwiftPMDependencyGraphSourceFilesTests {
    private static func graph(_ json: String) throws -> SwiftPMDependencyGraph {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(SwiftPMTargetResolver.DescribeOutput.self, from: Data(json.utf8))
        return SwiftPMTargetResolver.dependencyGraph(from: decoded, projectRoot: URL(fileURLWithPath: "/tmp/example"))
    }

    @Test("An explicit sources: allow-list narrower than the target's directory is respected")
    func explicitSourcesAllowListIsRespected() throws {
        // ExampleApp/Services/ holds three files on disk, but Package.swift's
        // `sources:` for this target lists only two of them — the third
        // (e.g. an experimental Helper.swift) is deliberately not part
        // of the compiled product. `sourceFiles` must name only the two
        // SwiftPM actually compiles.
        let graph = try Self.graph("""
        {
          "targets": [
            {
              "name": "ExampleAppServicesCore", "path": "ExampleApp/Services",
              "sources": ["Parser.swift", "Formatter.swift"],
              "type": "library", "product_memberships": ["ExampleAppServicesCore"]
            },
            {
              "name": "ExampleAppServicesCoreTests", "path": "Tests/ExampleAppServicesCoreTests",
              "sources": ["ParserTests.swift"],
              "type": "test", "target_dependencies": ["ExampleAppServicesCore"]
            }
          ],
          "products": []
        }
        """)

        let testTargets = graph.targets.keys.filter { graph.isTestTarget($0) }
        let files = graph.sourceFiles(reachableFrom: Array(testTargets))

        #expect(files == ["ExampleApp/Services/Formatter.swift", "ExampleApp/Services/Parser.swift"])
        #expect(!files.contains("ExampleApp/Services/Helper.swift"))
    }

    @Test("Multiple, transitively-reachable production targets contribute all their own files, sorted")
    func transitiveDependenciesContributeAllFiles() throws {
        let graph = try Self.graph("""
        {
          "targets": [
            {
              "name": "Networking", "path": "Sources/Networking", "sources": ["Client.swift", "Auth.swift"],
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

        let files = graph.sourceFiles(reachableFrom: ["AppTests"])
        #expect(files == ["Sources/Core/Types.swift", "Sources/Networking/Auth.swift", "Sources/Networking/Client.swift"])
    }

    @Test("A target rooted at the package root (path: \".\") joins without a spurious leading ./")
    func rootPathTargetJoinsCleanly() throws {
        // `swift package describe` reports a target whose sources live
        // directly under the package root as `path: "."` — naively joining
        // `path` and each source would produce "./Foo.swift", which
        // `SourceFileWalker`'s own repository-relative output never
        // contains, silently making a freshly generated `sources.include`
        // match nothing at all.
        let graph = try Self.graph("""
        {
          "targets": [
            {
              "name": "Lib", "path": ".", "sources": ["Foo.swift"],
              "type": "library", "product_memberships": ["Lib"]
            },
            {
              "name": "LibTests", "path": "Tests/LibTests", "sources": ["FooTests.swift"],
              "type": "test", "target_dependencies": ["Lib"]
            }
          ],
          "products": []
        }
        """)

        let files = graph.sourceFiles(reachableFrom: ["LibTests"])
        #expect(files == ["Foo.swift"])
    }

    @Test("A mixed-language target's non-Swift sources are excluded — the planner can never mutate them")
    func nonSwiftSourcesAreExcluded() throws {
        let graph = try Self.graph("""
        {
          "targets": [
            {
              "name": "MixedLib", "path": "Sources/MixedLib",
              "sources": ["Bridge.swift", "shim.h", "legacy.c"],
              "type": "library", "product_memberships": ["MixedLib"]
            },
            {
              "name": "MixedLibTests", "path": "Tests/MixedLibTests", "sources": ["Tests.swift"],
              "type": "test", "target_dependencies": ["MixedLib"]
            }
          ],
          "products": []
        }
        """)

        let files = graph.sourceFiles(reachableFrom: ["MixedLibTests"])
        #expect(files == ["Sources/MixedLib/Bridge.swift"])
    }

    @Test("A test target's own files are never included")
    func testTargetFilesAreExcluded() throws {
        let graph = try Self.graph("""
        {
          "targets": [
            {
              "name": "MutationModel", "path": "Sources/MutationModel", "sources": ["Types.swift"],
              "type": "library", "product_memberships": ["MutationModel"]
            },
            {
              "name": "MutationModelTests", "path": "Tests/MutationModelTests", "sources": ["Tests.swift", "Fixtures.swift"],
              "type": "test", "target_dependencies": ["MutationModel"]
            }
          ],
          "products": []
        }
        """)

        let files = graph.sourceFiles(reachableFrom: ["MutationModelTests"])
        #expect(files == ["Sources/MutationModel/Types.swift"])
    }
}
