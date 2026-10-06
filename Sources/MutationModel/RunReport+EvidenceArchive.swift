extension RunReport {
    /// This report with the run's evidence archive recorded and any archive
    /// problems appended to its operational issues. Every verdict, the
    /// integrity record and the score are carried over untouched.
    public func attachingEvidenceArchive(
        _ reference: EvidenceArchiveReference?, additionalIssues: [OperationalIssue] = []
    ) -> RunReport {
        RunReport(copying: self, evidenceArchive: reference, operationalIssues: operationalIssues + additionalIssues)
    }

    private init(copying other: RunReport, evidenceArchive: EvidenceArchiveReference?, operationalIssues: [OperationalIssue]) {
        schemaVersion = other.schemaVersion
        planID = other.planID
        startedAt = other.startedAt
        finishedAt = other.finishedAt
        projectRoot = other.projectRoot
        toolchain = other.toolchain
        baseline = other.baseline
        results = other.results
        integrity = other.integrity
        score = other.score
        batchExecution = other.batchExecution
        executionStrategy = other.executionStrategy
        self.operationalIssues = operationalIssues
        self.evidenceArchive = evidenceArchive
    }
}
