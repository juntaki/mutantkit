import Foundation
import MutationModel

// MARK: - Errors

/// Everything `BudgetSelectorV2` can refuse to do, and why.
///
/// Unlike v1's `BudgetSelector` (which is a pure, non-throwing filter over
/// well-formed input — see `MutationPlanner.swift`), v2 has two real
/// precondition violations it must actively reject rather than silently
/// mishandle:
///
/// - A duplicate `MutationID` in the candidate pool. ADR-0007 A.14 found
///   v1 silently drops one of two colliding points, uncounted, with no skip
///   record — breaking the codebase's own "skips are part of the plan"
///   promise. Invariant 4 (B.1) makes this a normative requirement on v2,
///   not optional hardening: reject, don't drop.
/// - An invalid `weight` configuration (B.3): partially-configured weights,
///   or a configured weight outside `1...1_000_000` (including `0`, which
///   is no longer a valid "opt a stratum out" signal — see B.3's revised,
///   opt-out-free semantics). This is meant to be a config-load-time error
///   the same way `ConfigurationValidation.swift` already treats other
///   numeric range checks — this module has no `Configuration` integration
///   point yet (that wiring is explicitly out of scope for this task), so
///   `allocateCounts`/`allocate` enforce it themselves by throwing, using
///   the same `ConfigurationIssue` accumulator shape a future config-load
///   validator can reuse verbatim (see `validateWeightConfiguration`).
public enum BudgetSelectorV2Error: Error, CustomStringConvertible, Sendable, Equatable {
    case duplicateMutationID(MutationID)
    case invalidWeightConfiguration([ConfigurationIssue])
    case budgetMagnitudeExceeded(limit: Int, totalCandidates: Int, maximum: Int)

    public var description: String {
        switch self {
        case let .duplicateMutationID(id):
            """
            BudgetSelectorV2 received two candidates sharing MutationID '\(id.rawValue)'. \
            The selector's input contract requires unique MutationIDs (ADR-0007 invariant 4); \
            an earlier version of this bug silently dropped one twin instead of rejecting the \
            input outright (see A.14) — v2 refuses to repeat that.
            """
        case let .invalidWeightConfiguration(issues):
            """
            Invalid weight configuration: \(issues.map(\.description).joined(separator: "; ")).
            """
        case let .budgetMagnitudeExceeded(limit, totalCandidates, maximum):
            """
            budget.maxMutants (\(limit)) or total candidate count (\(totalCandidates)) exceeds \
            \(maximum) (2^31), the bound ADR-0007 B.2's overflow-safety proof for Phase 2's \
            Int64 arithmetic is derived against. This is not a realistic corpus size; refusing \
            rather than risking an integer-overflow trap outside the proven-safe domain.
            """
        }
    }
}

// MARK: - Inputs

/// One stratum of the outer (or, recursively, inner) stratification
/// dimension: an opaque identity plus the candidates it owns.
///
/// `BudgetSelectorV2` does not know or care what `id` *means* — "file
/// path", "operator ID", "declaration path" are all just strings to it.
/// The caller decides what a stratum is by how it partitions `candidates`
/// before calling `allocate`/`allocateCounts`; this keeps the algorithm
/// itself dimension-agnostic, matching B.2's "one function, different
/// dimension configuration" framing for the plain/default case (B.2,
/// "Selection semantics for plain").
public struct BudgetStratumV2: Sendable {
    public let id: String
    public let candidates: [MutationPoint]

    public init(id: String, candidates: [MutationPoint]) {
        self.id = id
        self.candidates = candidates
    }
}

/// How many slots a stratum was granted, split by which of `allocateCounts`'s
/// two phases granted them (ADR-0007 B.2 step 2). Never *which* mutants —
/// that is `allocate`'s job.
public struct PhaseSplit: Sendable, Equatable {
    public let phase1: Int
    public let phase2: Int

    public init(phase1: Int = 0, phase2: Int = 0) {
        self.phase1 = phase1
        self.phase2 = phase2
    }

    public var total: Int { phase1 + phase2 }
}

// MARK: - BudgetSelectorV2

//
// `InclusionReason`/`InclusionReason.ReasonCode` (B.7's audit-trail schema)
// live in `MutationModel`, not here — `MutationPlan` persists one per
// v2-selected mutant and cannot depend on `MutationPlanner`. See
// `MutationModel/InclusionReason.swift`.

/// Budget Selection v2 (ADR-0007) — an opt-in, additive alternative to
/// `BudgetSelector` (v1). Generalizes v1's three modes into one two-level
/// stratified allocator: an outer stratification dimension, and, only if
/// configured, exactly one inner dimension scoped to each outer stratum's
/// own candidates (B.1 invariant 11 bounds recursion at exactly two
/// levels).
///
/// This type is standalone and not yet wired into `MutationPlanner
/// .makePlan`, the CLI, or configuration decoding — that integration is a
/// separate, later task (see the ADR's Choice 1: v2 ships opt-in only).
/// Every function here is a pure, deterministic computation over its
/// arguments: no system RNG, no wall-clock, no historical/outcome-derived
/// data of any kind (B.5/invariant 12 close that off entirely for this
/// cut), matching v1's own determinism contract (A.8) and extending it with
/// two new precondition checks v1 never had (see `BudgetSelectorV2Error`).
public enum BudgetSelectorV2 {
    /// The valid range for a configured `weight` value (B.3): `0` is not a
    /// valid value at all — the prior ADR revision's "explicit zero opts a
    /// stratum out" design was removed because it made the exact-fill
    /// target ambiguous (see B.2 step 2's "REVISED" note).
    public static let weightValidRange = 1 ... 1_000_000

    /// The upper bound (`2^31`) B.2's overflow-safety proof assumes for
    /// both `limit` and the total candidate count — the domain
    /// `numerator = R * effectiveWeight[s] <= 2^31 * 10^6 ≈ 2.1×10^15`
    /// (safely within `Int64`) is actually derived against. Enforced by
    /// `allocateCounts` itself (closing a Codex code-review Medium
    /// finding: an unenforced caller precondition on unchecked `Int64`
    /// multiplication), not merely documented.
    public static let maximumBudgetMagnitude = 1 << 31

    // MARK: allocateCounts

    /// Decides *how many* slots each stratum gets, split by which phase
    /// granted them — never *which* mutants (that is `allocate`'s job).
    /// Implements ADR-0007 B.2 step 2 exactly: a one-slot-per-stratum-per-
    /// round minimum reservation (Phase 1), followed by an exact-integer
    /// capacitated largest-remainder distribution of whatever budget
    /// remains (Phase 2). No `Float`/`Double` anywhere in Phase 2, per the
    /// ADR's explicit requirement — every Phase 2 quantity that could
    /// exceed 32 bits (`numerator`, `W`, `floorShare`, the remainder) is
    /// carried in `Int64`, even though `Int` is already 64-bit on this
    /// project's target platforms (`.macOS(.v14)`, see `Package.swift`;
    /// `SplitMix64` already assumes 64-bit arithmetic the same way) — B.2's
    /// overflow-safety note asks for this explicitly, not merely for
    /// whatever `Int` happens to be.
    ///
    /// - Parameters:
    ///   - strata: the strata being allocated across. `candidateCount` is
    ///     derived from `stratum.candidates.count` for each — kept bundled
    ///     with the actual points here (rather than a separate parameter,
    ///     as B.2's pseudocode has it) because `allocate` needs the real
    ///     points too; `allocateCounts` alone only ever reads `.count`.
    ///   - minimumPerStratum: Phase 1's per-stratum minimum. `0` (or
    ///     negative) means Phase 1 grants nothing, degenerately.
    ///   - weight: optional per-stratum Phase 2 weight (B.3). Empty means
    ///     equal-share (`effectiveWeight = 1` for every stratum). Any
    ///     non-empty configuration must cover every stratum in `strata`
    ///     with a value in `weightValidRange`, or this throws
    ///     `.invalidWeightConfiguration` — checked once, after Phase 1,
    ///     before Phase 2 begins, matching B.2's pseudocode ordering (the
    ///     `limit <= 0`/empty-`strata` degenerate case below returns before
    ///     `weight` is even consulted, so a malformed `weight` alongside a
    ///     non-positive `limit` does not throw — there is genuinely no
    ///     computation to validate it against).
    /// - Throws: `BudgetSelectorV2Error.invalidWeightConfiguration` if
    ///   `weight` is non-empty but does not cover every stratum, or any
    ///   configured value falls outside `weightValidRange`; or
    ///   `BudgetSelectorV2Error.budgetMagnitudeExceeded` if `limit` or the
    ///   total candidate count exceeds `maximumBudgetMagnitude`.
    public static func allocateCounts(
        strata: [BudgetStratumV2],
        limit: Int,
        seed: UInt64?,
        minimumPerStratum: Int,
        weight: [String: Int] = [:]
    ) throws -> [String: PhaseSplit] {
        // Degenerate cases, defined explicitly (B.2 step 2): no computation
        // at all, not even weight validation — there is nothing to compute
        // against.
        guard limit > 0, !strata.isEmpty else {
            return Dictionary(uniqueKeysWithValues: strata.map { ($0.id, PhaseSplit()) })
        }

        // B.2's overflow-safety note bounds `limit`/`remaining` and
        // `sum(candidateCount.values())` to `<= 2^31` — the numbers the
        // Int64 overflow proof for `numerator = R * effectiveWeight` (up to
        // `2^31 * 10^6`) is actually derived against. Enforced here, not
        // merely assumed by a caller, closing a real gap a Codex code
        // review found: an unchecked `Int(remaining) * Int64(weight)` can
        // trap on a value like `Int.max` before this guard existed.
        // Accumulated with an early-exit cap, not a plain `reduce`, so the
        // sum itself cannot overflow `Int` before the bound below is even
        // checked (Codex re-review Low finding).
        var totalCandidates = 0
        for stratum in strata {
            totalCandidates += stratum.candidates.count
            if totalCandidates > maximumBudgetMagnitude { break }
        }
        guard limit <= maximumBudgetMagnitude, totalCandidates <= maximumBudgetMagnitude else {
            throw BudgetSelectorV2Error.budgetMagnitudeExceeded(
                limit: limit, totalCandidates: totalCandidates, maximum: maximumBudgetMagnitude
            )
        }

        var split: [String: PhaseSplit] = Dictionary(uniqueKeysWithValues: strata.map { ($0.id, PhaseSplit()) })
        let candidateCount: [String: Int] = Dictionary(uniqueKeysWithValues: strata.map { ($0.id, $0.candidates.count) })
        var remaining = limit

        // ---- Phase 1: one-slot-per-stratum-per-round minimum reservation ----
        let order = seededOrder(strata.map(\.id), seed: seed)
        phase1: while remaining > 0 {
            var grantedThisRound = false
            for stratumID in order {
                if remaining == 0 { break phase1 }
                guard let current = split[stratumID] else { continue }
                if current.phase1 >= minimumPerStratum { continue }
                if current.phase1 >= (candidateCount[stratumID] ?? 0) { continue }
                split[stratumID] = PhaseSplit(phase1: current.phase1 + 1, phase2: current.phase2)
                remaining -= 1
                grantedThisRound = true
            }
            if !grantedThisRound { break }
        }

        // `weight` only matters from here on — validated once, now, per the
        // doc comment above.
        try requireValidWeight(weight, strataIDs: strata.map(\.id))

        // ---- Phase 2: iterative capacitated largest-remainder, exact integers only ----
        let useEqualWeight = weight.isEmpty
        func residualCapacity(_ id: String) -> Int {
            let current = split[id] ?? PhaseSplit()
            return (candidateCount[id] ?? 0) - current.phase1 - current.phase2
        }

        var eligible = Set(strata.map(\.id).filter { residualCapacity($0) > 0 })
        var remainderVal: [String: Int64] = [:]

        while remaining > 0, !eligible.isEmpty {
            let effectiveWeight: [String: Int64] = Dictionary(uniqueKeysWithValues: eligible.map { id in
                (id, useEqualWeight ? Int64(1) : Int64(weight[id] ?? 1))
            })
            // W > 0 always: `eligible` is non-empty (loop guard) and every
            // member's effectiveWeight is >= 1 (equal-share fallback, or a
            // validated positive configured value) — structurally
            // unreachable to divide by zero, not a runtime check (B.2).
            let totalWeight: Int64 = effectiveWeight.values.reduce(0, +)
            let remainingAsInt64 = Int64(remaining)

            var grantThisRound: [String: Int] = [:]
            for id in eligible {
                let numerator = remainingAsInt64 * (effectiveWeight[id] ?? 1) // Int64 — see overflow-safety note
                let floorShare = numerator / totalWeight // exact integer division
                remainderVal[id] = numerator % totalWeight // exact integer remainder
                grantThisRound[id] = min(Int(floorShare), residualCapacity(id))
            }

            for (id, grant) in grantThisRound {
                let current = split[id] ?? PhaseSplit()
                split[id] = PhaseSplit(phase1: current.phase1, phase2: current.phase2 + grant)
            }
            remaining -= grantThisRound.values.reduce(0, +)

            let newlySaturated = eligible.filter { residualCapacity($0) == 0 }
            eligible.subtract(newlySaturated)

            // REVISED (ADR-0007 B.2, closing Codex re-review High #1): break
            // when no stratum became newly saturated this round — NOT when
            // no grant was "clipped" (`grant < floorShare`). A floor grant
            // that exactly exhausts a stratum's remaining capacity still
            // saturates it even though it was not "clipped" by that
            // narrower definition; treating it as if the round changed
            // nothing would hand the leftover pass an `E` smaller than the
            // one its Hamilton bound was actually proved against. See the
            // ADR's proof for why `newlySaturated.isEmpty` is exactly the
            // right condition.
            if newlySaturated.isEmpty { break }
            // Whenever `newlySaturated` is non-empty, `eligible` strictly
            // shrinks — bounded by `strata.count`, so this loop always
            // terminates.
        }

        // ---- Leftover single-slot distribution: exact integer comparison
        // only, descending remainder, ties broken by ascending stratum ID.
        // Only reached when the round that produced `remainderVal` left
        // `eligible` unchanged (the break above), so the Hamilton bound the
        // ADR proves applies validly to this exact `eligible`. ----
        if remaining > 0, !eligible.isEmpty {
            let order2 = eligible.sorted { lhs, rhs in
                let lhsRemainder = remainderVal[lhs] ?? 0
                let rhsRemainder = remainderVal[rhs] ?? 0
                return lhsRemainder == rhsRemainder ? lhs < rhs : lhsRemainder > rhsRemainder
            }
            var index = 0
            while remaining > 0, index < order2.count {
                let id = order2[index]
                if residualCapacity(id) > 0 {
                    let current = split[id] ?? PhaseSplit()
                    split[id] = PhaseSplit(phase1: current.phase1, phase2: current.phase2 + 1)
                    remaining -= 1
                }
                index += 1
            }
        }

        // Postcondition (proved in the ADR): sum(total(split[s])) ==
        // min(limit, sum(candidateCount.values())).
        return split
    }

    // MARK: allocate

    /// The outer driver: turns `PhaseSplit` counts into actual selected
    /// `(MutationPoint, InclusionReason)` pairs. The one and only place
    /// recursion happens — exactly one inner dimension, scoped to each
    /// outer stratum's own candidates, never a third level (B.1 invariant
    /// 11; `innerDimension` is never itself passed down further).
    ///
    /// - Parameters:
    ///   - strata: the outer stratification.
    ///   - innerDimension: when non-nil, re-partitions each outer stratum's
    ///     own already-granted slots (`n`, its own already-bounded total —
    ///     never a fresh independent budget) by mapping each candidate
    ///     `MutationPoint` to an inner stratum ID. `nil` is the "plain"
    ///     degenerate case (B.2, "Selection semantics for plain"): a
    ///     single-level allocation with `stratumPath` of length 1.
    /// - Throws: `BudgetSelectorV2Error.duplicateMutationID` if any two
    ///   candidates across `strata` share a `MutationID` (invariant 4 — an
    ///   explicit precondition violation, checked unconditionally,
    ///   regardless of `limit`: this is an input-shape check, not part of
    ///   the "no computation for a non-positive limit" degenerate case).
    ///   `BudgetSelectorV2Error.invalidWeightConfiguration` propagates from
    ///   `allocateCounts` (outer or, if reached, inner).
    public static func allocate(
        strata: [BudgetStratumV2],
        limit: Int,
        seed: UInt64?,
        minimumPerStratum: Int,
        weight: [String: Int] = [:],
        innerDimension: ((MutationPoint) -> String)? = nil,
        innerMinimumPerStratum: Int = 1,
        innerWeight: [String: Int] = [:]
    ) throws -> [(point: MutationPoint, reason: InclusionReason)] {
        try requireUniqueMutationIDs(strata)

        let counts = try allocateCounts(
            strata: strata, limit: limit, seed: seed, minimumPerStratum: minimumPerStratum, weight: weight
        )

        var selected: [(point: MutationPoint, reason: InclusionReason)] = []
        for stratum in strata.sorted(by: { $0.id < $1.id }) {
            guard let split = counts[stratum.id] else { continue }
            let n = split.total
            // Normative: a zero-count stratum makes NO inner call at all —
            // not just "contributes zero mutants" (B.2 step 3).
            guard n > 0 else { continue }

            if let innerDimension {
                var byInner: [String: [MutationPoint]] = [:]
                for point in stratum.candidates {
                    byInner[innerDimension(point), default: []].append(point)
                }
                let innerStrata = byInner.keys.sorted().map { BudgetStratumV2(id: $0, candidates: byInner[$0] ?? []) }

                // The one and only permitted recursive call. `limit` is `n`
                // — the outer call's own already-bounded output for this
                // stratum. It never itself receives an `innerDimension`
                // argument, so a third level can never occur.
                let innerCounts = try allocateCounts(
                    strata: innerStrata, limit: n, seed: seed,
                    minimumPerStratum: innerMinimumPerStratum, weight: innerWeight
                )
                for innerStratum in innerStrata.sorted(by: { $0.id < $1.id }) {
                    guard let innerSplit = innerCounts[innerStratum.id] else { continue }
                    let candidates = fill(innerStratum, count: innerSplit.total, seed: seed)
                    for (ordinal, point) in candidates.enumerated() {
                        // reasonCode is drawn from the TERMINAL (inner) call's
                        // own PhaseSplit — never the outer stratum's (B.7).
                        let reasonCode: InclusionReason.ReasonCode =
                            ordinal < innerSplit.phase1 ? .minimumReservation : .proportionalRemainder
                        selected.append((point, InclusionReason(
                            mutationID: point.id,
                            reasonCode: reasonCode,
                            stratumPath: [stratum.id, innerStratum.id],
                            selectionOrdinal: ordinal
                        )))
                    }
                }
            } else {
                let candidates = fill(stratum, count: n, seed: seed)
                for (ordinal, point) in candidates.enumerated() {
                    let reasonCode: InclusionReason.ReasonCode =
                        ordinal < split.phase1 ? .minimumReservation : .proportionalRemainder
                    selected.append((point, InclusionReason(
                        mutationID: point.id,
                        reasonCode: reasonCode,
                        stratumPath: [stratum.id],
                        selectionOrdinal: ordinal
                    )))
                }
            }
        }
        return selected
    }

    // MARK: - Deterministic ordering (B.2 step 4, B.4)

    /// A stable order over stratum identifiers: seed-dependent when `seed`
    /// is set (each stratum ID draws its own `SplitMix64` value from `seed`
    /// mixed into its identity via `StableHash.fnv1a64`; lowest value wins,
    /// ties by ID) and plain alphabetical otherwise — the exact construction
    /// B.2 step 4 specifies, applied one level up from v1's own per-mutant
    /// tie-break (B.4). `SplitMix64`/`StableHash` themselves (defined
    /// `public` in `Determinism.swift`) are reused directly, unchanged, per
    /// the ADR's explicit requirement not to reimplement the PRNG; the
    /// surrounding round-robin/ordering logic is v2-specific and cannot
    /// reuse v1's own `private` `seededOrder` in `MutationPlanner.swift`
    /// (Swift's `private` is file-scoped, so this file — a different file
    /// in the same module — cannot see it even though both are `internal`
    /// to the same module in spirit).
    private static func seededOrder(_ ids: [String], seed: UInt64?) -> [String] {
        let base = ids.sorted()
        guard let seed else { return base }
        let keyed = base.map { id -> (key: UInt64, id: String) in
            var generator = SplitMix64(seed: seed ^ StableHash.fnv1a64(id))
            return (generator.next(), id)
        }
        return keyed
            .sorted { lhs, rhs in lhs.key == rhs.key ? lhs.id < rhs.id : lhs.key < rhs.key }
            .map(\.id)
    }

    /// B.2 step 5, restated here for completeness: `stratum.candidates`
    /// sorted by ID, `prefix(count)`, when `seed` is nil; otherwise sorted
    /// by `(SplitMix64(seed XOR FNV1a64(id)).key, id)`. Its output order is
    /// exactly what `selectionOrdinal` (in `allocate`) indexes into.
    private static func fill(_ stratum: BudgetStratumV2, count: Int, seed: UInt64?) -> [MutationPoint] {
        guard count > 0 else { return [] }
        let ordered: [MutationPoint]
        if let seed {
            let keyed = stratum.candidates.map { point -> (key: UInt64, point: MutationPoint) in
                var generator = SplitMix64(seed: seed ^ StableHash.fnv1a64(point.id.rawValue))
                return (generator.next(), point)
            }
            ordered = keyed
                .sorted { lhs, rhs in lhs.key == rhs.key ? lhs.point.id < rhs.point.id : lhs.key < rhs.key }
                .map(\.point)
        } else {
            ordered = stratum.candidates.sorted { $0.id < $1.id }
        }
        return Array(ordered.prefix(count))
    }

    // MARK: - Validation

    /// Rejects duplicate `MutationID`s across every candidate in `strata`
    /// (invariant 4 / A.14). Unlike v1's `BudgetSelector`, which computes
    /// `selected`/`dropped` via `Set<MutationID>` membership and so silently
    /// loses the second of two colliding points, this walks the full input
    /// once and throws on the first collision found, in input order —
    /// deterministic given a fixed input, though which specific ID is named
    /// in the error is not itself part of the contract (only that rejection
    /// happens at all).
    private static func requireUniqueMutationIDs(_ strata: [BudgetStratumV2]) throws {
        var seen = Set<MutationID>()
        for point in strata.flatMap(\.candidates) where !seen.insert(point.id).inserted {
            throw BudgetSelectorV2Error.duplicateMutationID(point.id)
        }
    }

    /// The config-load-shaped weight check B.3 specifies, expressed with
    /// this codebase's existing `ConfigurationIssue` accumulator (see
    /// `ConfigurationValidation.swift`'s `validateBudgetSampling` for the
    /// established pattern this mirrors) so a future CLI/config integration
    /// can call this directly instead of duplicating the rule. Exposed
    /// publicly for exactly that reuse; `allocateCounts` also calls it
    /// itself (via `requireValidWeight`) since this module has no
    /// `Configuration` wiring yet to enforce it upstream.
    ///
    /// - Returns: empty when `weight` is empty (equal-share default) or
    ///   when every stratum in `strataIDs` has a configured value in
    ///   `weightValidRange`; one `.error` issue per missing stratum and per
    ///   out-of-range value otherwise.
    public static func validateWeightConfiguration(
        _ weight: [String: Int],
        strataIDs: [String],
        path: String = "budget.weight"
    ) -> [ConfigurationIssue] {
        guard !weight.isEmpty else { return [] }

        var issues: [ConfigurationIssue] = []
        let strataSet = Set(strataIDs)

        for stratumID in strataSet.subtracting(weight.keys).sorted() {
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "\(path).\(stratumID)",
                message: """
                Every stratum must have a configured weight once any weight is configured for this \
                allocation; '\(stratumID)' has none.
                """
            ))
        }
        for stratumID in weight.keys.sorted() where strataSet.contains(stratumID) {
            let value = weight[stratumID] ?? 0
            guard !weightValidRange.contains(value) else { continue }
            issues.append(ConfigurationIssue(
                severity: .error,
                path: "\(path).\(stratumID)",
                message: "Must be an integer in \(weightValidRange.lowerBound)...\(weightValidRange.upperBound); got \(value)."
            ))
        }
        return issues
    }

    private static func requireValidWeight(_ weight: [String: Int], strataIDs: [String]) throws {
        let issues = validateWeightConfiguration(weight, strataIDs: strataIDs)
        guard issues.isEmpty else { throw BudgetSelectorV2Error.invalidWeightConfiguration(issues) }
    }
}
