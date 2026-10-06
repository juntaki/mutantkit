import Foundation
import MutationModel

public enum EvidenceArchiveError: Error, CustomStringConvertible {
    case unwritable(path: String, underlying: String)

    public var description: String {
        switch self {
        case let .unwritable(path, underlying):
            "Could not write the evidence archive file \(path): \(underlying)"
        }
    }
}

/// Writes the opt-in evidence archive for one run:
/// `.mutantkit/evidence/<run-id>/observations/<digest>.json` per evaluated
/// mutant, then `manifest.json` (hashes of every observation file, the
/// confirmation policy and the versions the run used) when the run is sealed.
///
/// A `runID` that is not a plain identifier (see
/// `EvidenceArchiveCodec.isValidRunID`) is replaced by a fresh one.
///
/// Every file is written atomically. A failure is thrown to the caller, which
/// reports it as an operational issue; nothing here can change a verdict, and
/// the run carries on without the archived observation.
public final class EvidenceArchiveWriter: @unchecked Sendable {
    public let runID: String
    public let directory: URL
    private let evidenceRoot: URL
    private let planID: String
    private let workUnitID: String
    private let policy: MutationVerdictVerifier.VerdictVerificationPolicy
    private let lock = NSLock()
    private var entries: [String: EvidenceArchiveManifest.Entry] = [:]

    public init(
        evidenceRoot: URL, runID: String = UUID().uuidString.lowercased(), plan: MutationPlan,
        policy: MutationVerdictVerifier.VerdictVerificationPolicy
    ) {
        // A run ID that is not a single plain path component would let the
        // archive be written elsewhere; fall back to a fresh one.
        let safeRunID = EvidenceArchiveCodec.isValidRunID(runID) ? runID : UUID().uuidString.lowercased()
        self.runID = safeRunID
        self.evidenceRoot = evidenceRoot
        directory = evidenceRoot.appendingPathComponent(safeRunID)
        planID = plan.planID
        workUnitID = plan.workUnitID
        self.policy = policy
    }

    /// The archive holds full observations (working directories, test output,
    /// source diffs), so it is readable by the owner only.
    static let directoryPermissions = 0o700
    static let filePermissions = 0o600

    /// Creates `directory` and every directory between the evidence root and
    /// it owner-only, tightening ones an earlier run left more open.
    private func makePrivateDirectories(_ directory: URL) throws {
        var chain: [URL] = []
        var current = directory.standardizedFileURL
        let root = evidenceRoot.standardizedFileURL
        while current.path.count >= root.path.count {
            chain.append(current)
            if current.path == root.path { break }
            current.deleteLastPathComponent()
        }
        for url in chain.reversed() {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: Self.directoryPermissions]
            )
            try makePrivate(url, permissions: Self.directoryPermissions)
        }
    }

    private func makePrivate(_ url: URL, permissions: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private var writeFailures = 0
    private var firstWriteFailure: String?

    /// Notes a failed `record`. Returns `true` for the first one, so the
    /// caller warns once instead of once per mutant.
    public func noteWriteFailure(_ description: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        writeFailures += 1
        if firstWriteFailure == nil { firstWriteFailure = description }
        return writeFailures == 1
    }

    /// How many observations could not be archived, and the first reason.
    public var writeFailureSummary: (count: Int, first: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (writeFailures, firstWriteFailure)
    }

    public var recordedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Writes one mutant's raw observations and remembers its content hash.
    public func record(_ observations: MutationObservations) throws {
        let id = observations.plannedMutation.mutationID.rawValue
        let file = EvidenceArchiveCodec.fileName(forMutationID: id)
        let url = directory
            .appendingPathComponent(EvidenceArchiveCodec.observationsDirectoryName)
            .appendingPathComponent(file)
        let data: Data
        do {
            data = try EvidenceArchiveCodec.encode(EvidenceArchiveEntry(runID: runID, planID: planID, observations: observations))
            try makePrivateDirectories(url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
            try makePrivate(url, permissions: Self.filePermissions)
        } catch {
            throw EvidenceArchiveError.unwritable(path: url.path, underlying: error.localizedDescription)
        }
        lock.lock()
        entries[id] = EvidenceArchiveManifest.Entry(mutationID: id, file: file, hash: ContentHash.of(data))
        lock.unlock()
    }

    /// Writes `manifest.json` and returns what the report should record.
    public func seal() throws -> EvidenceArchiveReference {
        lock.lock()
        let recorded = Array(entries.values)
        lock.unlock()
        let url = directory.appendingPathComponent(EvidenceArchiveCodec.manifestFileName)
        let data: Data
        do {
            data = try EvidenceArchiveCodec.encode(EvidenceArchiveManifest(
                runID: runID, planID: planID, workUnitID: workUnitID, policy: policy, entries: recorded
            ))
            try makePrivateDirectories(directory)
            try data.write(to: url, options: .atomic)
            try makePrivate(url, permissions: Self.filePermissions)
        } catch {
            throw EvidenceArchiveError.unwritable(path: url.path, underlying: error.localizedDescription)
        }
        return EvidenceArchiveReference(runID: runID, manifestHash: ContentHash.of(data), entryCount: recorded.count)
    }
}
