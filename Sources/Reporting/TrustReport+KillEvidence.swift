import MutationModel

extension TrustReport {
    /// A tally over the verifier-authored kill evidence stored in a report:
    /// which tests credited each assertion kill and how deep the confirmation
    /// chains behind the verdicts are. Counts only; nothing here re-decides a
    /// verdict. A result with no recorded attribution is counted under
    /// `attributionNotRecorded`, never under a favourable heading.
    public struct KillEvidenceSection: Codable, Sendable, Equatable {
        /// Assertion kills in the report.
        public let assertionKills: Int
        /// Failing tests all inside the selection the run was narrowed to.
        public let withinSelection: Int
        /// Whole configured test list ran, failing tests named.
        public let wholeSuiteRan: Int
        /// The run named no failing test; the kill rests on the run status.
        public let failingTestsUnnamed: Int
        /// Attribution absent or not admitting a kill.
        public let attributionNotRecorded: Int
        /// Kills whose failure came from a shared batch invocation.
        public let batchAttributed: Int
        /// Results that went through more than one confirmation round.
        public let cascadeConfirmations: Int

        public init(
            assertionKills: Int, withinSelection: Int, wholeSuiteRan: Int, failingTestsUnnamed: Int,
            attributionNotRecorded: Int, batchAttributed: Int, cascadeConfirmations: Int
        ) {
            self.assertionKills = assertionKills
            self.withinSelection = withinSelection
            self.wholeSuiteRan = wholeSuiteRan
            self.failingTestsUnnamed = failingTestsUnnamed
            self.attributionNotRecorded = attributionNotRecorded
            self.batchAttributed = batchAttributed
            self.cascadeConfirmations = cascadeConfirmations
        }
    }

    /// `nil` when the report holds no assertion kill and no multi-step chain.
    static func killEvidenceSection(for results: [MutationResult]) -> KillEvidenceSection? {
        let kills = results.filter { $0.outcome == .killedByAssertion }
        let cascades = results.filter { ($0.evidence?.confirmationChain.count ?? 0) > 1 }.count
        guard !kills.isEmpty || cascades > 0 else { return nil }

        var within = 0, whole = 0, unnamed = 0, notRecorded = 0, batch = 0
        for kill in kills {
            guard let attribution = kill.evidence?.assertionKillAttribution, attribution.disposition.admitsKill else {
                notRecorded += 1
                continue
            }
            switch attribution.disposition {
            case .withinSelection: within += 1
            case .wholeSuiteRan: whole += 1
            case .failingTestsUnnamed: unnamed += 1
            case .outsideSelection, .executionNotRecorded: notRecorded += 1
            }
            if attribution.attribution == .batch { batch += 1 }
        }
        return KillEvidenceSection(
            assertionKills: kills.count, withinSelection: within, wholeSuiteRan: whole, failingTestsUnnamed: unnamed,
            attributionNotRecorded: notRecorded, batchAttributed: batch, cascadeConfirmations: cascades
        )
    }
}
