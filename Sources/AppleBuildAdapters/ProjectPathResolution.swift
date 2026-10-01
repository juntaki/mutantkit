import Foundation
import MutationExecution

/// Where the Swift package under test lives inside a directory that is a
/// copy of (or is) `--project-root`.
///
/// `project.path` points at a package that is not at the root itself, for
/// example a monorepo umbrella with the package one level down. Plan-time
/// discovery, the sandboxed build and test, sandbox layout discovery and the
/// containment proof must all agree on this location, so they all ask here.
enum ProjectPathResolution {
    /// `directory` itself when `projectPath` is unset, empty, `"."` or
    /// absolute; `directory` plus `projectPath` otherwise.
    ///
    /// An absolute path is left unresolved: a sandbox is a copy of the project
    /// root, and an absolute path cannot name a place inside that copy.
    static func packageDirectory(in directory: URL, projectPath: String?) -> URL {
        guard let projectPath, !projectPath.isEmpty, projectPath != "." else { return directory }
        guard !projectPath.hasPrefix("/") else { return directory }
        return directory.appendingPathComponent(projectPath)
    }
}

/// A resolver that evaluates the package at `project.path` below the
/// directory it is handed, instead of at the directory itself.
struct ProjectPathScopedResolver: LocalPackageDependencyResolving {
    let inner: any LocalPackageDependencyResolving
    let projectPath: String?

    func localPackageClosure(of root: URL) async throws -> [LocalPackageRoot] {
        try await inner.localPackageClosure(of: ProjectPathResolution.packageDirectory(in: root, projectPath: projectPath))
    }
}
