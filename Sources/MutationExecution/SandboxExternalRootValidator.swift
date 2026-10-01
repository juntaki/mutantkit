import Foundation

/// An external local-package tree cannot be copied without letting the
/// sandbox read back into the original filesystem.
public enum SandboxExternalRootError: Error, Equatable, CustomStringConvertible {
    case symlinkLeavesExternalRoot(link: String, target: String, externalRoot: String)

    public var description: String {
        switch self {
        case let .symlinkLeavesExternalRoot(link, target, externalRoot):
            """
            The local package at \(externalRoot) contains the symbolic link \(link) -> \(target),             which points outside that package. A sandbox copies links as they are, so the copy             would read the original files. Replace the link with the files it points at, or point             it at a path inside the package by a relative path.
            """
        }
    }
}

/// S3 preflight for external roots.
///
/// Project-root symlinks retain the tool's existing behavior. External roots
/// are stricter because they are copied to a different position relative to
/// the original filesystem: an absolute link, or a relative link that escapes
/// its package, would make the sandbox read original files.
public enum SandboxExternalRootValidator {
    /// Validates every external root of `layout`, skipping `scratchRoot` and
    /// anything `excludes` names, exactly as the sandbox copy does.
    public static func validate(layout: SandboxLayout, excludes: [String], scratchRoot: URL) throws {
        let scratchPath = CanonicalPath.resolve(scratchRoot.path) ?? CanonicalPath.lexical(scratchRoot.path)
        for root in layout.externalRoots {
            try validate(root: root.sourceRoot, excludes: excludes, scratchRootPath: scratchPath)
        }
    }

    static func validate(
        root: URL,
        excludes: [String],
        scratchRootPath: String
    ) throws {
        let canonicalRoot = CanonicalPath.resolve(root.path)
            ?? CanonicalPath.lexical(root.path)

        try SandboxCopyWalk.walk(
            root: root,
            excludes: excludes,
            skippingCanonicalPaths: [scratchRootPath]
        ) { entry in
            guard entry.kind == .symbolicLink else {
                return true
            }

            let target: String
            do {
                target = try FileManager.default.destinationOfSymbolicLink(
                    atPath: entry.url.path
                )
            } catch {
                throw WorkspaceError.unreadable(
                    path: entry.url.path,
                    underlying: error.localizedDescription
                )
            }

            try check(
                link: entry.url.path,
                target: target,
                externalRoot: canonicalRoot
            )
            return false
        }
    }

    private static func check(
        link: String,
        target: String,
        externalRoot: String
    ) throws {
        let refusal = SandboxExternalRootError.symlinkLeavesExternalRoot(
            link: link,
            target: target,
            externalRoot: externalRoot
        )

        // Recreating an absolute link in the sandbox always points at the
        // original absolute location, even when that location is inside the
        // source root today.
        if target.hasPrefix("/") {
            throw refusal
        }

        let parent = String(link[..<(link.lastIndex(of: "/") ?? link.endIndex)])
        let lexicalTarget = CanonicalPath.lexical(parent + "/" + target)
        guard SandboxLayout.isSameOrInside(lexicalTarget, externalRoot) else {
            throw refusal
        }

        // A lexically-contained target can still escape through another
        // symlink on the path. For dangling targets, inspect the longest
        // existing prefix; the remaining suffix cannot change containment
        // until it resolves through something that exists.
        let components = (parent + "/" + target)
            .split(separator: "/", omittingEmptySubsequences: true)
        for count in stride(from: components.count, through: 0, by: -1) {
            let prefix = "/" + components.prefix(count).joined(separator: "/")
            guard let resolved = CanonicalPath.resolve(prefix) else {
                continue
            }
            guard SandboxLayout.isSameOrInside(resolved, externalRoot) else {
                throw refusal
            }
            return
        }
    }
}
