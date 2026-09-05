import MutationModel

/// Everything sharding and merging can refuse to do.
public enum ShardingError: Error, CustomStringConvertible {
    case invalidShardCount(Int)
    case noReports
    case planMismatch(expected: String, found: String)
    case toolchainMismatch
    case duplicateResult(MutationID)

    public var description: String {
        switch self {
        case let .invalidShardCount(count):
            "Shard count must be at least 1, got \(count)."
        case .noReports:
            "Cannot merge an empty set of reports."
        case let .planMismatch(expected, found):
            """
            These reports come from different plans (\(expected) and \(found)). Merging them \
            would produce a score for a project state that never existed.
            """
        case .toolchainMismatch:
            """
            The reports were produced by different toolchains. Results measured against \
            different compilers are not comparable, so they will not be merged.
            """
        case let .duplicateResult(id):
            "Mutation \(id) has a result in more than one shard."
        }
    }
}

/// Everything `PlanSharding.subset` can refuse to do.
public enum PlanSubsetError: Error, CustomStringConvertible {
    /// A `MutationID` named more than once in the requested subset. Silently
    /// de-duplicating would make the derived plan's membership depend on
    /// caller sloppiness rather than being an exact, auditable echo of what
    /// was asked for.
    case duplicateRequestedID(MutationID)
    /// A requested `MutationID` that is not present in the parent plan's own
    /// `mutations`. Silently dropping it would make the derived plan smaller
    /// than the caller intended without any signal that anything was lost.
    case missingFromParent([MutationID])

    public var description: String {
        switch self {
        case let .duplicateRequestedID(id):
            "MutationID \(id) was requested more than once; a subset selection must name each mutation exactly once."
        case let .missingFromParent(ids):
            """
            \(ids.count) requested MutationID(s) are not present in the parent plan: \
            \(ids.map(\.rawValue).sorted().joined(separator: ", "))
            """
        }
    }
}

/// Splits a plan across machines and puts the results back together.
///
/// Sharding is a pure function of the plan. No shard knows about any other, no
/// coordinator hands out work, and a shard that dies can be re-run on a
/// different machine and land on exactly the same mutants.
public enum PlanSharding {
    /// Splits a plan into `count` plans.
    ///
    /// Assignment is `FNV-1a(mutation ID) % count`, so a given mutant always
    /// lands in the same shard for a given count — the assignment survives
    /// re-planning, re-ordering and re-running, and it needs no shared state to
    /// compute. Skipped records shard by the same rule, which keeps the union of
    /// the shards exactly equal to the original plan rather than duplicating
    /// every skip `count` times.
    ///
    /// Each shard keeps the full `operators` list and the full
    /// `sourceFileHashes` map: a shard's report has to stay interpretable on its
    /// own, and a shard must be able to detect a source file that changed under
    /// it even for a file it was not assigned any mutant in.
    ///
    /// Shards share the parent's `planID`. They are views of one plan, not new
    /// plans, and the shared ID is what lets `merge` refuse to combine reports
    /// that came from different planning runs.
    public static func shard(plan: MutationPlan, count: Int) throws -> [MutationPlan] {
        guard count >= 1 else { throw ShardingError.invalidShardCount(count) }
        guard count > 1 else { return [plan] }

        var mutations = [[MutationPoint]](repeating: [], count: count)
        var skipped = [[SkippedMutation]](repeating: [], count: count)
        var inclusionReasons = [[InclusionReason]](repeating: [], count: count)

        for point in plan.mutations {
            mutations[index(of: point.id, count: count)].append(point)
        }
        for record in plan.skipped {
            skipped[index(of: record.id, count: count)].append(record)
        }
        // Copied unchanged by the same `MutationID`-keyed rule `mutations`
        // itself shards by — never recomputed from shard-local position or
        // candidate count (ADR-0007 B.7's shard-stability requirement).
        for reason in plan.budgetInclusionReasons {
            inclusionReasons[index(of: reason.mutationID, count: count)].append(reason)
        }

        return (0 ..< count).map { shardIndex in
            MutationPlan(
                planID: plan.planID,
                createdAt: plan.createdAt,
                projectRoot: plan.projectRoot,
                toolchain: plan.toolchain,
                configurationHash: plan.configurationHash,
                sourceFileHashes: plan.sourceFileHashes,
                mutations: mutations[shardIndex],
                skipped: skipped[shardIndex],
                operators: plan.operators,
                budgetInclusionReasons: inclusionReasons[shardIndex]
            )
        }
    }

    /// Which shard a mutation belongs to, for a given shard count.
    public static func index(of id: MutationID, count: Int) -> Int {
        precondition(count >= 1, "Shard count must be at least 1.")
        return Int(StableHash.fnv1a64(id.rawValue) % UInt64(count))
    }

    /// Derives a plan containing exactly `mutationIDs`' mutations, in the same
    /// `planID`/`toolchain`/`configurationHash`/`sourceFileHashes`/`operators`
    /// context as `plan` — a subset plan is a view of `plan`, not a new plan,
    /// on the same terms a shard is (see `shard`'s doc comment): same
    /// provenance identity, same operator/source-file context, so a real
    /// `mutantkit run`/`verify` against the derived plan is genuinely
    /// standalone-runnable rather than partial.
    ///
    /// Unlike `shard`, a subset is not required to partition the parent:
    /// everything not named in `mutationIDs` is simply dropped from
    /// `mutations`/`skipped`/`budgetInclusionReasons`, not preserved in some
    /// complementary plan.
    ///
    /// Fails closed on either malformed input, rather than silently producing
    /// a plan smaller or differently-shaped than the caller asked for:
    /// - a duplicate ID in `mutationIDs` (`.duplicateRequestedID`)
    /// - an ID not present in `plan.mutations` (`.missingFromParent`, naming
    ///   every offending ID so the caller can tell exactly which)
    ///
    /// Does not mutate `plan` — a fresh `MutationPlan` is constructed and
    /// returned, the same way `shard` never mutates its input.
    public static func subset(of plan: MutationPlan, mutationIDs: [MutationID]) throws -> MutationPlan {
        var requested = Set<MutationID>()
        for id in mutationIDs {
            guard requested.insert(id).inserted else {
                throw PlanSubsetError.duplicateRequestedID(id)
            }
        }

        let parentIDs = Set(plan.mutations.map(\.id))
        let missing = requested.subtracting(parentIDs)
        guard missing.isEmpty else {
            throw PlanSubsetError.missingFromParent(missing.sorted { $0.rawValue < $1.rawValue })
        }

        return MutationPlan(
            planID: plan.planID,
            createdAt: plan.createdAt,
            projectRoot: plan.projectRoot,
            toolchain: plan.toolchain,
            configurationHash: plan.configurationHash,
            sourceFileHashes: plan.sourceFileHashes,
            mutations: plan.mutations.filter { requested.contains($0.id) },
            skipped: plan.skipped.filter { requested.contains($0.id) },
            operators: plan.operators,
            budgetInclusionReasons: plan.budgetInclusionReasons.filter { requested.contains($0.mutationID) }
        )
    }

    /// Combines shard reports into one report for the whole plan.
    ///
    /// The unsharded `plan` is required rather than reconstructed from the
    /// reports, because reconciliation is the point: only the original plan
    /// knows about a mutant whose shard never reported at all. Rebuilding the
    /// plan from the reports would make a lost shard look like a smaller run
    /// that succeeded.
    public static func merge(reports: [RunReport], plan: MutationPlan) throws -> RunReport {
        guard let first = reports.first else { throw ShardingError.noReports }

        for report in reports {
            guard report.planID == plan.planID else {
                throw ShardingError.planMismatch(expected: plan.planID, found: report.planID)
            }
            guard report.toolchain == first.toolchain else {
                throw ShardingError.toolchainMismatch
            }
        }

        // Deduplicated by `MutationID`, not by `ResultLedger`'s own
        // `PlannedMutationRef` key: each shard's `MutationPlan.workUnitID`
        // is computed from that shard's own mutation subset (see
        // `MutationPlan.workUnitID`'s doc comment), so the *same* mutation
        // appearing in two shards — the real bug this guards against — would
        // carry two different `workUnitID`s and therefore two different
        // refs, which `ResultLedger.insert` would not catch as a collision.
        // `MutationID` is the one identity that is stable across shards.
        var seen: Set<MutationID> = []
        var results: [MutationResult] = []
        for report in reports {
            for result in report.results {
                guard seen.insert(result.id).inserted else {
                    throw ShardingError.duplicateResult(result.id)
                }
                results.append(result)
            }
        }
        var ledger = ResultLedger<MutationResult>()
        for result in results {
            try ledger.insert(result)
        }

        // A failed baseline anywhere invalidates every shard's numbers, so the
        // merged report carries the failing record rather than an arbitrary
        // passing one — the reader should see what actually went wrong.
        let baselinePassed = reports.allSatisfy { $0.baseline.passed }
        let baseline = reports.first { !$0.baseline.passed }?.baseline ?? first.baseline

        let integrity = IntegrityChecker.check(
            plan: plan,
            ledger: ledger,
            baselinePassed: baselinePassed
        )

        return RunReport(
            planID: plan.planID,
            startedAt: reports.map(\.startedAt).min() ?? first.startedAt,
            finishedAt: reports.map(\.finishedAt).max() ?? first.finishedAt,
            projectRoot: first.projectRoot,
            toolchain: first.toolchain,
            baseline: baseline,
            ledger: ledger,
            integrity: integrity,
            operationalIssues: reports.flatMap(\.operationalIssues)
        )
    }
}
