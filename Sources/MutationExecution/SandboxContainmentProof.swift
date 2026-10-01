import Foundation

/// A sandbox whose manifests would load a local package from somewhere other
/// than the sandbox itself.
public enum SandboxContainmentError: Error, Equatable, CustomStringConvertible {
    /// A local package the sandboxed build would load lies outside the
    /// sandbox, so the build would read the original tree instead of its copy.
    case localPackageOutsideSandbox(reported: String, canonical: String, declaredBy: String)
    /// The sandboxed manifests load a different set of local packages than
    /// discovery saw in place. Both lists are paths below the layout root.
    case dependencyGraphChangedInSandbox(unexpected: [String], missing: [String])
    /// The sandboxed manifests could not be evaluated or walked.
    case unresolvableInSandbox(detail: String)

    private static let supportedSpelling = """
    Local packages are supported when they are declared by a relative path, such as     .package(path: "../SwiftMapper"), to a directory beside the project or inside it.
    """

    public var description: String {
        switch self {
        case let .localPackageOutsideSandbox(reported, canonical, declaredBy):
            let location = reported == canonical ? reported : "\(reported) (resolving to \(canonical))"
            return """
            The package manifest in \(declaredBy) depends on the local package at \(location), which a             sandbox cannot carry: from inside the sandbox it still names the original files, so a             build there would not test the copy. An absolute package path does this.             \(Self.supportedSpelling)
            """
        case let .dependencyGraphChangedInSandbox(unexpected, missing):
            var changes: [String] = []
            if !unexpected.isEmpty {
                changes.append("it also loads \(unexpected.joined(separator: ", "))")
            }
            if !missing.isEmpty {
                changes.append("it no longer loads \(missing.joined(separator: ", "))")
            }
            return """
            Evaluated inside a sandbox, the package manifests load different local packages than they             do in place: \(changes.joined(separator: "; ")). A manifest whose dependencies depend on             its location or on the environment cannot be sandboxed faithfully.             \(Self.supportedSpelling)
            """
        case let .unresolvableInSandbox(detail):
            return """
            The local packages of the sandboxed project could not be resolved before building:             \(detail) \(Self.supportedSpelling)
            """
        }
    }
}

/// Proves, before anything is built, that a sandbox is closed: every local
/// package its build would load is a copy inside it.
public protocol SandboxContainmentProving: Sendable {
    func proveContainment(of sandbox: Sandbox, layout: SandboxLayout) async throws
}

/// The containment proof over any `LocalPackageDependencyResolving`.
///
/// The resolver walks the sandbox's own manifests from `workspaceRoot`.
/// Every returned package must be inside the canonical container, and the
/// package set relative to that container must agree with the layout.
public struct LocalPackageContainmentProof: SandboxContainmentProving {
    let resolver: any LocalPackageDependencyResolving

    public init(resolver: any LocalPackageDependencyResolving) {
        self.resolver = resolver
    }

    public func proveContainment(of sandbox: Sandbox, layout: SandboxLayout) async throws {
        let packages: [LocalPackageRoot]
        do {
            packages = try await resolver.localPackageClosure(of: sandbox.workspaceRoot)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SandboxContainmentError.unresolvableInSandbox(detail: "\(error)")
        }
        try Self.check(packages, sandbox: sandbox, layout: layout)
    }

    static func check(
        _ packages: [LocalPackageRoot],
        sandbox: Sandbox,
        layout: SandboxLayout
    ) throws(SandboxContainmentError) {
        let container = CanonicalPath.resolve(sandbox.containerRoot.path)
            ?? CanonicalPath.lexical(sandbox.containerRoot.path)

        var loaded: [String] = []
        for package in packages {
            guard package.canonicalPath != container,
                  SandboxLayout.isSameOrInside(package.canonicalPath, container)
            else {
                throw .localPackageOutsideSandbox(
                    reported: package.reportedPath,
                    canonical: package.canonicalPath,
                    declaredBy: originalLocation(
                        of: package.declaredBy,
                        container: container,
                        layout: layout
                    )
                )
            }
            loaded.append(String(package.canonicalPath.dropFirst(container.count + 1)))
        }

        let roots = layout.externalRoots.map(\.relativePath)
        let unexpected = loaded.filter { path in
            !isSameOrBelow(path, layout.workspaceRelativePath)
                && !roots.contains { isSameOrBelow(path, $0) }
        }
        let missing = roots.filter { !loaded.contains($0) }
        guard unexpected.isEmpty, missing.isEmpty else {
            throw .dependencyGraphChangedInSandbox(
                unexpected: unexpected.sorted(),
                missing: missing.sorted()
            )
        }
    }

    /// `path` below `ancestor`, both relative to the container; an empty
    /// ancestor is the container itself.
    private static func isSameOrBelow(_ path: String, _ ancestor: String) -> Bool {
        ancestor.isEmpty || path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// Maps a declaring manifest inside the container back to the original
    /// layout so diagnostics point at the file the user can edit.
    private static func originalLocation(
        of path: String,
        container: String,
        layout: SandboxLayout
    ) -> String {
        if path == container {
            return CanonicalPath.lexical(layout.layoutRoot.path)
        }
        guard SandboxLayout.isSameOrInside(path, container) else {
            return path
        }
        let relative = path.dropFirst(container.count + 1)
        return CanonicalPath.lexical(layout.layoutRoot.path + "/" + relative)
    }
}
