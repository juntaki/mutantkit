import Foundation
import MutationModel

/// Persistent cache of a baseline's per-test coverage attribution, so the
/// ~85-minute `measurePerTestCoverage` pass on a real project does not have
/// to run again on the next iteration against unchanged source, tests,
/// toolchain, or configuration.
///
/// Distinct from `CheckpointStore` on purpose. A checkpoint exists to resume
/// an interrupted run *within* one continuous attempt — its scope is one
/// `RunContextFingerprint`, and it records individual mutant verdicts. This
/// cache records the much more expensive, run-independent fact of "which
/// tests covered which lines at baseline", which only changes when the
/// inputs to that measurement change, not when a mutant is re-attempted.
///
/// The cache is intentionally dumb about reuse: a hit requires exact
/// equality on the coverage context digest. There is no partial
/// invalidation ("changed tests only") here — that is a later optimisation,
/// not a v1 concern. The digest is computed in the CLI layer from the same
/// inputs `RunContextFingerprint` uses, minus the plan's `workUnitID`,
/// because coverage attribution depends on the source tree and test suite,
/// not on which mutations were planned against it. Two different plans
/// against the same tree reuse one coverage map; the same plan against a
/// changed tree recomputes it.
public actor CoverageProfileCache {
    public struct Key: Codable, Sendable, Hashable {
        /// A digest of everything the measured coverage depends on: source
        /// tree, test sources, scheme, test targets, destination runtime,
        /// Xcode/Swift versions, coverage configuration. Computed by the
        /// CLI layer, opaque to this type.
        public let contextDigest: String

        public init(contextDigest: String) {
            self.contextDigest = contextDigest
        }

        fileprivate var storageName: String {
            ContentHash.shortDigest(of: contextDigest, length: 32) + ".json"
        }
    }

    private let root: URL
    private let fileManager = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    /// Returns the cached attribution for this context, or `nil` when no
    /// entry exists, the file is unreadable, or the decoded payload fails
    /// the version check. `nil` is the safe answer in every one of those
    /// cases: the caller recomputes coverage from a fresh baseline pass.
    public func load(_ key: Key) -> PerTestCoverageMap? {
        let url = root.appendingPathComponent(key.storageName)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(CacheRecord.self, from: data),
              record.key == key
        else { return nil }
        return record.coverage
    }

    /// Persists a measured attribution. A `nil` map (profiling produced
    /// nothing) is not stored: it carries no reusable fact, and a later run
    /// that does measure something should not be served a stale empty entry.
    public func store(_ coverage: PerTestCoverageMap, for key: Key) {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let record = CacheRecord(key: key, coverage: coverage)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: root.appendingPathComponent(key.storageName), options: .atomic)
    }

    /// Removes every cached entry. Used by `mutantkit run --no-cache`-style
    /// invocations and by tests.
    public func removeAll() {
        try? fileManager.removeItem(at: root)
    }

    private struct CacheRecord: Codable {
        let key: Key
        let coverage: PerTestCoverageMap
    }
}
