@testable import CLI
import Foundation
import MutationExecution

extension RunInputState {
    /// The input state of `root` as a project with no local packages
    /// outside it.
    static func forProject(_ root: URL) async throws -> RunInputState {
        try await compute(projectRoot: root, layout: .projectOnly(root))
    }

    /// A state that needs no git and no files, for tests that exercise only
    /// what an identity does with its other inputs.
    static let placeholder = RunInputState(
        worktreeContentState: "placeholder", workspaceRelativePath: "", externalPackageInputs: []
    )
}
