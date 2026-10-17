import MutationModel
import SwiftFrontend

extension MutationConfirmationCoordinator {
    /// Rebuilds a mutant whose first build ended in a compiler crash, from scratch in a sandbox
    /// independent of the one the crash was observed in.
    ///
    /// Returns the confirming build's failure only when it is the same crash as the first: a
    /// compiler-crash candidate (the compiler process died with no diagnostic and no environment marker)
    /// whose signature, the signal, what the compiler was processing and its top frames, equals
    /// `signature`. A different crash, a rebuild that succeeds, that fails with a diagnostic, or that
    /// fails any other way returns `nil`, and so does a sandbox, source or mutation problem: nothing was
    /// confirmed, and the caller keeps the first failure as an infrastructure failure. This never
    /// decides a verdict; the verifier does, from the build kind the caller records.
    func confirmCompilerCrash(_ point: MutationPoint, matching signature: CompilerCrashSignature) async -> BuildFailure? {
        let sandbox: Sandbox
        do {
            sandbox = try await workspaces.createSandbox(id: "\(point.id.rawValue)-compiler-crash-confirm")
        } catch {
            return nil
        }
        let confirming = await rebuild(point, in: sandbox)
        try? await workspaces.destroySandbox(sandbox)
        return confirming?.compilerCrashSignature == signature ? confirming : nil
    }

    private func rebuild(_ point: MutationPoint, in sandbox: Sandbox) async -> BuildFailure? {
        let applied: AppliedMutation
        do {
            let sourceURL = try workspaces.resolveSourceURL(in: sandbox, relativePath: point.file)
            applied = try MutationApplication.applyInPlace(point, fileAt: sourceURL)
        } catch {
            return nil
        }

        do {
            _ = try await build.buildMutant(applied, in: sandbox.workspaceRoot)
            return nil
        } catch let failure as BuildFailure {
            return failure.kind == .infrastructure && failure.isCompilerCrashCandidate ? failure : nil
        } catch {
            return nil
        }
    }
}
