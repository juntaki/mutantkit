import MutationExecution

/// The containment proof for SwiftPM projects: SwiftPM evaluates the
/// sandbox's own manifests, and every local package they load must be a copy
/// inside the sandbox.
///
/// Built on `SwiftPMLocalDependencyResolver`, so the sandbox is judged by
/// the same discovery rules that produced its layout.
public struct SwiftPMSandboxContainmentProof: SandboxContainmentProving {
    private let proof: LocalPackageContainmentProof

    /// - Parameter manifestDumps: a cache for sandbox manifests. Entries are
    ///   keyed by path, so sharing the run cache never serves an original
    ///   manifest's output for a sandboxed copy.
    /// - Parameter projectPath: `project.path`, the package's location below
    ///   the sandbox workspace, or `nil` when the package is the workspace.
    public init(
        projectPath: String?,
        timeoutSeconds: Double = 60,
        manifestDumps: SwiftPMManifestDumps = SwiftPMManifestDumps()
    ) {
        proof = LocalPackageContainmentProof(
            resolver: ProjectPathScopedResolver(
                inner: SwiftPMLocalDependencyResolver(
                    timeoutSeconds: timeoutSeconds,
                    manifestDumps: manifestDumps
                ),
                projectPath: projectPath
            )
        )
    }

    public func proveContainment(of sandbox: Sandbox, layout: SandboxLayout) async throws {
        try await proof.proveContainment(of: sandbox, layout: layout)
    }
}
