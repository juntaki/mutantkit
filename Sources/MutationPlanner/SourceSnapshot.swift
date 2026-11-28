import Foundation
import MutationModel

/// The authoritative eligible source set for one planning pass: every file the
/// eligibility policy admitted, read exactly once.
///
/// Discovery, suppression parsing and plan file hashes must all derive from
/// this one read. A file edited while planning runs then cannot make the
/// recorded hash, the discovered anchors and the inline suppressions describe
/// three different versions of the same path.
public struct SourceSnapshot: Sendable {
    public struct File: Sendable {
        public let relativePath: String
        public let contentHash: String
        public let data: Data

        public init(relativePath: String, data: Data) {
            self.relativePath = relativePath
            self.data = data
            contentHash = ContentHash.of(data)
        }
    }

    /// Sorted by `relativePath`.
    public let files: [File]

    public init(files: [File]) {
        self.files = files.sorted { $0.relativePath < $1.relativePath }
    }

    /// Hashes keyed by relative path — what `MutationPlan.sourceFileHashes` records.
    public var fileHashes: [String: String] {
        Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0.contentHash) })
    }

    /// Walks `root` under `settings` and reads every eligible file once.
    /// Fails closed on an incomplete walk or an unreadable file.
    public static func load(root: URL, settings: SourceSettings) throws -> SourceSnapshot {
        let root = root.standardizedFileURL
        let paths = try SourceFileWalker(root: root, settings: settings).discover().requireComplete()
        return try SourceSnapshot(files: paths.map { relativePath in
            do {
                return try File(relativePath: relativePath, data: Data(contentsOf: root.appendingPathComponent(relativePath)))
            } catch {
                throw PlannerError.unreadableFile(path: relativePath, detail: error.localizedDescription)
            }
        })
    }
}
