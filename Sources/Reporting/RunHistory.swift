import Foundation
import MutationModel

/// Small, append-only historical record used to track mutation quality and
/// performance across commits/runs without requiring an external dashboard.
public struct RunHistoryRecord: Codable, Sendable, Hashable {
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
