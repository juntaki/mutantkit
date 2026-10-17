import MutationModel

public extension TrustReport {
    /// Diagnostic thresholds for `KillEvidenceSection.suspectTests`. Simple
    /// constants, not tuned statistics: a test that failed for at least
    /// `suspectMinMutants` mutants spread over at least `suspectMinFiles`
    /// distinct mutated files is worth a second look. They only decide what is
    /// listed; they never feed a verdict, the score or the trust status.
    enum KillingTestThresholds {
        /// Most rows listed in `killingTests` / `suspectTests`.
        public static let topN = 10
        public static let suspectMinMutants = 10
        public static let suspectMinFiles = 5
        /// The fixed wording attached to every suspect row.
        public static let suspectWarning = "broad-failing/suspect test — confirm with the baseline control"
    }

    /// One test as named by the recorded kill evidence of assertion kills.
    struct KillingTest: Codable, Sendable, Equatable {
        public let test: String
        /// Distinct assertion-killed mutants whose recorded failing tests name it.
        public let mutantCount: Int
        /// Distinct mutated files among those mutants.
        public let fileCount: Int
        /// Of those mutants, how many it was the only failing test for.
        public let soleFailingCount: Int
        /// Of those mutants, how many carry a recorded confirmation that is not
        /// `.confirmed` (retest did not reproduce, differing set, baseline
        /// control failed or not established). A missing record is not counted.
        public let notConfirmedCount: Int
        /// Share of all assertion kills that name this test (0...1).
        public let shareOfKills: Double

        public init(
            test: String, mutantCount: Int, fileCount: Int, soleFailingCount: Int, notConfirmedCount: Int, shareOfKills: Double
        ) {
            self.test = test
            self.mutantCount = mutantCount
            self.fileCount = fileCount
            self.soleFailingCount = soleFailingCount
            self.notConfirmedCount = notConfirmedCount
            self.shareOfKills = shareOfKills
        }
    }

    /// A `KillingTest` that crossed the diagnostic thresholds. Diagnostic only:
    /// a legitimate end-to-end test can kill broadly, so this is never proof of
    /// flakiness and never changes a verdict or the score.
    struct SuspectTest: Codable, Sendable, Equatable {
        public let test: KillingTest
        public let warning: String

        public init(test: KillingTest, warning: String = KillingTestThresholds.suspectWarning) {
            self.test = test
            self.warning = warning
        }
    }

    /// Tally of failing tests over assertion kills; `nil` when no kill names one.
    internal static func killingTests(for results: [MutationResult]) -> (top: [KillingTest], suspects: [SuspectTest])? {
        struct Acc {
            var ids: Set<String> = []
            var files: Set<String> = []
            var sole = 0
            var notConfirmed = 0
        }
        var byTest: [String: Acc] = [:]
        var kills = 0
        for result in results where result.outcome == .killedByAssertion {
            kills += 1
            let evidence = result.evidence
            let named = evidence?.assertionKillAttribution?.failingTests
                ?? evidence?.assertionKillConfirmation?.primaryFailingTests ?? []
            let tests = Set(named)
            let contested = evidence?.assertionKillConfirmation.map { !$0.disposition.isConfirmed } ?? false
            for test in tests {
                var acc = byTest[test, default: Acc()]
                guard acc.ids.insert(result.id.rawValue).inserted else { continue }
                acc.files.insert(result.point.file)
                if tests.count == 1 { acc.sole += 1 }
                if contested { acc.notConfirmed += 1 }
                byTest[test] = acc
            }
        }
        guard !byTest.isEmpty else { return nil }
        let rows = byTest.map {
            KillingTest(
                test: $0.key, mutantCount: $0.value.ids.count, fileCount: $0.value.files.count,
                soleFailingCount: $0.value.sole, notConfirmedCount: $0.value.notConfirmed,
                shareOfKills: Double($0.value.ids.count) / Double(kills)
            )
        }.sorted {
            if $0.mutantCount != $1.mutantCount { return $0.mutantCount > $1.mutantCount }
            if $0.fileCount != $1.fileCount { return $0.fileCount > $1.fileCount }
            return $0.test < $1.test
        }
        let suspects = rows.filter {
            $0.mutantCount >= KillingTestThresholds.suspectMinMutants && $0.fileCount >= KillingTestThresholds.suspectMinFiles
        }
        return (
            Array(rows.prefix(KillingTestThresholds.topN)),
            suspects.prefix(KillingTestThresholds.topN).map { SuspectTest(test: $0) }
        )
    }
}
