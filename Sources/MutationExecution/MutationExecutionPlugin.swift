import Foundation
import MutationModel

/// Stable extension points for execution-side customisation without making
/// `MutationRunner` depend on concrete third-party packages.
///
/// v1 deliberately keeps plugins observational/selection-oriented. A plugin
/// cannot manufacture a scored verdict; classification and integrity remain
/// owned by MutantKit's core. This preserves the fail-closed model while allowing
/// alternative test ordering, external caches, telemetry and CI integration.
public protocol MutationExecutionPlugin: Sendable {
    var id: String { get }

    func willRun(planID: String, mutationCount: Int) async
    func willEvaluate(_ mutation: MutationPoint) async
    func didEvaluate(_ result: MutationResult) async
    func didFinish(_ report: RunReport) async
}

public extension MutationExecutionPlugin {
    func willRun(planID: String, mutationCount: Int) async {}
    func willEvaluate(_ mutation: MutationPoint) async {}
    func didEvaluate(_ result: MutationResult) async {}
    func didFinish(_ report: RunReport) async {}
}

/// Type-erased plugin collection. Hooks are best-effort diagnostics: plugin
/// failures are represented by plugin implementations themselves and cannot
/// alter mutation classification or integrity accounting.
public struct MutationExecutionPlugins: Sendable {
    public let plugins: [any MutationExecutionPlugin]

    public init(_ plugins: [any MutationExecutionPlugin] = []) {
        self.plugins = plugins
    }

    public func willRun(planID: String, mutationCount: Int) async {
        for plugin in plugins {
            await plugin.willRun(planID: planID, mutationCount: mutationCount)
        }
    }

    public func willEvaluate(_ mutation: MutationPoint) async {
        for plugin in plugins { await plugin.willEvaluate(mutation) }
    }

    public func didEvaluate(_ result: MutationResult) async {
        for plugin in plugins { await plugin.didEvaluate(result) }
    }

    public func didFinish(_ report: RunReport) async {
        for plugin in plugins { await plugin.didFinish(report) }
    }
}

/// Optional strategy point for selected-test ordering. Core ships a
/// history-based prioritizer (`TestPriorityStore`); integrations can provide a
/// different deterministic ordering without replacing the test adapter.
public protocol TestPrioritizationStrategy: Sendable {
    func order(
        _ tests: Set<TestIdentifier>,
        for mutation: MutationPoint
    ) async -> [TestIdentifier]
}

/// Optional external cache contract. Cache implementations return only a
/// previously classified `MutationResult`; the caller is still responsible for
/// proving the cache key covers source, tests, toolchain and configuration.
public protocol MutationResultCaching: Sendable {
    func load(mutationID: MutationID, contextDigest: String) async -> MutationResult?
    func store(_ result: MutationResult, contextDigest: String) async
}
