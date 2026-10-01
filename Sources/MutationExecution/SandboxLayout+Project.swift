import Foundation

public extension SandboxLayout {
    /// A layout with no external roots, for a project given as a URL.
    ///
    /// Lives apart from `SandboxLayout` because it reads the disk to
    /// canonicalize `projectRoot`; the model itself never does.
    static func projectOnly(_ projectRoot: URL) -> SandboxLayout {
        projectOnly(canonicalProjectRoot: CanonicalPath.resolve(projectRoot.path) ?? CanonicalPath.lexical(projectRoot.path))
    }
}
