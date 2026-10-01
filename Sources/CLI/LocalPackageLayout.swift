import AppleBuildAdapters
import ArgumentParser
import Foundation
import MutationExecution
import MutationModel

/// The sandbox layout `run`, `dry-run`, `reproduce` and `doctor` share: the
/// project plus every local package outside it that its build reads, laid
/// out once before any sandbox exists.
enum LocalPackageLayout {
    /// `resolution` with its adapter rebuilt for the project's sandbox
    /// layout. A refusal (a package that cannot be discovered, or cannot be
    /// carried into a sandbox) goes to stderr and exits `operationalError`:
    /// building without it would fail, or read the original tree.
    static func resolve(
        _ resolution: AppleAdapterFactory.Resolution,
        configuration: Configuration,
        projectRoot: URL,
        scratchRoot: URL,
        manifestDumps: SwiftPMManifestDumps = SwiftPMManifestDumps()
    ) async throws -> AppleAdapterFactory.Resolution {
        let layout = try await layout(
            kind: resolution.detection.kind, projectRoot: projectRoot, projectPath: configuration.project.path,
            scratchRoot: scratchRoot, manifestDumps: manifestDumps
        )
        return AppleAdapterFactory.withSandboxLayout(
            layout, resolution: resolution, configuration: configuration, projectRoot: projectRoot
        )
    }

    /// The layout alone, for a caller with no adapter yet. Same refusal
    /// handling as `resolve`.
    static func layout(
        kind: ProjectKind,
        projectRoot: URL,
        projectPath: String?,
        scratchRoot: URL,
        manifestDumps: SwiftPMManifestDumps = SwiftPMManifestDumps()
    ) async throws -> SandboxLayout {
        do {
            return try await AppleAdapterFactory.sandboxLayout(
                for: kind, projectRoot: projectRoot, projectPath: projectPath, scratchRoot: scratchRoot,
                manifestDumps: manifestDumps
            )
        } catch {
            FileHandle.standardError.write(Data("The sandbox cannot be laid out: \(error)\n".utf8))
            throw ExitCode(MutantKitExit.operationalError)
        }
    }

    /// `createSandbox(id:)`, with a containment refusal reported the way a
    /// layout refusal is: on stderr, exiting `operationalError`.
    static func createSandbox(id: String, in workspaces: WorkspaceManager) async throws -> Sandbox {
        do {
            return try await workspaces.createSandbox(id: id)
        } catch let WorkspaceError.containment(refusal) {
            FileHandle.standardError.write(Data("The sandbox cannot be built in: \(refusal)\n".utf8))
            throw ExitCode(MutantKitExit.operationalError)
        }
    }

    /// A manager whose sandboxes reproduce `layout`, proving on its first
    /// sandbox that every local package the build loads is inside it.
    static func workspaceManager(
        layout: SandboxLayout, kind: ProjectKind, projectPath: String?, scratchRoot: URL, cleanSubtreeCloning: Bool = false
    ) throws -> WorkspaceManager {
        try WorkspaceManager(
            layout: layout,
            scratchRoot: scratchRoot,
            cleanSubtreeCloning: cleanSubtreeCloning,
            containmentProof: AppleAdapterFactory.containmentProof(for: kind, projectPath: projectPath)
        )
    }

    /// One line for `dry-run` and `run`.
    static func summary(of layout: SandboxLayout) -> String {
        "Local packages: " + (layout.externalRoots.isEmpty ? "none outside the project" : packageList(layout))
    }

    /// Every external package by name, with its path from the project as a
    /// manifest beside it would spell it.
    private static func packageList(_ layout: SandboxLayout) -> String {
        let up = Array(repeating: "..", count: layout.workspaceRelativePath.split(separator: "/").count)
        let packages = layout.externalRoots.map { root in
            let name = root.relativePath.split(separator: "/").last.map(String.init) ?? root.relativePath
            return "\(name) (\((up + [root.relativePath]).joined(separator: "/")))"
        }
        return packages.joined(separator: ", ") + " — copied into each sandbox, included in the run fingerprint"
    }
}
