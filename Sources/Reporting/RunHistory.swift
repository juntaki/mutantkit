import Foundation
import MutationModel

/// Small, append-only historical record used to track mutation quality and
/// performance across commits/runs without requiring an external dashboard.
public struct RunHistoryRecord: Codable, Sendable, Hashable {
    /// Set internally to `SchemaVersion.runHistoryRecord`, never a caller-
    /// supplied parameter. Decoded leniently (see `init(from:)` below) since
    /// this type is round-tripped through `.mutantkit/history/*.json` —
    /// files written before this field existed have no such key, and
    /// decoding that as a hard failure would silently drop every history
    /// record recorded before this change from `mutantkit history`, for no
    /// reason (the same precedent `MutationPlan.init(from:)` already sets
    /// for `budgetInclusionReasons`).
    public let schemaVersion: Int
    public let planID: String
    public let finishedAt: Date
    public let integrityPassed: Bool
    public let testedScore: Double?
    public let effectiveScore: Double?
    public let killed: Int?
    public let survived: Int?
    public let noCoverage: Int?
    public let wallClockSeconds: Double
    public let toolVersion: String
    public let toolCommitSHA: String?

    public init(report: RunReport) {
        schemaVersion = SchemaVersion.runHistoryRecord
        planID = report.planID
        finishedAt = report.finishedAt
        integrityPassed = report.integrity.passed
        testedScore = report.score?.tested
        effectiveScore = report.score?.effective
        killed = report.score?.killed
        survived = report.score?.survived
        noCoverage = report.score?.noCoverage
        wallClockSeconds = max(0, report.finishedAt.timeIntervalSince(report.startedAt))
        toolVersion = report.toolchain.toolVersion
        toolCommitSHA = report.toolchain.toolCommitSHA
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, planID, finishedAt, integrityPassed, testedScore, effectiveScore
        case killed, survived, noCoverage, wallClockSeconds, toolVersion, toolCommitSHA
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? SchemaVersion.runHistoryRecord
        planID = try container.decode(String.self, forKey: .planID)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        integrityPassed = try container.decode(Bool.self, forKey: .integrityPassed)
        testedScore = try container.decodeIfPresent(Double.self, forKey: .testedScore)
        effectiveScore = try container.decodeIfPresent(Double.self, forKey: .effectiveScore)
        killed = try container.decodeIfPresent(Int.self, forKey: .killed)
        survived = try container.decodeIfPresent(Int.self, forKey: .survived)
        noCoverage = try container.decodeIfPresent(Int.self, forKey: .noCoverage)
        wallClockSeconds = try container.decode(Double.self, forKey: .wallClockSeconds)
        toolVersion = try container.decode(String.self, forKey: .toolVersion)
        toolCommitSHA = try container.decodeIfPresent(String.self, forKey: .toolCommitSHA)
    }
}

/// Stores one JSON file per run. Separate files make concurrent writers safe:
/// there is no shared JSON array to truncate or rewrite, and a partially-written
/// file is ignored by readers rather than corrupting the whole history.
public struct RunHistoryStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func record(_ report: RunReport) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = RunHistoryRecord(report: report)
        let timestamp = Int(record.finishedAt.timeIntervalSince1970 * 1000)
        let suffix = ContentHash.shortDigest(of: report.planID + "\u{1F}" + String(timestamp), length: 12)
        let url = root.appendingPathComponent("\(timestamp)-\(suffix).json")
        let data = try MutationPlan.encoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    public func records(limit: Int? = nil) -> [RunHistoryRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var records = entries.compactMap { url -> RunHistoryRecord? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let record = try? MutationPlan.decoder().decode(RunHistoryRecord.self, from: data)
            else { return nil }
            return record
        }
        records.sort { $0.finishedAt > $1.finishedAt }
        if let limit { return Array(records.prefix(max(0, limit))) }
        return records
    }
}
