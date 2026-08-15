import Foundation
import MutationModel
import SwiftFrontend

/// Everything planning can refuse to do, and why.
public enum PlannerError: Error, CustomStringConvertible {
    case unknownOperator(id: String, known: [String])
    case operatorRequiresSymbolResolution(id: String)
    case unreadableDirectory(path: String, detail: String)
    case unreadableFile(path: String, detail: String)
    case invalidBudget(maxMutants: Int)
    case diffScopeMissing(base: String)
    case integrityViolations([IntegrityViolation])
    /// `budget.selection: v2` (ADR-0007) rejected its own input — a
    /// duplicate `MutationID`, an invalid `weight` configuration, or a
    /// `maxMutants`/candidate-count magnitude the overflow-safety bound
    /// disallows. See `BudgetSelectorV2Error`'s own description for detail.
    case budgetSelectionV2Failed(BudgetSelectorV2Error)

    public var description: String {
        switch self {
        case let .unknownOperator(id, known):
            """
            No operator with ID '\(id)'. Known operators: \(known.joined(separator: ", ")).
            """
        case let .operatorRequiresSymbolResolution(id):
            """
            Operator '\(id)' needs type information the syntax-only frontend cannot supply, \
            so it cannot be enabled in this release.
            """
        case let .unreadableDirectory(path, detail):
            "Could not read directory \(path): \(detail)"
        case let .unreadableFile(path, detail):
            "Could not read \(path): \(detail)"
        case let .invalidBudget(maxMutants):
            "budget.maxMutants must be greater than zero, got \(maxMutants)."
        case let .diffScopeMissing(base):
            """
            Configuration asks to mutate only code changed since '\(base)', but no diff was \
            supplied. Refusing to plan the whole project instead — that would be a far larger \
            run than the one that was asked for.
            """
        case let .integrityViolations(violations):
            """
            The plan violates its own invariants and will not be executed:
            \(violations.map { "  - \($0.kind.rawValue): \($0.detail)" }.joined(separator: "\n"))
            """
        case let .budgetSelectionV2Failed(error):
            "budget.selection: v2 rejected its input: \(error)"
        }
    }
}

/// Builds a `MutationPlan` from a configuration and a source tree.
///
/// The planner reads files and writes nothing. It spawns no subprocesses —
/// `ToolchainFingerprint` is injected precisely so that gathering it (which
/// means running `swift --version` and `xcodebuild -version`) stays outside a
/// component whose output must be reproducible from its inputs alone.
public struct MutationPlanner: Sendable {
    private let registry: MutationRegistry

    public init(registry: MutationRegistry = MutationRegistry()) {
        self.registry = registry
    }

    /// Discovers mutations and resolves them into a validated plan.
    ///
    /// The result does not depend on file completion order, on the machine's
    /// core count, or on the clock — only on the configuration, the tree's
    /// contents, and the diff.
    ///
    /// - Parameters:
    ///   - configuration: the resolved user configuration.
    ///   - projectRoot: the directory every path in the plan is relative to.
    ///   - toolchain: gathered by the caller; the planner runs no subprocesses.
    ///   - diffScope: required when `execution.diffBase` is set, ignored otherwise.
    ///   - createdAt: recorded in the plan; excluded from `planID`.
    public func makePlan(
        configuration: Configuration,
        projectRoot: URL,
        toolchain: ToolchainFingerprint,
        diffScope: DiffScope? = nil,
        createdAt: Date = Date()
    ) async throws -> MutationPlan {
        let resolution = try registry.resolve(configuration.operators)

        if let base = configuration.execution.diffBase, diffScope == nil {
            throw PlannerError.diffScopeMissing(base: base)
        }

        let root = projectRoot.standardizedFileURL
        let files = try SourceFileWalker(root: root, settings: configuration.sources).walk()
        let discovery = try await discoverConcurrently(
            files: files,
            root: root,
            operators: resolution.enabledOperators
        )

        var surviving = discovery.points
        var skipped: [SkippedMutation] = []

        // Gates run in a fixed order and each dropped mutation leaves at exactly
        // one gate. That is what keeps `discovered == mutations + skipped`
        // exact rather than approximately right.
        var inclusionReasons: [InclusionReason] = []
        (surviving, skipped) = applyConfidenceGate(surviving, skipped, resolution: resolution)
        (surviving, skipped) = applyDiffGate(surviving, skipped, diffScope: diffScope)
        let budgetGateResult = try applyBudgetGate(
            surviving, skipped, budget: configuration.execution.budget
        )
        surviving = budgetGateResult.selected
        skipped = budgetGateResult.skipped
        inclusionReasons = budgetGateResult.inclusionReasons

        // Sorted so the plan file is byte-identical across runs; `mutations` is
        // sorted by `MutationPlan.init`, `skipped` is not.
        skipped.sort { lhs, rhs in
            lhs.id == rhs.id ? lhs.reason.rawValue < rhs.reason.rawValue : lhs.id < rhs.id
        }

        let plan = MutationPlan(
            planID: Self.planID(
                configurationHash: configuration.configurationHash,
                sourceFileHashes: discovery.fileHashes,
                mutations: surviving,
                skipped: skipped
            ),
            createdAt: createdAt,
            projectRoot: root.path,
            toolchain: toolchain,
            configurationHash: configuration.configurationHash,
            sourceFileHashes: discovery.fileHashes,
            mutations: surviving,
            skipped: skipped,
            operators: resolution.descriptors,
            budgetInclusionReasons: inclusionReasons
        )

        // Checking here costs milliseconds. Checking after execution costs the
        // hour of builds that was spent proving a score nobody can trust.
        let violations = IntegrityChecker.validatePlan(plan)
        guard violations.isEmpty else { throw PlannerError.integrityViolations(violations) }

        return plan
    }

    // MARK: - Discovery

    private struct FileDiscovery: Sendable {
        let relativePath: String
        let sourceFileHash: String
        let points: [MutationPoint]
    }

    private struct DiscoveryOutcome {
        /// Every file walked, whether or not it yielded a mutation. A dictionary
        /// has no order to get wrong, so completion order cannot leak in here.
        var fileHashes: [String: String] = [:]
        var points: [MutationPoint] = []
    }

    /// Parses files concurrently, bounded to the machine's core count.
    ///
    /// Parsing is CPU-bound and each file is independent, so the bound exists to
    /// stop thousands of pending tasks holding thousands of syntax trees alive
    /// at once — memory, not scheduling, is what caps this.
    private func discoverConcurrently(
        files: [String],
        root: URL,
        operators: [any MutationOperator]
    ) async throws -> DiscoveryOutcome {
        guard !files.isEmpty else { return DiscoveryOutcome() }

        let limit = min(files.count, max(1, ProcessInfo.processInfo.activeProcessorCount))
        var outcome = DiscoveryOutcome()

        try await withThrowingTaskGroup(of: FileDiscovery.self) { group in
            var next = 0

            while next < limit {
                let relativePath = files[next]
                group.addTask {
                    try Self.discover(operators: operators, root: root, relativePath: relativePath)
                }
                next += 1
            }

            while let result = try await group.next() {
                outcome.fileHashes[result.relativePath] = result.sourceFileHash
                outcome.points.append(contentsOf: result.points)

                if next < files.count {
                    let relativePath = files[next]
                    group.addTask {
                        try Self.discover(operators: operators, root: root, relativePath: relativePath)
                    }
                    next += 1
                }
            }
        }

        // Points arrive interleaved by whichever file finished first. Sorting by
        // ID restores the one true order before any gate looks at them, so
        // budget selection sees the same input sequence every time.
        outcome.points.sort { $0.id < $1.id }
        return outcome
    }

    private static func discover(
        operators: [any MutationOperator],
        root: URL,
        relativePath: String
    ) throws -> FileDiscovery {
        let url = root.appendingPathComponent(relativePath)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PlannerError.unreadableFile(path: relativePath, detail: error.localizedDescription)
        }

        // Built per task: one discovery instance shared across tasks would be
        // shared mutable state for no gain — construction is free.
        let discovery = MutationDiscovery(operators: operators)
        return FileDiscovery(
            relativePath: relativePath,
            sourceFileHash: ContentHash.of(data),
            points: try discovery.discover(source: data, relativePath: relativePath)
        )
    }

    // MARK: - Gates

    private func applyConfidenceGate(
        _ points: [MutationPoint],
        _ skipped: [SkippedMutation],
        resolution: MutationRegistry.Resolution
    ) -> ([MutationPoint], [SkippedMutation]) {
        guard let floor = resolution.profile.siteConfidenceFloor else { return (points, skipped) }

        var kept: [MutationPoint] = []
        var skipped = skipped
        for point in points {
            // An operator the user named in `enable` bypasses the floor:
            // enabling an operator and then discarding all of its sites would
            // make the setting a no-op that reports nothing.
            let exempt = resolution.explicitlyEnabledOperatorIDs.contains(point.operatorID)
            if !exempt, point.confidence < floor {
                skipped.append(SkippedMutation(
                    id: point.id,
                    file: point.file,
                    reason: .confidenceBelowProfile,
                    detail: """
                    \(point.displayLocation): site confidence \(point.confidence.rawValue) is below \
                    the \(floor.rawValue) required by the \(resolution.profile.rawValue) profile.
                    """,
                    operatorID: point.operatorID
                ))
            } else {
                kept.append(point)
            }
        }
        return (kept, skipped)
    }

    private func applyDiffGate(
        _ points: [MutationPoint],
        _ skipped: [SkippedMutation],
        diffScope: DiffScope?
    ) -> ([MutationPoint], [SkippedMutation]) {
        guard let diffScope else { return (points, skipped) }

        let split = diffScope.split(points)
        let skipped = skipped + split.outOfScope.map { point in
            SkippedMutation(
                id: point.id,
                file: point.file,
                reason: .outsideDiff,
                detail: "\(point.displayLocation) is outside the diff being reviewed.",
                operatorID: point.operatorID
            )
        }
        return (split.inScope, skipped)
    }

    /// The result of a budget gate: which mutations survived, the running
    /// skip list with this gate's drops appended, and (v2 only) an
    /// `InclusionReason` per selected mutant.
    ///
    /// `inclusionReasons` is only ever non-empty under `budget.selection: v2`
    /// — v1's two modes produce no `InclusionReason` records (ADR-0007 B.7
    /// is a v2 capability, not retrofitted onto v1).
    private struct BudgetGateResult {
        let selected: [MutationPoint]
        let skipped: [SkippedMutation]
        let inclusionReasons: [InclusionReason]
    }

    private func applyBudgetGate(
        _ points: [MutationPoint],
        _ skipped: [SkippedMutation],
        budget: BudgetSettings
    ) throws -> BudgetGateResult {
        // `maxDurationSeconds` is not a planning input: the planner has no
        // measured baseline and no idea what a mutant costs. The executor stops
        // on that clock and records what it did not reach.
        guard let maxMutants = budget.maxMutants else {
            return BudgetGateResult(selected: points, skipped: skipped, inclusionReasons: [])
        }
        guard maxMutants > 0 else { throw PlannerError.invalidBudget(maxMutants: maxMutants) }

        if budget.selection == .v2 {
            return try applyBudgetGateV2(points, skipped, maxMutants: maxMutants, budget: budget)
        }

        guard points.count > maxMutants else {
            return BudgetGateResult(selected: points, skipped: skipped, inclusionReasons: [])
        }

        switch budget.stratifyBy {
        case .operatorSubtype:
            let minimumPerOperator = budget.minimumPerOperator ?? 1
            let selection = BudgetSelector.selectByOperatorSubtype(
                points, limit: maxMutants, seed: budget.seed, minimumPerOperator: minimumPerOperator
            )

            let skipped = skipped + selection.dropped.map { point in
                let assigned = selection.assignedPerOperator[point.operatorID] ?? 0
                let candidates = selection.candidatesPerOperator[point.operatorID] ?? 0
                return SkippedMutation(
                    id: point.id,
                    file: point.file,
                    reason: .budgetExceeded,
                    detail: """
                    Not selected by operatorSubtype sampling (seed \
                    \(budget.seed.map(String.init) ?? "none")): \(point.operatorID) was allocated \
                    \(assigned) of its \(candidates) eligible candidate(s) under a total budget of \
                    \(maxMutants) mutants across \(selection.candidatesPerOperator.count) operators.
                    """,
                    operatorID: point.operatorID
                )
            }
            return BudgetGateResult(selected: selection.selected, skipped: skipped, inclusionReasons: [])

        case .subtype, nil:
            let selection = BudgetSelector.select(
                points, limit: maxMutants, seed: budget.seed, stratifyBy: budget.stratifyBy
            )
            let rule: String
            if budget.stratifyBy == .subtype {
                rule = budget.seed.map { "subtype-stratified sample (seed \($0))" } ?? "subtype-stratified selection"
            } else {
                rule = budget.seed.map { "seeded sample (seed \($0))" } ?? "stratified selection"
            }

            let skipped = skipped + selection.dropped.map { point in
                SkippedMutation(
                    id: point.id,
                    file: point.file,
                    reason: .budgetExceeded,
                    detail: """
                    Not selected by \(rule) for a budget of \(maxMutants) mutants \
                    (\(points.count) were eligible).
                    """,
                    operatorID: point.operatorID
                )
            }
            return BudgetGateResult(selected: selection.selected, skipped: skipped, inclusionReasons: [])
        }
    }

    /// Budget Selection v2 (ADR-0007): outer stratum = operator ID, inner
    /// stratum = the exact (original, replacement) text pair — the same two
    /// dimensions `.operatorSubtype` already uses, so a v1-vs-v2 comparison
    /// isolates the allocation algorithm as the only variable, not the
    /// stratification dimensions too. Unlike v1's modes, this never takes
    /// the "budget covers the whole pool" shortcut: `allocate` always runs,
    /// so every selected mutant gets a real `InclusionReason` (B.7 requires
    /// one for every selected mutant individually, not only when something
    /// was dropped).
    private func applyBudgetGateV2(
        _ points: [MutationPoint],
        _ skipped: [SkippedMutation],
        maxMutants: Int,
        budget: BudgetSettings
    ) throws -> BudgetGateResult {
        var byOperator: [String: [MutationPoint]] = [:]
        for point in points {
            byOperator[point.operatorID, default: []].append(point)
        }
        let strata = byOperator.keys.sorted().map { operatorID in
            BudgetStratumV2(id: operatorID, candidates: byOperator[operatorID] ?? [])
        }

        let result: [(point: MutationPoint, reason: InclusionReason)]
        do {
            result = try BudgetSelectorV2.allocate(
                strata: strata,
                limit: maxMutants,
                seed: budget.seed,
                minimumPerStratum: budget.minimumPerStratum ?? 1,
                weight: budget.weight ?? [:],
                innerDimension: Self.budgetV2SubtypeKey,
                innerMinimumPerStratum: 1
            )
        } catch let error as BudgetSelectorV2Error {
            throw PlannerError.budgetSelectionV2Failed(error)
        }

        let selectedIDs = Set(result.map { $0.point.id })
        let dropped = points.filter { !selectedIDs.contains($0.id) }
        let newSkipped = skipped + dropped.map { point in
            SkippedMutation(
                id: point.id,
                file: point.file,
                reason: .budgetExceeded,
                detail: """
                Not selected by Budget Selection v2 (seed \(budget.seed.map(String.init) ?? "none")) \
                for a budget of \(maxMutants) mutants (\(points.count) were eligible).
                """,
                operatorID: point.operatorID
            )
        }

        return BudgetGateResult(
            selected: result.map(\.point).sorted { $0.id < $1.id },
            skipped: newSkipped,
            inclusionReasons: result.map(\.reason)
        )
    }

    /// v2's inner-dimension key: the exact (original, replacement) text
    /// pair, mirroring v1's `BudgetSelector.stratumKey` minus the operator
    /// prefix — v2's outer stratum ID already carries the operator.
    private static func budgetV2SubtypeKey(_ point: MutationPoint) -> String {
        "\(point.originalText)\u{1F}\(point.replacementText)"
    }

    // MARK: - Plan identity

    /// Derives a plan ID from what the plan *is*.
    ///
    /// `createdAt` is excluded on purpose: re-planning an unchanged tree with an
    /// unchanged config produces the same ID, which is what lets a cache, a
    /// resume, or a set of shards recognise each other.
    private static func planID(
        configurationHash: String,
        sourceFileHashes: [String: String],
        mutations: [MutationPoint],
        skipped: [SkippedMutation]
    ) -> String {
        let separator = "\u{1F}"
        var components = ["v1", configurationHash]
        components += sourceFileHashes.keys.sorted().map { "\($0)=\(sourceFileHashes[$0]!)" }
        components += mutations.map(\.id.rawValue).sorted()
        components += skipped.map { "\($0.id.rawValue)=\($0.reason.rawValue)" }.sorted()
        return "plan_" + ContentHash.shortDigest(of: components.joined(separator: separator))
    }
}

// MARK: - Budget selection

/// Chooses which mutations survive a `maxMutants` budget.
///
/// Both strategies are deterministic; the seed only decides *which* kind of
/// determinism. Neither ever consults the system RNG.
enum BudgetSelector {
    static func select(
        _ points: [MutationPoint],
        limit: Int,
        seed: UInt64?,
        stratifyBy: BudgetStratification? = nil
    ) -> (selected: [MutationPoint], dropped: [MutationPoint]) {
        let selected: [MutationPoint] = switch stratifyBy {
        case .subtype:
            stratifiedBySubtype(points, limit: limit, seed: seed)
        case nil:
            seed.map { sampled(points, limit: limit, seed: $0) } ?? stratified(points, limit: limit)
        case .operatorSubtype:
            preconditionFailure(
                "select(stratifyBy:) does not implement .operatorSubtype — callers must route " +
                    "that case to selectByOperatorSubtype instead (see MutationPlanner.applyBudgetGate)."
            )
        }

        let selectedIDs = Set(selected.map(\.id))
        let dropped = points.filter { !selectedIDs.contains($0.id) }
        return (selected.sorted { $0.id < $1.id }, dropped.sorted { $0.id < $1.id })
    }

    /// Result of `selectByOperatorSubtype`, carrying enough per-operator
    /// bookkeeping for the caller to explain every drop (see
    /// `MutationPlanner.applyBudgetGate`'s `.operatorSubtype` branch) and to
    /// report eligible/selected counts per operator.
    struct BalancedSelection {
        let selected: [MutationPoint]
        let dropped: [MutationPoint]
        /// Eligible candidate count per operator, i.e. `points.count` grouped
        /// by `operatorID` — everything this gate saw, before allocation.
        let candidatesPerOperator: [String: Int]
        /// How many of each operator's candidates were actually selected.
        let assignedPerOperator: [String: Int]
    }

    /// Reserves `minimumPerOperator` mutants for every operator with at least
    /// one eligible candidate before spending anything on proportional
    /// representation, then fills the rest of `limit` proportionally to each
    /// operator's remaining candidate count, and finally stratifies by
    /// subtype *within* each operator's own slots. See
    /// `BudgetStratification.operatorSubtype`'s doc comment for why this
    /// exists — `.subtype` alone stratifies flat across every operator at
    /// once, in alphabetical stratum order, which starves any operator whose
    /// strata happen to sort late once the stratum count exceeds the budget.
    ///
    /// Three phases, all deterministic from `(points, limit, seed,
    /// minimumPerOperator)`, and none of them alphabetical when `seed` is
    /// set — every group-selection decision below draws from `seededOrder`,
    /// so which operators/subtypes survive a tight budget is a function of
    /// the seed, not of string sort order:
    ///
    /// 1. **Minimum phase.** Round-robin, one slot per operator per round, in
    ///    `seededOrder(operatorIDs, seed)` priority order — until every
    ///    operator has `min(minimumPerOperator, its candidate count)` slots
    ///    or `limit` runs out. Round-robin, not "each operator's full minimum
    ///    before moving to the next": a budget too small to cover every
    ///    operator's minimum still gives each eligible operator one slot
    ///    before any operator gets a second, rather than handing the entire
    ///    remainder to whichever operator sorts first.
    /// 2. **Remainder phase.** Whatever budget is left after every operator
    ///    has its minimum (or ran out of candidates) is split across
    ///    operators proportionally to their remaining (unassigned) candidate
    ///    count, using the largest-remainder method: each operator's exact
    ///    fractional share is floored, and leftover slots from rounding go to
    ///    the operators with the largest fractional remainders, ties broken
    ///    by `operatorID` — a named, stable rule, but not seed-dependent;
    ///    unlike phases 1 and 3, this phase is never the one deciding whether
    ///    an operator is represented *at all*, only how many of its already-
    ///    guaranteed-eligible extra slots it gets.
    /// 3. **Within-operator phase.** Each operator's assigned slot count is
    ///    filled via `stratifiedBySubtype(seedStratumOrder: true)`, scoped to
    ///    that operator's own candidates — round-robins across that
    ///    operator's distinct (original, replacement) pairs in
    ///    `seededOrder`, not alphabetical, priority when the pair count
    ///    exceeds the operator's slot count.
    static func selectByOperatorSubtype(
        _ points: [MutationPoint],
        limit: Int,
        seed: UInt64?,
        minimumPerOperator: Int
    ) -> BalancedSelection {
        var byOperator: [String: [MutationPoint]] = [:]
        for point in points {
            byOperator[point.operatorID, default: []].append(point)
        }
        let candidatesPerOperator = byOperator.mapValues(\.count)
        // The base set is always alphabetical (deterministic regardless of
        // discovery/iteration order); `seededOrder` re-derives priority from
        // it, so passing keys in a different order here would not change
        // the outcome — see the "operator order reversed" regression test.
        let operatorIDs = byOperator.keys.sorted()
        let priorityOrder = seededOrder(operatorIDs, seed: seed)

        var assigned = reserveMinimums(
            priorityOrder: priorityOrder, candidatesPerOperator: candidatesPerOperator,
            limit: limit, minimumPerOperator: minimumPerOperator
        )
        let spent = assigned.values.reduce(0, +)
        distributeRemainder(
            operatorIDs: operatorIDs, candidatesPerOperator: candidatesPerOperator,
            remainingBudget: limit - spent, into: &assigned
        )

        var selected: [MutationPoint] = []
        for operatorID in operatorIDs {
            let take = assigned[operatorID] ?? 0
            guard take > 0 else { continue }
            let candidates = byOperator[operatorID] ?? []
            selected.append(contentsOf: stratifiedBySubtype(
                candidates, limit: take, seed: seed, seedStratumOrder: true
            ))
        }

        let selectedIDs = Set(selected.map(\.id))
        let dropped = points.filter { !selectedIDs.contains($0.id) }

        return BalancedSelection(
            selected: selected.sorted { $0.id < $1.id },
            dropped: dropped.sorted { $0.id < $1.id },
            candidatesPerOperator: candidatesPerOperator,
            assignedPerOperator: assigned
        )
    }

    /// A stable order over `keys` — seed-dependent when `seed` is set (each
    /// key draws its own `SplitMix64` value from `seed` mixed into its
    /// identity; lowest value wins, ties broken alphabetically) and plain
    /// alphabetical when it is not. Used wherever `.operatorSubtype`
    /// sampling has to decide which of several groups (operators, or
    /// subtypes within one operator) get truncated when there are more
    /// groups than budget — the decision `.subtype`'s fixed alphabetical
    /// order never makes seed-dependent (see `BudgetStratification.subtype`
    /// and `.operatorSubtype`'s doc comments for why that gap is real).
    private static func seededOrder(_ keys: [String], seed: UInt64?) -> [String] {
        guard let seed else { return keys.sorted() }
        let keyed = keys.map { key -> (key: UInt64, value: String) in
            var generator = SplitMix64(seed: seed ^ StableHash.fnv1a64(key))
            return (generator.next(), key)
        }
        return keyed
            .sorted { lhs, rhs in lhs.key == rhs.key ? lhs.value < rhs.value : lhs.key < rhs.key }
            .map(\.value)
    }

    /// Phase 1 of `selectByOperatorSubtype`: reserves `minimumPerOperator`
    /// slots per operator, visited in `priorityOrder` (see `seededOrder`).
    private static func reserveMinimums(
        priorityOrder: [String],
        candidatesPerOperator: [String: Int],
        limit: Int,
        minimumPerOperator: Int
    ) -> [String: Int] {
        var assigned: [String: Int] = [:]
        var remainingBudget = limit

        // Round-robin, one slot per operator per round, not "each operator's
        // full minimum before moving to the next" — otherwise a budget too
        // small to cover every minimum hands the entire remainder to
        // whichever operator sorts first, starving every operator after it
        // even though each one has an eligible candidate.
        for _ in 0 ..< minimumPerOperator where remainingBudget > 0 {
            for operatorID in priorityOrder where remainingBudget > 0 {
                let already = assigned[operatorID] ?? 0
                guard already < minimumPerOperator, already < (candidatesPerOperator[operatorID] ?? 0) else {
                    continue
                }
                assigned[operatorID] = already + 1
                remainingBudget -= 1
            }
        }
        return assigned
    }

    /// Phase 2 of `selectByOperatorSubtype`: splits whatever budget phase 1
    /// left over across operators' remaining (unassigned) candidate capacity,
    /// using the largest-remainder method — see `selectByOperatorSubtype`'s
    /// doc comment for why.
    private static func distributeRemainder(
        operatorIDs: [String],
        candidatesPerOperator: [String: Int],
        remainingBudget: Int,
        into assigned: inout [String: Int]
    ) {
        guard remainingBudget > 0 else { return }

        let capacity: [String: Int] = operatorIDs.reduce(into: [:]) { result, operatorID in
            result[operatorID] = (candidatesPerOperator[operatorID] ?? 0) - (assigned[operatorID] ?? 0)
        }
        let totalCapacity = capacity.values.reduce(0, +)
        guard totalCapacity > 0 else { return }

        let toDistribute = min(remainingBudget, totalCapacity)
        var floorShares: [String: Int] = [:]
        var remainders: [(operatorID: String, remainder: Double)] = []

        for operatorID in operatorIDs {
            let operatorCapacity = capacity[operatorID] ?? 0
            guard operatorCapacity > 0 else { continue }
            let exact = Double(toDistribute) * Double(operatorCapacity) / Double(totalCapacity)
            let flooredShare = min(Int(exact), operatorCapacity)
            floorShares[operatorID] = flooredShare
            remainders.append((operatorID, exact - Double(flooredShare)))
        }

        var leftover = toDistribute - floorShares.values.reduce(0, +)
        let priority = remainders.sorted { lhs, rhs in
            lhs.remainder == rhs.remainder ? lhs.operatorID < rhs.operatorID : lhs.remainder > rhs.remainder
        }
        for entry in priority where leftover > 0 {
            let operatorCapacity = capacity[entry.operatorID] ?? 0
            guard (floorShares[entry.operatorID] ?? 0) < operatorCapacity else { continue }
            floorShares[entry.operatorID, default: 0] += 1
            leftover -= 1
        }

        for (operatorID, share) in floorShares where share > 0 {
            assigned[operatorID, default: 0] += share
        }
    }

    /// Seeded uniform sample.
    ///
    /// Each mutation draws a key from a PRNG seeded with `seed` mixed into its
    /// own ID, and the lowest `limit` keys win. Keying off identity rather than
    /// position means the sample does not depend on the order the points arrived
    /// in — and a mutation's fate depends only on the seed and on itself, so
    /// adding a file elsewhere does not reshuffle the whole selection.
    private static func sampled(_ points: [MutationPoint], limit: Int, seed: UInt64) -> [MutationPoint] {
        let keyed = points.map { point -> (key: UInt64, point: MutationPoint) in
            var generator = SplitMix64(seed: seed ^ StableHash.fnv1a64(point.id.rawValue))
            return (generator.next(), point)
        }
        let ordered = keyed.sorted { lhs, rhs in
            lhs.key == rhs.key ? lhs.point.id < rhs.point.id : lhs.key < rhs.key
        }
        return ordered.prefix(limit).map(\.point)
    }

    /// Unseeded stratified selection: round-robin over files, then over
    /// operators within each file.
    ///
    /// The obvious alternative — take the first `limit` by ID — is what makes a
    /// budgeted run useless: IDs are content hashes, so "first N" is an
    /// arbitrary subset that happens to be stable, and it concentrates wherever
    /// the hashes happen to land. Round-robin guarantees every file contributes
    /// its first mutant before any file contributes its second, and the same
    /// within a file across operators. A 50-mutant budget on a 200-file project
    /// therefore reports on 50 different files rather than on two.
    private static func stratified(_ points: [MutationPoint], limit: Int) -> [MutationPoint] {
        var byFile: [String: [String: [MutationPoint]]] = [:]
        for point in points {
            byFile[point.file, default: [:]][point.operatorID, default: []].append(point)
        }

        let queues: [[MutationPoint]] = byFile.keys.sorted().map { file in
            let byOperator = byFile[file]!
            let groups = byOperator.keys.sorted().map { byOperator[$0]!.sorted { $0.id < $1.id } }
            return interleave(groups)
        }

        var selected: [MutationPoint] = []
        var cursors = [Int](repeating: 0, count: queues.count)
        var progressed = true

        while selected.count < limit, progressed {
            progressed = false
            for index in queues.indices where selected.count < limit {
                guard cursors[index] < queues[index].count else { continue }
                selected.append(queues[index][cursors[index]])
                cursors[index] += 1
                progressed = true
            }
        }

        return selected
    }

    /// Stratifies by operator *and* by the exact original → replacement pair,
    /// round-robin across strata the same way `stratified` round-robins
    /// across files. Every (operator, replacement) pair present in the
    /// population contributes before any pair contributes twice; a pair with
    /// only a handful of occurrences still gets its fair turn rather than
    /// being drowned out by whichever pair happens to be the most common one
    /// in the codebase. Within a stratum, order is by ID when `seed` is
    /// `nil` and by the same seeded draw `sampled` uses otherwise — so two
    /// seeds select the same strata in the same order, differing only in
    /// which members of each stratum are chosen first — **unless
    /// `seedStratumOrder` is set**, in which case which strata are even
    /// included when the budget can't cover all of them is *also*
    /// seed-dependent; see `seedStratumOrder`'s parameter doc.
    private static func stratifiedBySubtype(
        _ points: [MutationPoint],
        limit: Int,
        seed: UInt64?,
        seedStratumOrder: Bool = false
    ) -> [MutationPoint] {
        var byStratum: [String: [MutationPoint]] = [:]
        for point in points {
            byStratum[stratumKey(point), default: []].append(point)
        }

        // `.subtype` (seedStratumOrder: false, the default) always visits
        // strata alphabetically — changing that would be a silent behavior
        // change for every existing config that already sets `stratifyBy:
        // subtype`. `.operatorSubtype` opts into `seededOrder` instead, so a
        // subtype count that exceeds an operator's slot budget truncates by
        // seed rather than by string sort order.
        let strataOrder = seedStratumOrder ? seededOrder(Array(byStratum.keys), seed: seed) : byStratum.keys.sorted()

        let groups: [[MutationPoint]] = strataOrder.map { key in
            let members = byStratum[key]!
            guard let seed else {
                return members.sorted { $0.id < $1.id }
            }
            let keyed = members.map { point -> (key: UInt64, point: MutationPoint) in
                var generator = SplitMix64(seed: seed ^ StableHash.fnv1a64(point.id.rawValue))
                return (generator.next(), point)
            }
            return keyed
                .sorted { lhs, rhs in lhs.key == rhs.key ? lhs.point.id < rhs.point.id : lhs.key < rhs.key }
                .map(\.point)
        }

        return Array(interleave(groups).prefix(limit))
    }

    /// The stratum a mutation belongs to for `stratifiedBySubtype`: its
    /// operator and the exact original → replacement pair, not just the
    /// operator.
    private static func stratumKey(_ point: MutationPoint) -> String {
        "\(point.operatorID)\u{1F}\(point.originalText)\u{1F}\(point.replacementText)"
    }

    /// Takes one element from each group in turn until all are exhausted.
    private static func interleave(_ groups: [[MutationPoint]]) -> [MutationPoint] {
        var result: [MutationPoint] = []
        var index = 0
        var remaining = true

        while remaining {
            remaining = false
            for group in groups where index < group.count {
                result.append(group[index])
                remaining = true
            }
            index += 1
        }

        return result
    }
}
