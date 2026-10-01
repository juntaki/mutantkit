import Foundation

/// A path handed back as a sandbox workspace does not have the shape
/// described by its run's layout.
public enum SandboxLayoutError: Error, Equatable, CustomStringConvertible {
    case notASandboxWorkspace(path: String, workspaceRelativePath: String)

    public var description: String {
        switch self {
        case let .notASandboxWorkspace(path, workspaceRelativePath):
            workspaceRelativePath.isEmpty
                ? "\(path) is not a sandbox: its last component is not an sbx_ directory."
                : "\(path) is not a sandbox workspace: it does not end in \(workspaceRelativePath) below an sbx_ directory."
        }
    }
}

/// Where a project and the local packages it depends on sit inside every
/// sandbox of a run.
///
/// This is a pure path model. Discovery owns canonicalization and rejection
/// of unsupported dependency topology; materialization owns filesystem
/// copying and containment checks. The layout only maps the canonical roots
/// discovery returned into one relative directory shape.
///
/// A relative `.package(path: "../SwiftMapper")` therefore resolves inside
/// the sandbox exactly as it does in place, with no manifest rewriting.
public struct SandboxLayout: Sendable, Hashable {
    /// A local package outside the project, copied beside it.
    public struct ExternalRoot: Sendable, Hashable {
        /// Canonical source tree.
        public let sourceRoot: URL
        /// Its path below `layoutRoot`, "/"-separated, never "..".
        public let relativePath: String

        public init(sourceRoot: URL, relativePath: String) {
            self.sourceRoot = sourceRoot
            self.relativePath = relativePath
        }
    }

    /// Canonical project root.
    public let projectRoot: URL
    /// Deepest common ancestor of `projectRoot` and every external root.
    public let layoutRoot: URL
    /// `projectRoot` below `layoutRoot`; empty when there are no external roots.
    public let workspaceRelativePath: String
    /// Minimal external roots, sorted by `relativePath`.
    public let externalRoots: [ExternalRoot]

    public init(
        projectRoot: URL,
        layoutRoot: URL,
        workspaceRelativePath: String,
        externalRoots: [ExternalRoot]
    ) {
        self.projectRoot = projectRoot
        self.layoutRoot = layoutRoot
        self.workspaceRelativePath = workspaceRelativePath
        self.externalRoots = externalRoots
    }

    /// Plans one stable sandbox shape from already-canonical discovery output.
    ///
    /// Packages inside the project are omitted because the project copy
    /// already carries them. If one external package contains another, only
    /// the outer root is needed. Duplicate canonical roots collapse naturally.
    ///
    /// `canonicalProjectRoot` and every `LocalPackageRoot.canonicalPath`
    /// are contractually canonical absolute paths. Discovery is responsible
    /// for refusing a package that is the project itself or an ancestor of it.
    public static func make(
        canonicalProjectRoot: String,
        localPackages: [LocalPackageRoot]
    ) -> SandboxLayout {
        let projectRoot = CanonicalPath.lexical(canonicalProjectRoot)

        let outside = localPackages
            .map(\.canonicalPath)
            .map(CanonicalPath.lexical)
            .filter { !isSameOrInside($0, projectRoot) }

        // Not validation: the policy (and the error a user sees) belongs to
        // discovery. This only stops a broken contract from becoming a layout
        // whose external root is empty and whose workspace is nested in it.
        precondition(
            !outside.contains { isSameOrInside(projectRoot, $0) },
            "SandboxLayout.make was given a package that contains the project; discovery must refuse it"
        )

        // Sorted canonical paths put an enclosing root before anything inside
        // it, so this produces the minimal set of trees materialization needs.
        var roots: [String] = []
        for path in Set(outside).sorted() where !roots.contains(where: { isSameOrInside(path, $0) }) {
            roots.append(path)
        }

        guard !roots.isEmpty else {
            return projectOnly(canonicalProjectRoot: projectRoot)
        }

        let layoutRoot = roots.reduce(projectRoot, commonAncestor)
        let externalRoots = roots
            .map {
                ExternalRoot(
                    sourceRoot: URL(fileURLWithPath: $0, isDirectory: true),
                    relativePath: relative($0, below: layoutRoot)
                )
            }
            .sorted { $0.relativePath < $1.relativePath }

        return SandboxLayout(
            projectRoot: URL(fileURLWithPath: projectRoot, isDirectory: true),
            layoutRoot: URL(fileURLWithPath: layoutRoot, isDirectory: true),
            workspaceRelativePath: relative(projectRoot, below: layoutRoot),
            externalRoots: externalRoots
        )
    }

    /// A layout with no external roots: the sandbox is the project copy, as
    /// it was before local packages were carried.
    public static func projectOnly(canonicalProjectRoot: String) -> SandboxLayout {
        let path = CanonicalPath.lexical(canonicalProjectRoot)
        let root = URL(fileURLWithPath: path, isDirectory: true)
        return SandboxLayout(projectRoot: root, layoutRoot: root, workspaceRelativePath: "", externalRoots: [])
    }

    /// The sandbox this layout gives a container directory.
    public func sandbox(containerRoot: URL) -> Sandbox {
        let workspace = workspaceRelativePath.isEmpty
            ? containerRoot
            : containerRoot.appendingPathComponent(workspaceRelativePath, isDirectory: true)
        return Sandbox(containerRoot: containerRoot, workspaceRoot: workspace)
    }

    /// The scratch root holding the sandbox whose workspace is `workspace`.
    ///
    /// Strips `workspaceRelativePath` component by component and requires
    /// what remains to end in an `sbx_` container, so a path from anywhere
    /// else fails instead of naming the wrong directory.
    public func scratchRoot(ofWorkspace workspace: URL) throws(SandboxLayoutError) -> URL {
        try Self.container(ofWorkspace: workspace, workspaceRelativePath: workspaceRelativePath)
            .deletingLastPathComponent()
    }

    /// The directory name of the container holding `workspace`.
    public func containerName(ofWorkspace workspace: URL) throws(SandboxLayoutError) -> String {
        try Self.container(ofWorkspace: workspace, workspaceRelativePath: workspaceRelativePath).lastPathComponent
    }

    /// `workspace` with `workspaceRelativePath` removed from its end,
    /// checked to be an `sbx_<20 hex>` directory.
    public static func container(
        ofWorkspace workspace: URL,
        workspaceRelativePath: String
    ) throws(SandboxLayoutError) -> URL {
        var components = CanonicalPath.lexical(workspace.path).split(separator: "/").map(String.init)
        let expected = workspaceRelativePath.split(separator: "/").map(String.init)
        guard components.count > expected.count, Array(components.suffix(expected.count)) == expected else {
            throw .notASandboxWorkspace(path: workspace.path, workspaceRelativePath: workspaceRelativePath)
        }
        components.removeLast(expected.count)
        guard let name = components.last, isSandboxDirectoryName(name) else {
            throw .notASandboxWorkspace(path: workspace.path, workspaceRelativePath: workspaceRelativePath)
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
    }

    static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }

    private static func isSandboxDirectoryName(_ name: String) -> Bool {
        let digest = name.dropFirst(4)
        return name.hasPrefix("sbx_") && digest.count == 20 && digest.allSatisfy(\.isHexDigit)
    }

    private static func commonAncestor(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.split(separator: "/")
        let right = rhs.split(separator: "/")
        let shared = zip(left, right).prefix { $0 == $1 }.map(\.0)
        return "/" + shared.joined(separator: "/")
    }

    private static func relative(_ path: String, below ancestor: String) -> String {
        String(path.dropFirst(ancestor == "/" ? 1 : ancestor.count + 1))
    }
}

/// One sandbox of a run: the directory created and destroyed as a unit, and
/// the project copy inside it that adapters build in.
public struct Sandbox: Sendable, Hashable {
    /// `scratchRoot/sbx_<digest>`, the unit of creation and destruction.
    public let containerRoot: URL
    /// `containerRoot/workspaceRelativePath`: what adapters build in.
    public let workspaceRoot: URL

    public init(containerRoot: URL, workspaceRoot: URL) {
        self.containerRoot = containerRoot
        self.workspaceRoot = workspaceRoot
    }
}
