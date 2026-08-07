import Foundation
import MutationExecution
import MutationModel
import MutationPlanner

/// Resolves which SwiftPM target/module/product each source file belongs
/// to — the `targetInfo` input `SchemataChunkPlanner.plan(...)` needs to
/// group mutations into chunks, and which no production code computed
/// before this: every existing caller of `SchemataChunkPlanner.plan`
/// (tests) hand-constructs it for a single, known fixture target.
///
/// Backed by `swift package describe --type json` rather than a hand-rolled
/// `Package.swift` parser: SwiftPM's own describe output is the same
/// target/source resolution `swift build` itself uses, including `path:`
/// overrides and non-default layouts a naive directory-convention guess
/// would get wrong.
public enum SwiftPMTargetResolver {
    public enum ResolutionError: Error, CustomStringConvertible {
        case describeFailed(diagnosis: String)
        case malformedOutput(String)

        public var description: String {
            switch self {
            case let .describeFailed(diagnosis): "`swift package describe` failed: \(diagnosis)"
            case let .malformedOutput(detail): "`swift package describe --type json` produced unparseable output: \(detail)"
            }
        }
    }

    struct DescribeOutput: Decodable {
        struct Target: Decodable {
            let name: String
            /// Project-root-relative, e.g. `"Sources/MutationModel"`.
            let path: String
            /// Target-relative, e.g. `"CoreTypes.swift"`.
            let sources: [String]
            let productMemberships: [String]?
            /// `"test"`, `"library"`, `"executable"`, and similar — SwiftPM's
            /// own classification, not inferred from a naming convention.
            let type: String
            /// Direct target-name dependencies — `SwiftPMDependencyGraph`
            /// builds the transitive closure from this, never a guess about
            /// what a target "probably" links against.
            let targetDependencies: [String]?
        }

        struct Product: Decodable {
            let name: String
            let targets: [String]
        }

        let targets: [Target]
        let products: [Product]
    }

    private static func describe(projectRoot: URL, timeoutSeconds: Double) async throws -> DescribeOutput {
        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcrun,
                arguments: ["swift", "package", "describe", "--type", "json"],
                workingDirectory: projectRoot,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            throw ResolutionError.describeFailed(diagnosis: "\(error)")
        }
        guard result.succeeded else {
            throw ResolutionError.describeFailed(diagnosis: String(decoding: result.standardError, as: UTF8.self))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(DescribeOutput.self, from: result.standardOutput)
        } catch {
            throw ResolutionError.malformedOutput("\(error)")
        }
    }

    /// One entry per source file the manifest actually declares, keyed by
    /// project-root-relative path — the same convention `MutationPoint.file`
    /// and `SchemataChunk`/`SchemataPlanEntry` already use everywhere else.
    /// A file belonging to more than one target (a rare but real SwiftPM
    /// configuration) gets one `SchemataTargetInfo` entry per membership —
    /// `SchemataChunkPlanner` already understands and routes this case to
    /// isolated fallback (`multipleTargetsNotYetSupported`), it does not
    /// need to be resolved here.
    public static func resolveTargetInfo(projectRoot: URL, timeoutSeconds: Double = 120) async throws -> [String: [SchemataTargetInfo]] {
        let decoded = try await describe(projectRoot: projectRoot, timeoutSeconds: timeoutSeconds)
        return Self.targetInfo(from: decoded, projectRoot: projectRoot)
    }

    static func targetInfo(from decoded: DescribeOutput, projectRoot: URL) -> [String: [SchemataTargetInfo]] {
        let projectIdentity = Self.projectIdentity(for: projectRoot)
        var targetInfo: [String: [SchemataTargetInfo]] = [:]
        for target in decoded.targets {
            let info = SchemataTargetInfo(
                projectIdentity: projectIdentity,
                target: target.name,
                module: target.name,
                product: target.productMemberships?.first ?? target.name
            )
            for source in target.sources {
                let relativePath = "\(target.path)/\(source)"
                targetInfo[relativePath, default: []].append(info)
            }
        }
        return targetInfo
    }

    /// The real dependency graph, target types, and product membership —
    /// what `SwiftPMCompilationUnitImageResolver` needs to prove which real
    /// built image a compilation unit's target ends up in, by graph
    /// reachability rather than by matching a discovered bundle's filename
    /// against a target name.
    public static func resolveDependencyGraph(projectRoot: URL, timeoutSeconds: Double = 120) async throws -> SwiftPMDependencyGraph {
        let decoded = try await describe(projectRoot: projectRoot, timeoutSeconds: timeoutSeconds)
        return Self.dependencyGraph(from: decoded, projectRoot: projectRoot)
    }

    static func dependencyGraph(from decoded: DescribeOutput, projectRoot: URL) -> SwiftPMDependencyGraph {
        let projectIdentity = Self.projectIdentity(for: projectRoot)
        var targets: [String: SwiftPMDependencyGraph.TargetInfo] = [:]
        for target in decoded.targets {
            targets[target.name] = SwiftPMDependencyGraph.TargetInfo(
                name: target.name, type: target.type, dependencies: Set(target.targetDependencies ?? [])
            )
        }
        var products: [String: Set<String>] = [:]
        for product in decoded.products {
            products[product.name] = Set(product.targets)
        }
        return SwiftPMDependencyGraph(projectIdentity: projectIdentity, targets: targets, products: products)
    }

    private static func projectIdentity(for projectRoot: URL) -> String {
        // A package can have more than one `Package.swift` build description
        // per se, but for the resolved project this run operates on, its
        // own manifest is the one, stable identity every target here shares
        // — matching `SchemataChunk.projectIdentity`'s role of telling apart
        // two different projects that happen to name a target identically.
        projectRoot.appendingPathComponent("Package.swift").path
    }
}

/// The real SwiftPM target dependency graph, target types, and product
/// membership for one project — resolved from `swift package describe`,
/// never inferred from a target's own display name.
public struct SwiftPMDependencyGraph: Sendable {
    public struct TargetInfo: Sendable {
        public let name: String
        public let type: String
        public let dependencies: Set<String>
    }

    public let projectIdentity: String
    public let targets: [String: TargetInfo]
    public let products: [String: Set<String>]

    public func isTestTarget(_ name: String) -> Bool {
        targets[name]?.type == "test"
    }

    /// Every target whose dependency chain (direct or transitive) includes
    /// `target` — the set of things that would statically link `target`'s
    /// compiled code into their own build product.
    public func transitiveDependents(of target: String) -> Set<String> {
        var dependents: Set<String> = []
        for (name, info) in targets where reaches(info, target: target) {
            dependents.insert(name)
        }
        return dependents
    }

    private func reaches(_ info: TargetInfo, target: String, visited: Set<String> = []) -> Bool {
        if info.dependencies.contains(target) { return true }
        var visited = visited
        visited.insert(info.name)
        for dependencyName in info.dependencies where !visited.contains(dependencyName) {
            guard let dependencyInfo = targets[dependencyName] else { continue }
            if reaches(dependencyInfo, target: target, visited: visited) { return true }
        }
        return false
    }

    public func buildTarget(named name: String) -> BuildTargetIdentity {
        BuildTargetIdentity(projectIdentity: projectIdentity, targetName: name, moduleName: name)
    }
}
