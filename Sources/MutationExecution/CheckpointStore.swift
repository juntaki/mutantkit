import Foundation
import MutationModel

public enum CheckpointError: Error, CustomStringConvertible {
    case unreadable(path: String, underlying: String)
    case unwritable(path: String, underlying: String)
    case corruptRecord(path: String, line: Int, underlying: String)
    /// The same `MutationID` was recorded more than once. A checkpoint is
    /// append-only, so this can only mean the same mutant was finalized
    /// twice in one run — a real bug, not something safe to resolve by
    /// picking whichever line happened to come first or last.
    case duplicateRecord(path: String, mutationID: MutationID)

    public var description: String {
        switch self {
        case let .unreadable(path, underlying):
            "Could not read the checkpoint file \(path): \(underlying)"
        case let .unwritable(path, underlying):
            "Could not write the checkpoint file \(path): \(underlying)"
        case let .corruptRecord(path, line, underlying):
            """
            Line \(line) of \(path) is not a readable result: \(underlying). The file was \
            edited by hand or written by an incompatible version; delete it to start over.
            """
        case let .duplicateRecord(path, mutationID):
            "\(path) records \(mutationID) more than once — delete it to start over."
        }
    }
}

/// Persists each mutant's result the moment it is known, so a run can be resumed.
///
/// A full mutation run is hours of builds. Nothing about that work should have to
/// be repeated because a machine rebooted or someone pressed Ctrl-C, so results
/// are not held until the end: each one is appended and flushed as it lands.
///
/// The format is JSON Lines rather than a JSON array because an array has to be
/// closed to be valid — an interrupted run would leave an unreadable file, which
/// is exactly the moment the file has to be readable. One line is one complete
/// record, and a record that was half-written when the process died is discarded
/// on the next open.
public actor CheckpointStore {
    private let url: URL
    private var handle: FileHandle?
    /// The confirmation policy `loadAll`'s reverify uses — see
    /// `MutationResultCache`'s own `policy` doc comment for why this is
    /// required rather than defaulted.
    private let policy: MutationVerdictVerifier.VerdictVerificationPolicy

    public init(url: URL, policy: MutationVerdictVerifier.VerdictVerificationPolicy) {
        self.url = url
        self.policy = policy
    }

    /// The untrusted, on-disk shape of one checkpointed mutant. Carries the
    /// *raw* `MutationObservations` — never a `VerifiedMutationRecord` or
    /// `MutationResult` outcome directly — so `loadAll` has no choice but to
    /// call `MutationVerdictVerifier.verify` itself before trusting
    /// anything about this line (ADR-0006 Stage 1, second review round: a
    /// prior version of this file decoded `MutationResult` and merely
    /// re-derived a `VerdictProof` from its already-decided `outcome`,
    /// which revalidates internal shape but never re-judges the underlying
    /// facts — a structurally-consistent forged line would have passed).
    /// Durations are operational timing the verifier never sees, carried
    /// alongside rather than inside `observations`.
    private struct Record: Codable {
        let observations: MutationObservations
        let durationSeconds: Double
        let buildDurationSeconds: Double?
        let testDurationSeconds: Double?
        let confirmationDurationSeconds: Double?
    }

    /// Appends one mutant's observations and flushes to disk before returning.
    ///
    /// The flush is the point: a checkpoint still sitting in a buffer when the
    /// machine goes down has bought nothing.
    public func record(
        _ observations: MutationObservations,
        durationSeconds: Double,
        buildDurationSeconds: Double? = nil,
        testDurationSeconds: Double? = nil,
        confirmationDurationSeconds: Double? = nil
    ) async throws {
        let handle = try openForAppending()

        var line = try encode(Record(
            observations: observations, durationSeconds: durationSeconds, buildDurationSeconds: buildDurationSeconds,
            testDurationSeconds: testDurationSeconds, confirmationDurationSeconds: confirmationDurationSeconds
        ))
        line.append(0x0A)

        do {
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } catch {
            throw CheckpointError.unwritable(path: url.path, underlying: error.localizedDescription)
        }
    }

    public func completedIDs(plan: MutationPlan) async throws -> Set<MutationID> {
        Set(try await loadAll(plan: plan).map(\.id))
    }

    /// Every mutant's verdict, re-derived fresh from its checkpointed
    /// observations, in the order they completed.
    ///
    /// ADR-0006 Stage 1: `plan` is required, not optional convenience — a
    /// checkpoint line's own `MutationObservations` are decoded as
    /// untrusted, validated against `plan`'s own point for the same
    /// `MutationID` (content identity: `pointDigest`, not just an ID that
    /// happens to match), re-verified through `MutationVerdictVerifier
    /// .verify` exactly like a fresh evaluation would be, and only then
    /// projected. A line whose mutation is no longer in `plan`, or whose
    /// content no longer matches the planned point, is dropped rather than
    /// resumed from — the mutant is simply re-evaluated fresh, which is
    /// always safe, unlike silently trusting a stale or hand-edited line
    /// would be. A line whose `MutationID` repeats an earlier one in this
    /// same file is a real bug (an append-only log recorded the same
    /// mutant twice), not a case to resolve by picking a winner — see
    /// `CheckpointError.duplicateRecord`.
    public func loadAll(plan: MutationPlan) async throws -> [MutationResult] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CheckpointError.unreadable(path: url.path, underlying: error.localizedDescription)
        }

        // Not `Dictionary(uniqueKeysWithValues:)`: `plan` here is whatever
        // the caller passed in, not guaranteed to have gone through
        // `MutationPlan.decode`'s validation — a duplicate ID must not trap
        // a checkpoint resume. First-seen point per ID; a duplicate-ID plan
        // is malformed regardless of what loadAll does with it here.
        var pointsByID: [MutationID: MutationPoint] = [:]
        for point in plan.mutations where pointsByID[point.id] == nil {
            pointsByID[point.id] = point
        }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let decoder = MutationPlan.decoder()
        var results: [MutationResult] = []
        var seen: Set<MutationID> = []

        for (index, line) in lines.enumerated() where !line.isEmpty {
            let decoded: Record
            do {
                decoded = try decoder.decode(Record.self, from: Data(line))
            } catch {
                // A kill between `write` and `synchronize` truncates the last
                // line and nothing else. Losing one mutant's result costs one
                // rebuild; refusing the file costs the whole run.
                if index == lines.count - 1 { break }
                throw CheckpointError.corruptRecord(
                    path: url.path,
                    line: index + 1,
                    underlying: error.localizedDescription
                )
            }
            let ref = decoded.observations.plannedMutation
            guard let point = pointsByID[ref.mutationID], ref.pointDigest == PlannedMutationRef.pointDigest(for: point) else {
                continue
            }
            guard seen.insert(ref.mutationID).inserted else {
                throw CheckpointError.duplicateRecord(path: url.path, mutationID: ref.mutationID)
            }
            let verified = MutationVerdictVerifier.verify(decoded.observations, policy: policy)
            guard let projected = try? MutationResult.projected(
                from: verified, point: point, planID: plan.planID, workUnitID: plan.workUnitID,
                durationSeconds: decoded.durationSeconds, buildDurationSeconds: decoded.buildDurationSeconds,
                testDurationSeconds: decoded.testDurationSeconds, confirmationDurationSeconds: decoded.confirmationDurationSeconds
            ) else { continue }
            results.append(projected)
        }

        return results
    }

    // MARK: - File handling

    private func openForAppending() throws -> FileHandle {
        if let handle { return handle }

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CheckpointError.unwritable(path: directory.path, underlying: error.localizedDescription)
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CheckpointError.unwritable(path: url.path, underlying: "could not create the file")
            }
        }

        let opened: FileHandle
        do {
            opened = try FileHandle(forUpdating: url)
            try truncateToLastCompleteRecord(opened)
            try opened.seekToEnd()
        } catch let error as CheckpointError {
            throw error
        } catch {
            throw CheckpointError.unwritable(path: url.path, underlying: error.localizedDescription)
        }

        handle = opened
        return opened
    }

    /// Drops a trailing partial line before anything is appended after it.
    ///
    /// `loadAll` forgives a truncated final line, but only while it *is* final.
    /// Appending behind one would strand the fragment in the middle of the file,
    /// where it becomes indistinguishable from real corruption.
    private func truncateToLastCompleteRecord(_ handle: FileHandle) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CheckpointError.unreadable(path: url.path, underlying: error.localizedDescription)
        }
        guard !data.isEmpty else { return }

        let end = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
        let complete = data.distance(from: data.startIndex, to: end)
        guard complete < data.count else { return }

        do {
            try handle.truncate(atOffset: UInt64(complete))
        } catch {
            throw CheckpointError.unwritable(path: url.path, underlying: error.localizedDescription)
        }
    }

    private func encode(_ record: Record) throws -> Data {
        // Not pretty-printed: one record has to be one line. JSON escapes every
        // newline inside a string, so no diagnosis or diff can break the format.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        do {
            return try encoder.encode(record)
        } catch {
            throw CheckpointError.unwritable(path: url.path, underlying: error.localizedDescription)
        }
    }
}
