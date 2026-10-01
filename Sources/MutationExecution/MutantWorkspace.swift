import Foundation

/// The directory a prepared mutant is tested in, and what destroying it
/// removes.
enum MutantWorkspace: Sendable {
    /// A sandbox: tested in its workspace, destroyed with its container.
    case sandbox(Sandbox)
    /// Build products cloned out of a worker's sandbox for a later test.
    case productsClone(URL)

    /// What adapters are handed.
    var url: URL {
        switch self {
        case let .sandbox(sandbox): sandbox.workspaceRoot
        case let .productsClone(clone): clone
        }
    }
}

extension WorkspaceManager {
    func destroy(_ workspace: MutantWorkspace) async throws {
        switch workspace {
        case let .sandbox(sandbox): try await destroySandbox(sandbox)
        case let .productsClone(clone): try await destroyProductsClone(at: clone)
        }
    }
}
