/// Persistent sandboxes for the crash and timeout confirmations of an
/// incremental-build run.
///
/// A confirmation rebuilds the mutant in a sandbox of its own, never in the
/// one its primary run used, so that nothing the primary run left behind can
/// carry over into the verdict. A sandbox made for the one confirmation pays
/// a cold build every time (14-15 s on swift-argument-parser, 118 s on
/// MutantKit itself); one that outlives a confirmation pays it once and then
/// rebuilds only the changed file.
///
/// The independence the confirmation exists for is kept: these sandboxes are
/// never a worker's own sandbox and never see a primary run, only earlier
/// confirmations, whose edit is restored before the sandbox is lent out again.
/// A sandbox whose restore fails is destroyed instead of reused. What reuse
/// does accept is what an incremental worker's sandbox already accepts (see
/// `ProcessSupervisor`'s "Remaining risks").
///
/// At most one confirmation uses a sandbox at a time; concurrent confirmations
/// each get their own, so the pool holds as many as ever ran together.
actor ConfirmationSandboxPool {
    private let workspaces: WorkspaceManager
    private var idle: [Sandbox] = []
    private var created = 0

    init(workspaces: WorkspaceManager) {
        self.workspaces = workspaces
    }

    /// An idle sandbox, or a new one when every sandbox is lent out.
    func acquire() async throws -> Sandbox {
        if let sandbox = idle.popLast() { return sandbox }
        created += 1
        return try await workspaces.createSandbox(id: "confirm-pool-\(created)")
    }

    /// Takes `sandbox` back after restoring the one file the confirmation
    /// edited. A sandbox that cannot be restored is destroyed.
    func release(_ sandbox: Sandbox, restoring relativePath: String) async {
        do {
            try await workspaces.restoreFile(relativePath: relativePath, in: sandbox)
            idle.append(sandbox)
        } catch {
            try? await workspaces.destroySandbox(sandbox)
        }
    }

    /// Destroys every idle sandbox. Called once the run's evaluation is over.
    func drain() async {
        let sandboxes = idle
        idle = []
        for sandbox in sandboxes {
            try? await workspaces.destroySandbox(sandbox)
        }
    }
}
