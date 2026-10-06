import Foundation
import MutationModel

/// Applies `evidence.keep`: removes the oldest evidence archives so that only
/// the newest `keep` remain, the run that just wrote its own included.
///
/// Only a plain (non-symlink) directory with a valid run ID for a name that
/// holds a `manifest.json` or an `observations/` directory is ever removed;
/// anything else under the evidence root is left alone. Removing an archive
/// makes the report that referenced it fall back to Tier A.
public enum EvidenceArchivePruner {
    public struct Outcome: Sendable, Equatable {
        public let removed: [String]
        public let failures: [String]
    }

    @discardableResult
    public static func prune(root: URL, keep: Int, current: String) -> Outcome {
        let fileManager = FileManager.default
        guard keep >= 1, let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return Outcome(removed: [], failures: [])
        }
        var archives: [(name: String, modified: Date)] = []
        for name in names where EvidenceArchiveCodec.isValidRunID(name) {
            let url = root.appendingPathComponent(name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  looksLikeArchive(url)
            else { continue }
            archives.append((name, (attributes[.modificationDate] as? Date) ?? .distantPast))
        }
        // The run's own archive always counts as the newest.
        archives.sort { lhs, rhs in
            if lhs.name == current || rhs.name == current { return lhs.name == current }
            return lhs.modified != rhs.modified ? lhs.modified > rhs.modified : lhs.name > rhs.name
        }
        var removed: [String] = []
        var failures: [String] = []
        for archive in archives.dropFirst(keep) {
            do {
                try fileManager.removeItem(at: root.appendingPathComponent(archive.name))
                removed.append(archive.name)
            } catch {
                failures.append("\(archive.name): \(error.localizedDescription)")
            }
        }
        return Outcome(removed: removed.sorted(), failures: failures.sorted())
    }

    private static func looksLikeArchive(_ directory: URL) -> Bool {
        [EvidenceArchiveCodec.manifestFileName, EvidenceArchiveCodec.observationsDirectoryName].contains { name in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }
}
