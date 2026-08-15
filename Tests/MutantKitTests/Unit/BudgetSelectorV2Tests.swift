import Foundation
import MutationModel
@testable import MutationPlanner
import Testing

/// Pins ADR-0007's Budget Selection v2 spec (`BudgetSelectorV2`) — the
/// two-level `allocateCounts`/`allocate` algorithm in B.2, the weight
/// semantics in B.3, and the `InclusionReason` schema in B.7. Fixtures reuse
/// `BudgetSelectorTests.point(...)` so both selector generations are tested
/// against the same style of `MutationPoint` construction.
@Suite("Budget selector v2: allocateCounts")
struct BudgetSelectorV2AllocateCountsTests {
    // MARK: - Degenerate cases (B.2 step 2)

    @Test("limit <= 0 returns an all-zero split with no computation")
    func nonPositiveLimitReturnsEmpty() throws {
        let strata = [Self.stratum(id: "A", count: 5), Self.stratum(id: "B", count: 5)]

        let zero = try BudgetSelectorV2.allocateCounts(strata: strata, limit: 0, seed: nil, minimumPerStratum: 1)
        let negative = try BudgetSelectorV2.allocateCounts(strata: strata, limit: -3, seed: nil, minimumPerStratum: 1)

        for split in [zero, negative] {
            #expect(split.count == 2)
            #expect(split.values.allSatisfy { $0.total == 0 })
        }
    }

    @Test("Empty strata returns an empty split")
    func emptyStrataReturnsEmpty() throws {
        let split = try BudgetSelectorV2.allocateCounts(strata: [], limit: 10, seed: nil, minimumPerStratum: 1)
        #expect(split.isEmpty)
    }

    @Test("A stratum with candidateCount == 0 never receives a grant")
    func zeroCandidateStratumGetsNothing() throws {
        let strata = [Self.stratum(id: "A", count: 0), Self.stratum(id: "B", count: 5)]

        let split = try BudgetSelectorV2.allocateCounts(strata: strata, limit: 3, seed: nil, minimumPerStratum: 1)

        #expect(split["A"]?.total == 0)
        #expect(split["B"]?.total == 3)
    }

    // MARK: - Determinism and order independence

    @Test("Same input reproduces byte-identical output")
    func deterministic() throws {
        let strata = [Self.stratum(id: "A", count: 8), Self.stratum(id: "B", count: 8), Self.stratum(id: "C", count: 8)]

        let first = try BudgetSelectorV2.allocateCounts(strata: strata, limit: 10, seed: 7, minimumPerStratum: 2)
        let second = try BudgetSelectorV2.allocateCounts(strata: strata, limit: 10, seed: 7, minimumPerStratum: 2)

        #expect(first == second)
    }

    @Test("Reordering the strata array does not change the result")
    func orderIndependent() throws {
        let strata = [Self.stratum(id: "A", count: 8), Self.stratum(id: "B", count: 8), Self.stratum(id: "C", count: 8)]

        let forward = try BudgetSelectorV2.allocateCounts(strata: strata, limit: 10, seed: 7, minimumPerStratum: 2)
        let reversed = try BudgetSelectorV2.allocateCounts(
            strata: strata.reversed(), limit: 10, seed: 7, minimumPerStratum: 2
        )

        #expect(forward == reversed)
    }

    // MARK: - Exact-fill property (B.1 invariant 11, B.2's proof)

    @Test(
        "Exact fill: total granted is min(limit, total eligible), across budgets both below and above the pool",
        arguments: [1, 3, 10, 15, 30, 100]
    )
    func exactFillAcrossBudgets(limit: Int) throws {
        let strata = [Self.stratum(id: "A", count: 4), Self.stratum(id: "B", count: 9), Self.stratum(id: "C", count: 7)]
        let totalCandidates = 20

        let split = try BudgetSelectorV2.allocateCounts(strata: strata, limit: limit, seed: 99, minimumPerStratum: 1)

        let granted = split.values.reduce(0) { $0 + $1.total }
        #expect(granted == min(limit, totalCandidates))
        #expect(granted <= limit)
        for stratum in strata {
            #expect((split[stratum.id]?.total ?? 0) <= stratum.candidates.count)
        }
    }

    // MARK: - Phase 1: genuine one-slot-per-round

    /// The ADR's own worked example (B.2 step 2): 3 strata, minimum 3,
    /// limit 5, alphabetical order [A, B, C] -> grants A1, B1, C1, A2, B2 ->
    /// {A:2, B:2, C:1}. A stratum must never receive a second slot before
    /// every other eligible stratum has had its first.
    @Test("Phase 1 grants strictly one slot per stratum per round under a tight budget")
    func phase1IsGenuinelyOneSlotPerRound() throws {
        let strata = [Self.stratum(id: "A", count: 5), Self.stratum(id: "B", count: 5), Self.stratum(id: "C", count: 5)]

        let split = try BudgetSelectorV2.allocateCounts(strata: strata, limit: 5, seed: nil, minimumPerStratum: 3)

        #expect(split["A"] == PhaseSplit(phase1: 2, phase2: 0))
        #expect(split["B"] == PhaseSplit(phase1: 2, phase2: 0))
        #expect(split["C"] == PhaseSplit(phase1: 1, phase2: 0))
    }

    // MARK: - The named leftover-pass regression (B.2's acceptance test implication)

    /// The exact counterexample that caught the prior ADR revision's
    /// `anyClipped`-based break condition: residual capacities {A:1, B:1,
    /// C:100}, equal weight, R=5 entering Phase 2. The corrected
    /// `newlySaturated.isEmpty` break condition must grant the full 5, not
    /// the bug's actual wrong output of 4.
    @Test("Leftover-pass regression: {A:1, B:1, C:100} at R=5 grants exactly 5, not 4")
    func leftoverPassRegressionGrantsExactlyFive() throws {
        let strata = [Self.stratum(id: "A", count: 1), Self.stratum(id: "B", count: 1), Self.stratum(id: "C", count: 100)]

        let split = try BudgetSelectorV2.allocateCounts(strata: strata, limit: 5, seed: nil, minimumPerStratum: 0)

        let granted = split.values.reduce(0) { $0 + $1.total }
        #expect(granted == 5, "expected exactly 5, the corrected result — 4 is the old, wrong output")
        #expect(split["A"] == PhaseSplit(phase1: 0, phase2: 1))
        #expect(split["B"] == PhaseSplit(phase1: 0, phase2: 1))
        #expect(split["C"] == PhaseSplit(phase1: 0, phase2: 3))
    }

    // MARK: - Saturated strata / uneven capacities

    @Test("A saturated stratum stops receiving grants and its budget flows to the rest")
    func saturatedStratumStopsReceivingGrants() throws {
        let strata = [Self.stratum(id: "A", count: 2), Self.stratum(id: "B", count: 50), Self.stratum(id: "C", count: 50)]

        let split = try BudgetSelectorV2.allocateCounts(strata: strata, limit: 20, seed: 3, minimumPerStratum: 0)

        #expect(split["A"]?.total == 2, "A can never exceed its own 2 candidates")
        let granted = split.values.reduce(0) { $0 + $1.total }
        #expect(granted == 20)
    }

    // MARK: - Weight configuration (B.3)

    @Test("Unconfigured weight is equal-share")
    func unconfiguredWeightIsEqualShare() throws {
        let strata = [Self.stratum(id: "A", count: 10), Self.stratum(id: "B", count: 10)]

        let split = try BudgetSelectorV2.allocateCounts(strata: strata, limit: 4, seed: nil, minimumPerStratum: 0)

        #expect(split["A"]?.total == 2)
        #expect(split["B"]?.total == 2)
    }

    @Test("A fully configured weight splits Phase 2 by floor/remainder, not by residual capacity")
    func configuredWeightUsesFloorAndRemainder() throws {
        // v2's default is equal-share, NOT v1's capacity-proportional policy
        // (B.2's correction) — this pins the floor/remainder mechanism
        // itself, weighted 1:3, independent of either stratum's capacity.
        let strata = [Self.stratum(id: "A", count: 10), Self.stratum(id: "B", count: 10)]

        let split = try BudgetSelectorV2.allocateCounts(
            strata: strata, limit: 4, seed: nil, minimumPerStratum: 0, weight: ["A": 1, "B": 3]
        )

        #expect(split["A"] == PhaseSplit(phase1: 0, phase2: 1))
        #expect(split["B"] == PhaseSplit(phase1: 0, phase2: 3))
    }

    @Test("A weight of exactly 0 anywhere is a config-load error, not a runtime fallback")
    func zeroWeightIsRejected() {
        let strata = [Self.stratum(id: "A", count: 10), Self.stratum(id: "B", count: 10)]

        #expect(throws: BudgetSelectorV2Error.self) {
            _ = try BudgetSelectorV2.allocateCounts(
                strata: strata, limit: 4, seed: nil, minimumPerStratum: 0, weight: ["A": 0, "B": 1]
            )
        }
    }

    @Test("A partially configured weight (some strata set, others not) is a config-load error")
    func partiallyConfiguredWeightIsRejected() {
        let strata = [Self.stratum(id: "A", count: 10), Self.stratum(id: "B", count: 10), Self.stratum(id: "C", count: 10)]

        #expect(throws: BudgetSelectorV2Error.self) {
            _ = try BudgetSelectorV2.allocateCounts(
                strata: strata, limit: 4, seed: nil, minimumPerStratum: 0, weight: ["A": 1, "B": 1]
            )
        }
    }

    @Test("validateWeightConfiguration reports every missing/out-of-range entry, not just the first")
    func validateWeightConfigurationReportsEveryIssue() {
        let issues = BudgetSelectorV2.validateWeightConfiguration(
            ["A": 0, "B": 2_000_000], strataIDs: ["A", "B", "C"]
        )

        // A: out of range (0); B: out of range (> 1_000_000); C: missing entirely.
        #expect(issues.count == 3)
        #expect(issues.allSatisfy { $0.severity == .error })
    }

    @Test("Empty weight against empty strata is not an error")
    func emptyWeightIsAlwaysValid() {
        #expect(BudgetSelectorV2.validateWeightConfiguration([:], strataIDs: []).isEmpty)
        #expect(BudgetSelectorV2.validateWeightConfiguration([:], strataIDs: ["A", "B"]).isEmpty)
    }

    // MARK: - Overflow-safety boundary (B.2's overflow-safety note; Codex code review #1 Medium)

    @Test("A limit exceeding 2^31 is rejected, not silently risked against Int64 overflow")
    func limitExceedingMagnitudeBoundIsRejected() {
        let strata = [Self.stratum(id: "A", count: 5), Self.stratum(id: "B", count: 5)]
        let overLimit = BudgetSelectorV2.maximumBudgetMagnitude + 1

        #expect(throws: BudgetSelectorV2Error.budgetMagnitudeExceeded(
            limit: overLimit, totalCandidates: 10, maximum: BudgetSelectorV2.maximumBudgetMagnitude
        )) {
            _ = try BudgetSelectorV2.allocateCounts(strata: strata, limit: overLimit, seed: nil, minimumPerStratum: 1)
        }
    }

    // A total-candidate-count-exceeding-2^31 case is not separately tested here:
    // it would require materializing over two billion `MutationPoint` values in
    // the test itself, which is impractical, and it goes through the exact same
    // guard/error path (`totalCandidates <= maximumBudgetMagnitude`) that
    // `limitExceedingMagnitudeBoundIsRejected` above already exercises.

    @Test("A limit exactly at the 2^31 bound is accepted, not rejected (boundary is inclusive)")
    func limitExactlyAtBoundIsAccepted() throws {
        // Degenerate-limit guard (limit <= 0) already short-circuits before the
        // magnitude check, and a real strata array at 2^31 candidates is
        // impractical to construct in a test — this pins the boundary itself
        // is inclusive (`<=`, not `<`) on the `limit` side, with a small,
        // realistic candidate count.
        let strata = [Self.stratum(id: "A", count: 5)]

        let split = try BudgetSelectorV2.allocateCounts(
            strata: strata, limit: BudgetSelectorV2.maximumBudgetMagnitude, seed: nil, minimumPerStratum: 1
        )

        #expect(split["A"]?.total == 5)
    }

    // MARK: - Exact-integer arithmetic, not floating point

    /// B.2's Phase 2 is specified using only `Int64` arithmetic specifically
    /// because a `Double`-based implementation is unsafe at the magnitudes
    /// the algorithm's own overflow-safety note allows (`remaining`/`limit`
    /// up to `2^31`, per-stratum `weight` up to `1_000_000`, `W` up to
    /// `|E| * 1_000_000`). This pins the concrete arithmetic fact that
    /// motivates that requirement: chosen so the true quotient's fractional
    /// part is closer to the double-precision rounding boundary than to the
    /// exact integer floor, a naive `Int(Double(numerator) / Double(W))`
    /// computation gives the wrong answer, while exact `Int64` division does
    /// not — this is exactly the class of bug B.2's "no Float/Double
    /// anywhere in Phase 2" requirement exists to rule out by construction,
    /// not merely by convention.
    @Test("Naive Double division would misround at the documented Phase 2 magnitude bound; Int64 does not")
    func exactInt64DivisionAvoidsTheFloatingPointPitfall() {
        let remaining: Int64 = 2_147_483_647 // <= 2^31, the documented `remaining`/`limit` bound
        let totalWeight: Int64 = 8_388_610 // a plausible sum of many strata's weights (each <= 1_000_000)
        // Constructed so numerator == floor(remaining) * totalWeight + (totalWeight - 1): the true
        // quotient sits exactly one part-per-totalWeight below the next integer.
        let numerator = remaining &* totalWeight &+ (totalWeight - 1)

        let exactFloor = numerator / totalWeight
        let exactRemainder = numerator % totalWeight
        #expect(exactFloor == remaining)
        #expect(exactRemainder == totalWeight - 1)

        let naiveFloatFloor = Int(Double(numerator) / Double(totalWeight))
        #expect(
            naiveFloatFloor != exactFloor,
            "this numerator/W pair was chosen specifically to demonstrate the divergence Int64 avoids"
        )
    }

    /// A smaller-scale, real `allocateCounts` regression pinning the exact
    /// floor/remainder result for a case a `Double`-based implementation
    /// could plausibly disagree on due to compiler/optimization-level
    /// differences in intermediate rounding; the exact-integer
    /// implementation has no such freedom; its result is fixed by the
    /// pseudocode alone, so this value must not drift between debug and
    /// release builds.
    @Test("Weighted Phase 2 result is pinned exactly, independent of build configuration")
    func weightedPhase2ResultIsPinnedExactly() throws {
        let strata = [Self.stratum(id: "A", count: 10), Self.stratum(id: "B", count: 10), Self.stratum(id: "C", count: 10)]

        let split = try BudgetSelectorV2.allocateCounts(
            strata: strata, limit: 10, seed: nil, minimumPerStratum: 0, weight: ["A": 1, "B": 2, "C": 4]
        )

        // W = 7, remaining = 10: floorShare A=10/7=1 r3, B=20/7=2 r6, C=40/7=5 r5.
        // floors sum to 8, leftover 2, remainders sorted desc: B(6), C(5), A(3) -> B and C each +1.
        #expect(split["A"] == PhaseSplit(phase1: 0, phase2: 1))
        #expect(split["B"] == PhaseSplit(phase1: 0, phase2: 3))
        #expect(split["C"] == PhaseSplit(phase1: 0, phase2: 6))
    }

    // MARK: - Fixtures

    static func stratum(id: String, count: Int, filePrefix: String? = nil) -> BudgetStratumV2 {
        let candidates = (0 ..< count).map { index in
            BudgetSelectorTests.point(
                id: "\(id)-\(index)",
                file: "\(filePrefix ?? "Sources/\(id)").swift",
                rawID: "v2_\(id)_\(index)"
            )
        }
        return BudgetStratumV2(id: id, candidates: candidates)
    }
}

@Suite("Budget selector v2: allocate")
struct BudgetSelectorV2AllocateTests {
    // MARK: - Determinism / order independence / containment

    @Test("Same input reproduces byte-identical output")
    func deterministic() throws {
        let strata = [
            BudgetSelectorV2AllocateCountsTests.stratum(id: "A", count: 6),
            BudgetSelectorV2AllocateCountsTests.stratum(id: "B", count: 6)
        ]

        let first = try BudgetSelectorV2.allocate(strata: strata, limit: 5, seed: 11, minimumPerStratum: 1)
        let second = try BudgetSelectorV2.allocate(strata: strata, limit: 5, seed: 11, minimumPerStratum: 1)

        #expect(first.map(\.point.id) == second.map(\.point.id))
        #expect(first.map(\.reason) == second.map(\.reason))
    }

    @Test("Reordering strata and their candidates does not change the result")
    func orderIndependent() throws {
        let strata = [
            BudgetSelectorV2AllocateCountsTests.stratum(id: "A", count: 6),
            BudgetSelectorV2AllocateCountsTests.stratum(id: "B", count: 6)
        ]
        let shuffled = strata.reversed().map { stratum in
            BudgetStratumV2(id: stratum.id, candidates: stratum.candidates.reversed())
        }

        let forward = try BudgetSelectorV2.allocate(strata: strata, limit: 5, seed: 11, minimumPerStratum: 1)
        let reordered = try BudgetSelectorV2.allocate(strata: shuffled, limit: 5, seed: 11, minimumPerStratum: 1)

        #expect(Set(forward.map(\.point.id)) == Set(reordered.map(\.point.id)))
        #expect(forward.map(\.point.id) == reordered.map(\.point.id), "traversal order must also match, not just the set")
    }

    @Test("No selected MutationPoint falls outside the original candidate set")
    func selectionNeverFabricatesAPoint() throws {
        let strata = [
            BudgetSelectorV2AllocateCountsTests.stratum(id: "A", count: 12),
            BudgetSelectorV2AllocateCountsTests.stratum(id: "B", count: 3),
            BudgetSelectorV2AllocateCountsTests.stratum(id: "C", count: 1)
        ]
        let allInputIDs = Set(strata.flatMap(\.candidates).map(\.id))

        let selection = try BudgetSelectorV2.allocate(strata: strata, limit: 8, seed: 5, minimumPerStratum: 1)

        #expect(Set(selection.map(\.point.id)).isSubset(of: allInputIDs))
    }

    @Test(
        "Exact-fill holds end to end across several budgets",
        arguments: [1, 4, 10, 16, 25]
    )
    func exactFillEndToEnd(limit: Int) throws {
        let strata = [
            BudgetSelectorV2AllocateCountsTests.stratum(id: "A", count: 4),
            BudgetSelectorV2AllocateCountsTests.stratum(id: "B", count: 9),
            BudgetSelectorV2AllocateCountsTests.stratum(id: "C", count: 3)
        ]
        let totalCandidates = 16

        let selection = try BudgetSelectorV2.allocate(strata: strata, limit: limit, seed: 42, minimumPerStratum: 1)

        #expect(selection.count == min(limit, totalCandidates))
    }

    // MARK: - Duplicate MutationID rejection (invariant 4 / A.14)

    @Test("A duplicate MutationID across strata is rejected, not silently dropped")
    func duplicateMutationIDIsRejected() {
        let duplicate = BudgetSelectorTests.point(id: "dup", file: "Sources/A.swift", rawID: "same-id")
        let alsoDuplicate = BudgetSelectorTests.point(id: "dup2", file: "Sources/B.swift", rawID: "same-id")
        let strata = [
            BudgetStratumV2(id: "A", candidates: [duplicate]),
            BudgetStratumV2(id: "B", candidates: [alsoDuplicate])
        ]

        #expect(throws: BudgetSelectorV2Error.self) {
            _ = try BudgetSelectorV2.allocate(strata: strata, limit: 2, seed: nil, minimumPerStratum: 1)
        }
    }

    @Test("A duplicate MutationID within the same stratum is also rejected")
    func duplicateMutationIDWithinOneStratumIsRejected() {
        let duplicate = BudgetSelectorTests.point(id: "dup", file: "Sources/A.swift", rawID: "same-id")
        let alsoDuplicate = BudgetSelectorTests.point(id: "dup2", file: "Sources/A.swift", rawID: "same-id")
        let strata = [BudgetStratumV2(id: "A", candidates: [duplicate, alsoDuplicate])]

        #expect(throws: BudgetSelectorV2Error.self) {
            _ = try BudgetSelectorV2.allocate(strata: strata, limit: 2, seed: nil, minimumPerStratum: 1)
        }
    }

    // MARK: - Operator/file imbalance (mirrors v1's own BudgetSelectorTests scenarios)

    @Test("Every stratum with eligible candidates gets its minimum, even the tiny one")
    func everyStratumGetsItsMinimum() throws {
        let dominant = BudgetSelectorV2AllocateCountsTests.stratum(id: "dominant", count: 20)
        let small = BudgetSelectorV2AllocateCountsTests.stratum(id: "small", count: 3)
        let tiny = BudgetSelectorV2AllocateCountsTests.stratum(id: "tiny", count: 1)

        let selection = try BudgetSelectorV2.allocate(
            strata: [dominant, small, tiny], limit: 10, seed: nil, minimumPerStratum: 1
        )

        let byStratum = Dictionary(grouping: selection, by: { $0.reason.stratumPath.first! })
        #expect(byStratum["dominant"]?.count ?? 0 >= 1)
        #expect(byStratum["small"]?.count ?? 0 >= 1)
        #expect(byStratum["tiny"]?.count == 1, "the single tiny candidate must be represented")
        #expect(selection.count == 10)
    }

    // MARK: - InclusionReason (B.7): single-level

    @Test("reasonCode/selectionOrdinal/stratumPath match B.7 for a single-level allocation")
    func inclusionReasonSingleLevel() throws {
        let strata = [
            BudgetSelectorV2AllocateCountsTests.stratum(id: "A", count: 5),
            BudgetSelectorV2AllocateCountsTests.stratum(id: "B", count: 5)
        ]

        let selection = try BudgetSelectorV2.allocate(strata: strata, limit: 4, seed: nil, minimumPerStratum: 1)

        for stratumID in ["A", "B"] {
            let inStratum = selection
                .filter { $0.reason.stratumPath == [stratumID] }
                .sorted { $0.reason.selectionOrdinal < $1.reason.selectionOrdinal }
            #expect(inStratum.count == 2)
            #expect(inStratum[0].reason.reasonCode == .minimumReservation)
            #expect(inStratum[0].reason.selectionOrdinal == 0)
            #expect(inStratum[1].reason.reasonCode == .proportionalRemainder)
            #expect(inStratum[1].reason.selectionOrdinal == 1)
            #expect(inStratum.allSatisfy { $0.reason.mutationID == $0.point.id })
        }
    }

    // MARK: - Recursive inner-dimension allocation (two levels)

    /// `starved` has real candidates (5) but a weight so lopsided against
    /// `big` (1_000_000 : 1, at limit 3) that it is assigned `n == 0` —
    /// the normative case B.2 step 3 calls out: a zero-count stratum makes
    /// NO inner call at all, not just "contributes zero mutants." This is
    /// checked precisely: every one of `big`'s (n > 0) candidates must
    /// reach the inner-dimension closure, and none of `starved`'s ever do.
    @Test("An outer stratum assigned n == 0 never runs the inner-dimension closure on any of its candidates")
    func zeroCountOuterStratumSkipsInnerEntirely() throws {
        let big = BudgetSelectorV2AllocateCountsTests.stratum(id: "big", count: 10)
        let starved = BudgetSelectorV2AllocateCountsTests.stratum(id: "starved", count: 5)

        var visitedIDs: Set<MutationID> = []
        let selection = try BudgetSelectorV2.allocate(
            strata: [big, starved], limit: 3, seed: nil, minimumPerStratum: 0,
            weight: ["big": 1_000_000, "starved": 1],
            innerDimension: { point in
                visitedIDs.insert(point.id)
                return point.file
            }
        )

        #expect(!selection.isEmpty)
        #expect(selection.allSatisfy { $0.reason.stratumPath.first == "big" }, "starved must be assigned n == 0 here")
        let starvedIDs = Set(starved.candidates.map(\.id))
        #expect(
            visitedIDs.isDisjoint(with: starvedIDs),
            "starved was assigned n == 0; its candidates must never reach the inner-dimension closure"
        )
        #expect(
            visitedIDs == Set(big.candidates.map(\.id)),
            "big (n > 0) must have every one of its own candidates partitioned by the inner dimension"
        )
    }

    @Test("Empty inner strata under a non-empty outer stratum select nothing extra")
    func emptyInnerStrataSelectNothing() throws {
        let stratum = BudgetStratumV2(id: "onlyEmpty", candidates: [])
        let selection = try BudgetSelectorV2.allocate(
            strata: [stratum], limit: 5, seed: nil, minimumPerStratum: 1,
            innerDimension: { $0.file }
        )
        #expect(selection.isEmpty)
    }

    @Test("Two-level allocation produces stratumPath == [outer, inner] and correct ordinals")
    func inclusionReasonTwoLevel() throws {
        let candidates = (0 ..< 6).map { index -> MutationPoint in
            let inner = index < 3 ? "innerA" : "innerB"
            return BudgetSelectorTests.point(id: "p\(index)", file: "Sources/\(inner).swift", rawID: "tl_\(index)")
        }
        let outer = BudgetStratumV2(id: "outer", candidates: candidates)

        let selection = try BudgetSelectorV2.allocate(
            strata: [outer], limit: 4, seed: nil, minimumPerStratum: 0,
            innerDimension: { $0.file }, innerMinimumPerStratum: 1
        )

        #expect(selection.count == 4)
        for entry in selection {
            #expect(entry.reason.stratumPath.count == 2)
            #expect(entry.reason.stratumPath[0] == "outer")
            #expect(["Sources/innerA.swift", "Sources/innerB.swift"].contains(entry.reason.stratumPath[1]))
        }
    }

    /// Directly tests that only the TERMINAL (inner) call's `PhaseSplit`
    /// determines `reasonCode` (B.7, normatively): the outer stratum's own
    /// minimum is 0, so if `reasonCode` were (incorrectly) derived from the
    /// outer call's split, every selected mutant here would be
    /// `.proportionalRemainder`. With `innerMinimumPerStratum: 1`, the inner
    /// call's own Phase 1 must still produce `.minimumReservation` entries.
    @Test("reasonCode is decided by the terminal (inner) call, not the outer stratum's own split")
    func reasonCodeUsesOnlyTheTerminalCallsPhaseSplit() throws {
        let candidates = (0 ..< 6).map { index -> MutationPoint in
            let inner = index < 3 ? "innerA" : "innerB"
            return BudgetSelectorTests.point(id: "q\(index)", file: "Sources/\(inner).swift", rawID: "term_\(index)")
        }
        let outer = BudgetStratumV2(id: "outer", candidates: candidates)

        // Outer minimumPerStratum: 0 -> the (single) outer stratum's own
        // PhaseSplit is entirely phase2 (proportionalRemainder-shaped), yet
        // the inner call's minimumPerStratum: 1 must still produce
        // minimumReservation entries for the two inner strata.
        let selection = try BudgetSelectorV2.allocate(
            strata: [outer], limit: 4, seed: nil, minimumPerStratum: 0,
            innerDimension: { $0.file }, innerMinimumPerStratum: 1
        )

        let reservationCount = selection.filter { $0.reason.reasonCode == .minimumReservation }.count
        #expect(reservationCount > 0, "outer's own split has phase1 == 0; only the inner call's phase1 can produce this")
    }

    // MARK: - Fixtures

    private static func inclusionReasonEquatable() {} // marker: InclusionReason must stay Equatable for the tests above
}
