import Foundation

/// An evidence archive read back from disk, with every file checked against
/// the hash its manifest records. Only entries whose bytes still match their
/// recorded hash, and whose own run/plan/mutation identity agrees with the
/// manifest, appear in `entries`; everything else is a `problem`.
public struct LoadedEvidenceArchive: Sendable {
    public struct Problem: Error, Sendable, Equatable {
        public let mutationID: String?
        public let detail: String

        public init(mutationID: String?, detail: String) {
            self.mutationID = mutationID
            self.detail = detail
        }
    }

    public let directory: URL
    /// `nil` when `manifest.json` is missing or unreadable.
    public let manifest: EvidenceArchiveManifest?
    /// Hash of the manifest's bytes as read, to compare with the report's reference.
    public let manifestHash: String?
    public let entries: [String: EvidenceArchiveEntry]
    public let problems: [Problem]
}

public enum EvidenceArchiveReader {
    /// The archive directory a report points at, looked for under each of
    /// `roots` in order. `nil` when the report records no archive or none of
    /// the candidate directories exists.
    public static func discover(for report: RunReport, roots: [URL]) -> URL? {
        guard let reference = report.evidenceArchive, EvidenceArchiveCodec.isValidRunID(reference.runID) else { return nil }
        for root in roots {
            let candidate = root
                .appendingPathComponent(EvidenceArchiveCodec.relativeRoot)
                .appendingPathComponent(reference.runID)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    public static func load(directory: URL) -> LoadedEvidenceArchive {
        let manifestURL = directory.appendingPathComponent(EvidenceArchiveCodec.manifestFileName)
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            return failed(directory, "manifest.json could not be read: \(error.localizedDescription)")
        }
        let manifest: EvidenceArchiveManifest
        do {
            manifest = try EvidenceArchiveCodec.decodeManifest(manifestData)
        } catch {
            return failed(directory, "manifest.json is not a valid evidence manifest: \(error)")
        }
        guard manifest.schemaVersion == SchemaVersion.evidenceArchive else {
            return failed(
                directory,
                "manifest schema version \(manifest.schemaVersion) is not supported (expects \(SchemaVersion.evidenceArchive))"
            )
        }

        guard EvidenceArchiveCodec.isValidRunID(manifest.runID) else {
            return failed(directory, "manifest run ID is not a plain run identifier")
        }

        var entries: [String: EvidenceArchiveEntry] = [:]
        var problems: [LoadedEvidenceArchive.Problem] = []
        let observations = directory.appendingPathComponent(EvidenceArchiveCodec.observationsDirectoryName)
        var listed = Set<String>()
        for item in manifest.entries {
            guard listed.insert(item.file).inserted, entries[item.mutationID] == nil else {
                problems.append(.init(mutationID: item.mutationID, detail: "listed more than once in the manifest"))
                continue
            }
            switch loadEntry(item, manifest: manifest, observations: observations) {
            case let .success(entry): entries[item.mutationID] = entry
            case let .failure(problem): problems.append(problem)
            }
        }

        let present = (try? FileManager.default.contentsOfDirectory(atPath: observations.path)) ?? []
        for name in present.sorted() where !listed.contains(name) {
            problems.append(.init(mutationID: nil, detail: "\(name) is in observations/ but not in the manifest"))
        }
        return LoadedEvidenceArchive(
            directory: directory, manifest: manifest, manifestHash: ContentHash.of(manifestData),
            entries: entries, problems: problems
        )
    }

    private static func failed(_ directory: URL, _ detail: String) -> LoadedEvidenceArchive {
        LoadedEvidenceArchive(
            directory: directory, manifest: nil, manifestHash: nil, entries: [:],
            problems: [.init(mutationID: nil, detail: detail)]
        )
    }

    private static func loadEntry(
        _ item: EvidenceArchiveManifest.Entry, manifest: EvidenceArchiveManifest, observations: URL
    ) -> Result<EvidenceArchiveEntry, LoadedEvidenceArchive.Problem> {
        func problem(_ detail: String) -> Result<EvidenceArchiveEntry, LoadedEvidenceArchive.Problem> {
            .failure(.init(mutationID: item.mutationID, detail: detail))
        }
        guard !item.file.isEmpty, !item.file.contains("/"), !item.file.contains("..") else {
            return problem("its manifest file name is not a plain file name")
        }
        let data: Data
        do {
            data = try Data(contentsOf: observations.appendingPathComponent(item.file))
        } catch {
            return problem("its observation file is missing or unreadable")
        }
        guard ContentHash.of(data) == item.hash else {
            return problem("its observation file does not match the hash the manifest records (edited, or the hash was)")
        }
        let entry: EvidenceArchiveEntry
        do {
            entry = try EvidenceArchiveCodec.decodeEntry(data)
        } catch {
            return problem("its observation file does not decode: \(error)")
        }
        guard entry.runID == manifest.runID, entry.planID == manifest.planID else {
            return problem("its observation file names run \(entry.runID) / plan \(entry.planID), not the manifest's")
        }
        guard entry.mutationID == item.mutationID, entry.observations.plannedMutation.mutationID.rawValue == item.mutationID else {
            return problem("its observation file is for a different mutation")
        }
        return .success(entry)
    }
}
