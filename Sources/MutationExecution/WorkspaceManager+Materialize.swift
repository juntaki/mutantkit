import Foundation
import MutationModel

// Materializing a sandbox from a `SandboxInputClosure`; see `WorkspaceManager`.

extension WorkspaceManager {
    static let stagingDirectoryPrefix = ".input-closure-"

    /// What SwiftPM writes into a sandbox that no source tree holds: the
    /// resolution state (`.swiftpm`, an untracked `Package.resolved`), at a
    /// package root. A reused sandbox keeps it when the closure does not
    /// contain it, so repeated builds stay pinned to the versions the first
    /// resolution chose. Anything the closure does contain (a committed
    /// `Package.resolved`) follows the closure: restored, or pruned if deleted.
    static let retainedOnReuse: Set<String> = [".swiftpm", "Package.resolved"]

    /// Which of `retainedOnReuse` the last materialization took from its closure,
    /// so a committed file deleted since is pruned while an adapter-written one is kept.
    static func readRetainedManifest(_ url: URL) -> Set<String> {
        Set(((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    }

    static func writeRetainedManifest(_ url: URL, names: Set<String>) {
        try? Data(names.sorted().joined(separator: "\n").utf8).write(to: url)
    }

    /// The verified copy of `root` inside this manager's staging directory,
    /// building and proving the whole staging area from the live tree on first use.
    func stagedRoot(for root: SandboxInputClosure.Root, closure: SandboxInputClosure) throws -> URL {
        if staged == nil {
            try removeStaging(stagingRoot)
            for source in closure.roots {
                let destination = Self.stagedDirectory(of: source, in: stagingRoot)
                try createDirectory(destination)
                try populate(
                    source, from: source.sourceRoot, to: destination, usesCleanSubtreeIndex: false, proving: true
                )
            }
            staged = StagedInputs(fingerprints: fingerprints(of: closure))
        }
        return Self.stagedDirectory(of: root, in: stagingRoot)
    }

    private func fingerprints(of closure: SandboxInputClosure) -> [String: StagedFile] {
        var result: [String: StagedFile] = [:]
        for root in closure.roots {
            let base = Self.stagedDirectory(of: root, in: stagingRoot)
            for entry in root.entries where entry.kind == .file {
                let url = base.appendingPathComponent(entry.relativePath)
                result[url.path] = StagedFile(of: url, fileManager: fileManager)
            }
        }
        return result
    }

    /// Cheap per-file check that a staged file is still the one that was
    /// verified at staging time (size, modification time, inode).
    func checkStaged(_ url: URL) throws {
        guard let recorded = staged?.fingerprints[url.path],
              StagedFile(of: url, fileManager: fileManager) == recorded
        else { throw SandboxInputClosureError.stagingCorrupted(path: url.path) }
    }

    /// Hash proof of one staged file against the closure.
    func verifyStaged(_ url: URL, against entry: SandboxInputClosure.Entry) throws {
        do { try verify(url, against: entry) } catch { throw SandboxInputClosureError.stagingCorrupted(path: url.path) }
    }

    /// Removes a staging directory, first making read-only source directories
    /// writable again (their modes were carried into it).
    nonisolated func removeStaging(_ url: URL) throws {
        let manager = FileManager.default
        guard (try? manager.attributesOfItem(atPath: url.path)) != nil else { return }
        if let walker = manager.enumerator(atPath: url.path) {
            for case let relative as String in walker {
                let path = url.path + "/" + relative
                if (try? manager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory {
                    try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                }
            }
        }
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        do {
            try manager.removeItem(at: url)
        } catch {
            throw WorkspaceError.unwritable(path: url.path, underlying: error.localizedDescription)
        }
    }

    private static func stagedDirectory(of root: SandboxInputClosure.Root, in staging: URL) -> URL {
        root.containerRelativePath.isEmpty
            ? staging : staging.appendingPathComponent(root.containerRelativePath, isDirectory: true)
    }

    /// Removes what a reused container still holds that the closure does not:
    /// a file deleted from the source since the container was filled.
    /// Excluded names (build state) are left alone, as the walk never carried them.
    func pruneStale(_ directory: URL, root: SandboxInputClosure.Root, relativePath: String, strict: Bool) throws {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw WorkspaceError.unreadable(path: directory.path, underlying: error.localizedDescription)
        }
        for name in names {
            let relative = relativePath.isEmpty ? name : relativePath + "/" + name
            let url = directory.appendingPathComponent(name)
            if let entry = root.entry(at: relative) {
                guard entry.kind == .directory else { continue }
                // Never descend through a link: pruning would delete outside the sandbox.
                guard try existingType(at: url) == .typeDirectory else {
                    throw SandboxInputClosureError.contentChanged(path: entry.relativePath)
                }
                try pruneStale(url, root: root, relativePath: relative, strict: strict)
            } else if !strict, Self.isExcluded(name: name, relativePath: relative, excludes: excludes)
                || (relativePath.isEmpty && Self.retainedOnReuse.contains(name) && !previouslyFromClosure.contains(name)) {
                continue
            } else {
                try removeIfPresent(url)
            }
        }
    }

    func existingType(at url: URL) throws -> FileAttributeType? {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else { return .typeSymbolicLink }
        return (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    func verify(_ copy: URL, against entry: SandboxInputClosure.Entry) throws {
        // Data(contentsOf:) follows links, so require a regular file first.
        guard (try? fileManager.attributesOfItem(atPath: copy.path))?[.type] as? FileAttributeType == .typeRegular,
              try SandboxInputClosure.hash(of: copy) == entry.identity
        else {
            throw SandboxInputClosureError.contentChanged(path: entry.relativePath)
        }
    }

    /// Puts a copy of `source` at `destination` and proves it carries the
    /// bytes recorded in `entry`. An existing destination is removed first
    /// (a failed removal throws), and a copy is always made: there is no
    /// reuse of what is already there on the strength of size and mtime.
    func materialize(_ source: URL, at destination: URL, entry: SandboxInputClosure.Entry, proving: Bool) throws {
        guard (try? fileManager.attributesOfItem(atPath: source.path)) != nil else {
            throw proving
                ? SandboxInputClosureError.contentChanged(path: entry.relativePath)
                : SandboxInputClosureError.stagingCorrupted(path: source.path)
        }
        if !proving { try checkStaged(source) }
        try removeIfPresent(destination)
        if !(supportsAPFSClone() && Self.clone(source, to: destination)) {
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                throw WorkspaceError.unwritable(path: destination.path, underlying: error.localizedDescription)
            }
        }
        if proving { try verify(destination, against: entry) }
    }

    func verifyClonedDescendant(_ entry: SandboxInputClosure.Entry, at target: URL) throws {
        switch entry.kind {
        case .file:
            try verify(target, against: entry)
        case .symbolicLink:
            guard (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) == entry.linkTarget else {
                throw SandboxInputClosureError.contentChanged(path: entry.relativePath)
            }
        case .directory:
            guard try existingType(at: target) == .typeDirectory else {
                throw SandboxInputClosureError.contentChanged(path: entry.relativePath)
            }
        }
    }
}

/// Size, modification time and inode of one staged file, recorded when staging
/// was verified.
struct StagedFile: Equatable {
    let size: Int?
    let modified: Date?
    let inode: UInt?

    init(of url: URL, fileManager: FileManager) {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        size = attributes?[.size] as? Int
        modified = attributes?[.modificationDate] as? Date
        inode = attributes?[.systemFileNumber] as? UInt
    }
}

/// The verified staging area of one manager.
struct StagedInputs {
    let fingerprints: [String: StagedFile]
}

/// Source directory modes to apply to staged directories once their children
/// exist, deepest first: a read-only directory must not block its own contents.
struct DirectoryModes {
    private var pending: [(target: URL, mode: Any)] = []

    mutating func record(source: URL, target: URL, enabled: Bool) {
        guard enabled, let mode = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.posixPermissions]
        else { return }
        pending.append((target, mode))
    }

    func apply() throws {
        for (target, mode) in pending.reversed() {
            do {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
            } catch {
                throw WorkspaceError.unwritable(path: target.path, underlying: error.localizedDescription)
            }
        }
    }
}
