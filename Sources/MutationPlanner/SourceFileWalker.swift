import Foundation
import MutationModel

/// Something the walk could not see. A gap means the discovered file list may
/// be smaller than the real eligible set, so it is never silently dropped.
public struct SourceDiscoveryGap: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Equatable, Sendable {
        /// A directory that policy says to descend into could not be listed.
        case directoryUnreadable
        /// An entry's file type could not be determined.
        case metadataUnreadable
    }

    public let relativePath: String
    public let kind: Kind
    public let detail: String

    public init(relativePath: String, kind: Kind, detail: String) {
        self.relativePath = relativePath
        self.kind = kind
        self.detail = detail
    }

    public var description: String { "\(relativePath) (\(kind.rawValue)): \(detail)" }
}

/// The outcome of one source walk: eligible files plus an explicit statement of
/// whether the walk saw everything it was supposed to.
///
/// Intentional pruning (build directories, symlinks, user excludes) is not a
/// gap; only filesystem failures are.
public struct SourceDiscovery: Equatable, Sendable {
    /// Repository-relative, `/`-separated, sorted.
    public let files: [String]
    public let gaps: [SourceDiscoveryGap]

    public var isComplete: Bool { gaps.isEmpty }

    /// The eligible files, or `PlannerError.incompleteSourceDiscovery` — a plan
    /// built from a partial walk would be a green, smaller plan.
    public func requireComplete() throws -> [String] {
        guard isComplete else { throw PlannerError.incompleteSourceDiscovery(gaps) }
        return files
    }
}

/// The filesystem operations the walk needs, injectable so unreadable-path
/// behaviour is testable without relying on permissions.
public struct SourceWalkerFileSystem: Sendable {
    public enum EntryKind: Equatable, Sendable { case directory, symbolicLink, file }

    public struct Entry: Sendable {
        public let name: String
        public let kind: Result<EntryKind, any Error>

        public init(name: String, kind: Result<EntryKind, any Error>) {
            self.name = name
            self.kind = kind
        }
    }

    public var list: @Sendable (URL) throws -> [Entry]

    public init(list: @escaping @Sendable (URL) throws -> [Entry]) {
        self.list = list
    }

    public static let live = SourceWalkerFileSystem { directory in
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        return entries.map { entry in
            let kind: Result<EntryKind, any Error> = Result {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { return .symbolicLink }
                return values.isDirectory == true ? .directory : .file
            }
            return Entry(name: entry.lastPathComponent, kind: kind)
        }
    }
}

/// Finds the `.swift` files a plan should consider.
///
/// Filesystem traversal only: every admission decision belongs to
/// `SourceEligibilityPolicy`. Returns repository-relative, `/`-separated,
/// sorted paths — the same tree always produces the same list in the same
/// order, the first link in the chain that makes a plan reproducible.
public struct SourceFileWalker: Sendable {
    private let root: URL
    private let policy: SourceEligibilityPolicy
    private let fileSystem: SourceWalkerFileSystem

    public init(root: URL, settings: SourceSettings, fileSystem: SourceWalkerFileSystem = .live) {
        self.root = root.standardizedFileURL
        policy = SourceEligibilityPolicy(settings: settings)
        self.fileSystem = fileSystem
    }

    /// Walks the tree. An unreadable root throws; any other unreadable path is
    /// reported as a gap in the result.
    public func discover() throws -> SourceDiscovery {
        var found: [String] = []
        var gaps: [SourceDiscoveryGap] = []
        var pending: [(url: URL, relativePath: String)] = [(root, "")]

        while let directory = pending.popLast() {
            let entries: [SourceWalkerFileSystem.Entry]
            do {
                entries = try fileSystem.list(directory.url)
            } catch {
                if directory.relativePath.isEmpty {
                    throw PlannerError.unreadableDirectory(
                        path: directory.url.path,
                        detail: error.localizedDescription
                    )
                }
                gaps.append(SourceDiscoveryGap(
                    relativePath: directory.relativePath,
                    kind: .directoryUnreadable,
                    detail: error.localizedDescription
                ))
                continue
            }

            for entry in entries {
                let relativePath = directory.relativePath.isEmpty
                    ? entry.name : directory.relativePath + "/" + entry.name

                let kind: SourceWalkerFileSystem.EntryKind
                switch entry.kind {
                case let .success(resolved):
                    kind = resolved
                case let .failure(error):
                    // An entry policy would reject by name alone (pruned,
                    // excluded, unreachable by any include) cannot hide an
                    // eligible file, so its unreadable metadata is no gap.
                    guard policy.directoryVerdict(relativePath: relativePath).isAdmitted else { continue }
                    gaps.append(SourceDiscoveryGap(
                        relativePath: relativePath,
                        kind: .metadataUnreadable,
                        detail: error.localizedDescription
                    ))
                    continue
                }

                switch kind {
                case .symbolicLink:
                    // Skipped rather than resolved: a link pointing at an
                    // ancestor turns the walk into an infinite loop, and a link
                    // pointing outside the repo produces a path that no
                    // relative anchor can describe.
                    continue
                case .directory:
                    guard policy.directoryVerdict(relativePath: relativePath).isAdmitted else { continue }
                    pending.append((directory.url.appendingPathComponent(entry.name), relativePath))
                case .file:
                    guard policy.fileVerdict(relativePath: relativePath).isAdmitted else { continue }
                    found.append(relativePath)
                }
            }
        }

        return SourceDiscovery(files: found.sorted(), gaps: gaps.sorted { $0.relativePath < $1.relativePath })
    }
}
