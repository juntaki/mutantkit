import Foundation
import MutationModel

/// Something a sandbox's inputs cannot be proven to be.
public enum SandboxInputClosureError: Error, Equatable, CustomStringConvertible {
    /// An entry the sandbox copy would carry could not be read.
    case unreadable(path: String, reason: String)
    /// A file's bytes are not the bytes the closure recorded: it changed
    /// after the closure was captured, or the copy does not match its source.
    case contentChanged(path: String)
    /// A file the closure does not contain (or contains as another kind).
    case notInClosure(path: String)
    /// The closure was captured for a different project than the one
    /// resolved for this invocation.
    case projectMismatch(closure: String, invocation: String)
    /// A file the plan was built from is not part of what the sandbox
    /// carries, or carries with different bytes.
    case snapshotMismatch(path: String, detail: String)
    /// The run's verified staged copy of the inputs is missing or no longer
    /// what was staged; the source is not at fault.
    case stagingCorrupted(path: String)

    public var description: String {
        switch self {
        case let .unreadable(path, reason):
            "The sandbox inputs cannot be proven: \(path) could not be read (\(reason))."
        case let .contentChanged(path):
            "\(path) changed after the sandbox inputs were captured; refusing to build from a tree that is not the one that was planned."
        case let .notInClosure(path):
            "\(path) is not one of the sandbox inputs captured for this run."
        case let .projectMismatch(closure, invocation):
            "The sandbox inputs were captured for \(closure), but this invocation resolved \(invocation)."
        case let .stagingCorrupted(path):
            "The staged copy of \(path) is missing or was modified after it was verified; refusing to build from it."
        case let .snapshotMismatch(path, detail):
            "The planned source \(path) does not match what the sandbox carries: \(detail)."
        }
    }
}

/// The complete, immutable description of what every sandbox of a run is built
/// from: the project root and each external package root of the layout, and for
/// each root every file, symlink and directory a sandbox copy carries, with the
/// content identity read once when the closure was captured.
///
/// A sandbox is materialized *from* this value, never by re-walking the live
/// tree, and each copied file is checked against the identity recorded here.
/// A source edited, deleted or replaced after capture therefore fails the
/// sandbox instead of silently describing a different tree, and "equal
/// closure digest" is a statement about exactly the entries a sandbox carries
/// (ignored generated files included; build output and other excludes not).
///
/// Capture uses `SandboxCopyWalk`, the one enumeration of sandbox content.
/// `AppleBuildAdapters` derives a closure from a `SourceSnapshot` and a
/// `ResolvedInvocationContext` (`SandboxInputClosure.capture(context:snapshot:...)`).
public struct SandboxInputClosure: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let relativePath: String
        public let kind: SandboxCopyWalk.Kind
        /// File: content hash. Symbolic link: hash of the link text (a link
        /// is recreated, never followed). Directory: `nil`.
        public let identity: String?
        /// Symbolic link: the link text.
        public let linkTarget: String?
    }

    /// One tree of the layout: the project, or an external local package.
    public struct Root: Sendable, Equatable {
        /// Below the container; empty for a project-only layout's project.
        public let containerRelativePath: String
        public let sourceRoot: URL
        /// Pre-order, siblings sorted by name (the walk order).
        public let entries: [Entry]
        private let index: [String: Int]

        init(containerRelativePath: String, sourceRoot: URL, entries: [Entry]) {
            self.containerRelativePath = containerRelativePath
            self.sourceRoot = sourceRoot
            self.entries = entries
            index = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.relativePath, $0) })
        }

        public func entry(at relativePath: String) -> Entry? {
            index[relativePath].map { entries[$0] }
        }
    }

    public let layout: SandboxLayout
    public let excludes: [String]
    /// The project root first, then the external roots in layout order.
    public let roots: [Root]
    /// One digest over layout shape, excludes and every entry.
    public let digest: String

    /// The project root's tree.
    public var project: Root { roots[0] }

    /// Walks every root of `layout` once and records what a sandbox carries.
    ///
    /// Throws when anything cannot be read: an unreadable entry must never be
    /// indistinguishable from an absent one.
    public static func capture(
        layout: SandboxLayout,
        excludes: [String] = WorkspaceManager.defaultExcludes,
        scratchRoots: [URL] = []
    ) throws -> SandboxInputClosure {
        let skipping = Set(scratchRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let sources = [(layout.workspaceRelativePath, layout.projectRoot)]
            + layout.externalRoots.map { ($0.relativePath, $0.sourceRoot) }
        let roots = try sources.map { relativePath, sourceRoot in
            Root(
                containerRelativePath: relativePath,
                sourceRoot: sourceRoot,
                entries: try entries(of: sourceRoot, excludes: excludes, skipping: skipping)
            )
        }
        var lines = ["excludes=" + excludes.joined(separator: "\u{1F}")]
        for root in roots {
            lines.append("root=\(root.containerRelativePath.utf8.count):\(root.containerRelativePath)")
            for entry in root.entries {
                lines.append("\(entry.relativePath.utf8.count):\(entry.relativePath)|\(entry.kind)|\(entry.identity ?? "")")
            }
        }
        return SandboxInputClosure(
            layout: layout, excludes: excludes, roots: roots,
            digest: ContentHash.of(lines.joined(separator: "\n"))
        )
    }

    private static func entries(of root: URL, excludes: [String], skipping: Set<String>) throws -> [Entry] {
        var result: [Entry] = []
        do {
            try SandboxCopyWalk.walk(root: root, excludes: excludes, skippingCanonicalPaths: skipping) { walked in
                switch walked.kind {
                case .directory:
                    result.append(Entry(relativePath: walked.relativePath, kind: .directory, identity: nil, linkTarget: nil))
                    return true
                case .symbolicLink:
                    let target: String
                    do {
                        target = try FileManager.default.destinationOfSymbolicLink(atPath: walked.url.path)
                    } catch {
                        throw SandboxInputClosureError.unreadable(path: walked.url.path, reason: error.localizedDescription)
                    }
                    result.append(Entry(
                        relativePath: walked.relativePath, kind: .symbolicLink,
                        identity: ContentHash.of(target), linkTarget: target
                    ))
                    return false
                case .file:
                    result.append(Entry(
                        relativePath: walked.relativePath, kind: .file,
                        identity: try Self.hash(of: walked.url), linkTarget: nil
                    ))
                    return false
                }
            }
        } catch let error as WorkspaceError {
            throw SandboxInputClosureError.unreadable(path: root.path, reason: "\(error)")
        }
        return result
    }

    /// Hash of the file at `url`, failing (never defaulting) when unreadable.
    static func hash(of url: URL) throws -> String {
        do {
            return try ContentHash.ofFile(at: url)
        } catch {
            throw SandboxInputClosureError.unreadable(path: url.path, reason: error.localizedDescription)
        }
    }

    /// The tree whose container-relative position is `containerRelativePath`.
    func root(atContainerPath containerRelativePath: String) -> Root? {
        roots.first { $0.containerRelativePath == containerRelativePath }
    }
}
