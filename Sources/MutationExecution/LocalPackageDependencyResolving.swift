import Foundation

/// A local package the build loads through a path dependency
/// (`.package(path:)` in SwiftPM), found by walking the manifests reachable
/// from a project.
///
/// Such a package is an input to the build exactly like the project's own
/// sources: a sandbox has to carry it, and the run's input fingerprint has to
/// cover it.
public struct LocalPackageRoot: Sendable, Hashable {
    /// Exactly as the build tool reported it.
    public let reportedPath: String
    /// `realpath` of `reportedPath`.
    public let canonicalPath: String
    /// Canonical path of the manifest directory that declared it.
    public let declaredBy: String

    public init(reportedPath: String, canonicalPath: String, declaredBy: String) {
        self.reportedPath = reportedPath
        self.canonicalPath = canonicalPath
        self.declaredBy = declaredBy
    }
}

/// Finds every local package a project's build will load.
///
/// Implementations are build-system specific; the sandbox layout and
/// `WorkspaceManager` only see the result.
public protocol LocalPackageDependencyResolving: Sendable {
    /// Every local package transitively reachable from `packageRoot`,
    /// sorted by canonical path. `packageRoot` itself is not included.
    func localPackageClosure(of packageRoot: URL) async throws -> [LocalPackageRoot]
}

/// A local package dependency that cannot be carried into a sandbox as
/// declared.
public enum LocalPackageResolutionError: Error, Equatable, CustomStringConvertible {
    /// The declared path has no `Package.swift`.
    case missingLocalPackage(reportedPath: String, declaredBy: String)
    /// The declared path reaches its package through a symbolic link.
    case symlinkedLocalPackage(reportedPath: String, canonicalPath: String, declaredBy: String)
    /// The declared package is a directory that contains the project, so a
    /// sandbox would have to carry the project inside one of its own
    /// dependencies.
    case localPackageContainsProject(reportedPath: String, projectRoot: String, declaredBy: String)
    /// The declared package is the project itself (`.package(path: ".")`, or a
    /// chain of local dependencies that leads back to it). SwiftPM rejects such
    /// a graph as cyclic; refused here so the cause is named, not an unexplained
    /// failed baseline.
    case localPackageCyclesToProject(reportedPath: String, projectRoot: String, declaredBy: String)

    public var description: String {
        switch self {
        case let .missingLocalPackage(reportedPath, declaredBy):
            """
            The package manifest in \(declaredBy) depends on a local package at \(reportedPath), \
            but there is no Package.swift there.
            """
        case let .symlinkedLocalPackage(reportedPath, canonicalPath, declaredBy):
            """
            The package manifest in \(declaredBy) depends on a local package at \(reportedPath), \
            which is reached through a symbolic link (it resolves to \(canonicalPath)). Local packages \
            reached through symbolic links are not supported yet; depend on \(canonicalPath) by a \
            path without symbolic links instead.
            """
        case let .localPackageContainsProject(reportedPath, projectRoot, declaredBy):
            """
            The package manifest in \(declaredBy) depends on a local package at \(reportedPath), \
            which is a parent directory of the project being tested (\(projectRoot)). A package \
            that contains the project cannot be reproduced next to it in a sandbox; depend on the \
            package that is a sibling of the project instead.
            """
        case let .localPackageCyclesToProject(reportedPath, projectRoot, declaredBy):
            """
            The package manifest in \(declaredBy) depends on a local package at \(reportedPath), \
            which is the project being tested (\(projectRoot)) itself. A package cannot depend on \
            itself, directly or through other local packages; remove the dependency.
            """
        }
    }
}

/// Symlink-free absolute paths.
public enum CanonicalPath {
    /// `realpath(3)` of `path`, or `nil` when it does not exist.
    ///
    /// Not `URL.resolvingSymlinksInPath()`: that strips a leading `/private`
    /// whenever the shorter spelling also exists, so `/private/var/x` comes
    /// back as `/var/x`, which is itself a symlinked spelling. Build tools
    /// report the `/private` form, and comparing the two would see a symlink
    /// where there is none.
    public static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` with `.`, `..`, repeated and trailing slashes folded away
    /// textually, without touching the disk.
    ///
    /// Not `URL.standardizedFileURL`, which applies the same `/private`
    /// rewrite as `resolvingSymlinksInPath()`.
    public static func lexical(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                _ = components.popLast()
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}
