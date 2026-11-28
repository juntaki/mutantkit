import Foundation
import MutationExecution
import MutationModel
import MutationPlanner

public extension SandboxInputClosure {
    /// The closure of the project `context` resolved, laid out as `layout`,
    /// proven to carry exactly the sources `snapshot` planned from.
    ///
    /// Every file in `snapshot` must be a file of the project tree with the
    /// same content hash; a planned source that the sandbox would not carry
    /// (excluded, ignored by the copy walk) or that changed since planning
    /// fails here, before any sandbox exists, rather than being built as a
    /// different file than the one mutated.
    static func capture(
        context: ResolvedInvocationContext,
        layout: SandboxLayout,
        snapshot: SourceSnapshot,
        excludes: [String] = WorkspaceManager.defaultExcludes,
        scratchRoots: [URL] = []
    ) throws -> SandboxInputClosure {
        let invocationRoot = CanonicalPath.resolve(context.projectRoot.path) ?? CanonicalPath.lexical(context.projectRoot.path)
        let layoutRoot = CanonicalPath.resolve(layout.projectRoot.path) ?? CanonicalPath.lexical(layout.projectRoot.path)
        guard invocationRoot == layoutRoot else {
            throw SandboxInputClosureError.projectMismatch(closure: layoutRoot, invocation: invocationRoot)
        }
        let closure = try capture(layout: layout, excludes: excludes, scratchRoots: scratchRoots)
        for file in snapshot.files {
            guard let entry = closure.project.entry(at: file.relativePath), entry.kind == .file else {
                throw SandboxInputClosureError.snapshotMismatch(path: file.relativePath, detail: "not carried by the sandbox copy")
            }
            guard entry.identity == file.contentHash else {
                throw SandboxInputClosureError.snapshotMismatch(path: file.relativePath, detail: "content differs from the planned bytes")
            }
        }
        return closure
    }
}
