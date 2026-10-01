import Foundation

/// The entries a sandbox copy carries from one root: every file, symlink
/// and directory below it, minus excluded names and minus any scratch root.
///
/// Sandbox materialization and the run identity's external-root fingerprint use this same walk,
/// so "equal digest" and "equal sandbox copy" are statements about one set
/// of entries rather than two enumerations that can drift apart.
public enum SandboxCopyWalk {
    public enum Kind: Sendable, Equatable {
        case file
        case symbolicLink
        case directory
    }

    public struct Entry: Sendable {
        /// The entry in the source tree.
        public let url: URL
        /// Its path below the walked root, "/"-separated.
        public let relativePath: String
        public let kind: Kind
    }

    /// Visits every entry below `root` in pre-order, siblings sorted by name.
    ///
    /// Excluded entries are skipped with their contents. A directory whose
    /// canonical path is in `skippingCanonicalPaths` is skipped as well, so
    /// a scratch root inside a copied tree cannot recursively copy sandboxes
    /// into themselves. Symlinks are reported and never followed.
    ///
    /// `visit` returns whether to descend into a directory entry; its return
    /// value is ignored for files and symbolic links.
    public static func walk(
        root: URL,
        excludes: [String],
        skippingCanonicalPaths: Set<String>,
        visit: (Entry) throws -> Bool
    ) throws {
        // Normalized here, so a caller's spelling (`/var/...` from
        // `URL.resolvingSymlinksInPath()` or `/private/var/...` from `realpath`)
        // cannot make a scratch root inside the tree go unrecognized.
        let skipping = Set(skippingCanonicalPaths.map { CanonicalPath.resolve($0) ?? CanonicalPath.lexical($0) })
        try walk(
            directory: root,
            relativePath: "",
            excludes: excludes,
            skipping: skipping,
            visit: visit
        )
    }

    private static func walk(
        directory: URL,
        relativePath: String,
        excludes: [String],
        skipping: Set<String>,
        visit: (Entry) throws -> Bool
    ) throws {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw WorkspaceError.unreadable(path: directory.path, underlying: error.localizedDescription)
        }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            let relative = relativePath.isEmpty ? name : relativePath + "/" + name
            if WorkspaceManager.isExcluded(name: name, relativePath: relative, excludes: excludes) {
                continue
            }
            // `CanonicalPath`, not `URL.resolvingSymlinksInPath()`: that strips a
            // leading `/private`, so it would never equal the `realpath` form
            // callers hand in, and a scratch root inside the tree would be walked.
            if skipping.contains(CanonicalPath.resolve(entry.path) ?? CanonicalPath.lexical(entry.path)) {
                continue
            }

            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                _ = try visit(Entry(url: entry, relativePath: relative, kind: .symbolicLink))
            } else if values?.isDirectory == true {
                if try visit(Entry(url: entry, relativePath: relative, kind: .directory)) {
                    try walk(
                        directory: entry,
                        relativePath: relative,
                        excludes: excludes,
                        skipping: skipping,
                        visit: visit
                    )
                }
            } else {
                _ = try visit(Entry(url: entry, relativePath: relative, kind: .file))
            }
        }
    }
}
