
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

    /// Five cases today: `MutationRunner.finalize`'s checkpoint write, a
    /// shared schemata chunk build that genuinely failed to compile
    /// (ADR-0008 Addendum 4's fan-out/observability requirement — one issue
    /// per failed chunk, never one per affected `MutationID`), a chunk whose
    /// build succeeded but whose own build receipt could not be resolved,
    /// and a `noOpCanarySampleRate`-sampled mutant whose build product
    /// hashed identical to baseline yet whose real test run did not simply
    /// pass — see `Configuration.execution.noOpCanarySampleRate`'s own doc
    /// comment. New kinds get added here as they're given the same
    /// treatment — this is not a general-purpose error bucket.
    public enum Kind: String, Codable, Sendable {
        case checkpointWriteFailed
        /// One chunk's shared lowered program did not compile, so every
        /// `MutationID` it covered forfeited schemata's fast path and was
        /// re-run through isolated mode instead. Never affects score or
        /// integrity (every affected mutation still gets a real isolated
        /// verdict) — it is a cost/health signal, which is exactly what
        /// `operationalIssues` is for.
        case schemataChunkBuildFailed
        /// One chunk's own shared lowered program built successfully, but
        /// its build receipt (the provably-unique image identity schemata
        /// verification depends on) could not be resolved, so every
        /// `MutationID` it covered forfeited schemata's fast path and was
        /// re-run through isolated mode instead. Distinct from
        /// `schemataChunkBuildFailed`: the build itself succeeded, only its
        /// identity proof did not. Never affects score or integrity, for the
        /// same reason `schemataChunkBuildFailed` does not.
        case schemataChunkReceiptUnavailable
        case noOpCanaryUnexpectedOutcome
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
