import Foundation

/// An infrastructure-level problem observed during a run that never affects
/// score or integrity — those stay decided purely by verified proof — but
/// would otherwise vanish once the run ends, since today it only ever reaches
/// stderr. `RunReport.operationalIssues` gives it a place a report reader (or
/// another tool consuming `report.json`) can actually see, alongside the
/// stderr warning a human watching the run live already gets.
public struct OperationalIssue: Codable, Sendable, Hashable {
    public enum Severity: String, Codable, Sendable {
        case warning
        case error
    }

    /// One case today: `MutationRunner.finalize`'s checkpoint write. New
    /// kinds get added here as they're given the same treatment — this is
    /// not a general-purpose error bucket.
    public enum Kind: String, Codable, Sendable {
        case checkpointWriteFailed
    }

    public let severity: Severity
    public let kind: Kind
    public let mutationID: MutationID?
    public let diagnosis: String

    public init(severity: Severity, kind: Kind, mutationID: MutationID?, diagnosis: String) {
        self.severity = severity
        self.kind = kind
        self.mutationID = mutationID
        self.diagnosis = diagnosis
    }
}

/// Collects `OperationalIssue`s from concurrent mutation evaluations without
/// requiring `MutationRunner` itself to serialize around them. An actor, not
/// a lock, because appends come from the same concurrent task group that
/// runs `finalize` for each mutation.
public actor OperationalIssueLog {
    private var storage: [OperationalIssue] = []

    public init() {}

    public func append(_ issue: OperationalIssue) {
        storage.append(issue)
    }

    public func snapshot() -> [OperationalIssue] {
        storage
    }
}
