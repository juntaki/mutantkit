import Foundation
import MutationModel

// EXPERIMENTAL (Research/safe-mutant-mixing-2026-09/DESIGN.md). Not wired into
// any execution path yet — see that document's "Scope of this pass" section.
// This file is a standalone, pure-function component: it only ever reads a
// `PerTestCoverageMap` that already exists (built the same way
// `selectCoveringTests` already builds one) and a list of `MutationPoint`s
// already discovered/planned by existing machinery. It runs no process,
// applies no mutation, and makes no execution decision.

/// Two mutants "conflict" (must never be tested together in one shared run)
/// exactly when some test's baseline run is recorded as covering both of
/// their mutated lines — see `MutantMixingPlanner.buildGraph`'s doc comment
/// for why that is the correct and sufficient condition, and
/// `Research/safe-mutant-mixing-2026-09/DESIGN.md`'s "Attribution argument"
/// for the full proof this graph exists to make true by construction.
///
/// A node with no entry in `neighbors` at all (as opposed to an entry mapped
/// to an empty set) never occurred in `buildGraph`'s input — `conflicts`
/// treats both the same way (no known conflict), but `MutantMixingPlanner
/// .Plan.unmixable` is the actual list of mutants excluded from the graph on
/// purpose; a missing node here is not evidence a mutant is safe to mix.
public struct MutantConflictGraph: Sendable, Equatable {
    /// Symmetric adjacency: every id present in `nodes` has an entry, possibly
    /// empty (no known conflicts). `id`'s own set never contains `id`.
    /// Symmetry is enforced by the initializer below, not merely assumed of
    /// whatever a caller passes in.
    public let neighbors: [MutationID: Set<MutationID>]
    /// Every mutant this graph has an opinion about — i.e. every mutant with
    /// a known, non-empty covering-test set. Disjoint from
    /// `MutantMixingPlanner.Plan.unmixable` by construction.
    public let nodes: Set<MutationID>

    /// `colorGreedily`'s entire correctness argument ("no two adjacent nodes
    /// ever share a color") depends on `neighbors` being symmetric — its own
    /// doc comment says so explicitly ("adjacency is stored symmetrically").
    /// `buildGraph`, the only production constructor, already builds a
    /// symmetric map by inserting both directions of every edge. But this
    /// initializer is `public`, and nothing stops a caller from handing it a
    /// one-directional map instead — verified, that lets `colorGreedily`
    /// place two conflicting mutants in the same batch even though
    /// `conflicts(a, b)` reports `true`, because `colorGreedily` only ever
    /// consults `b`'s own neighbor set when deciding `b`'s color, and an
    /// asymmetric map can leave that set without `a` in it. Deriving both
    /// directions here — from whatever was given, not trusting it — makes
    /// the stored representation symmetric by construction always, so this
    /// footgun cannot be reached through the public initializer at all. A
    /// well-formed (already-symmetric) input, e.g. anything `buildGraph`
    /// produces, passes through unchanged.
    public init(neighbors: [MutationID: Set<MutationID>], nodes: Set<MutationID>) {
        var symmetric = neighbors
        for (id, conflictsWithID) in neighbors {
            for other in conflictsWithID {
                symmetric[other, default: []].insert(id)
            }
        }
        self.neighbors = symmetric
        self.nodes = nodes
    }

    /// Whether `a` and `b` are known to conflict. `true` for `a == b`
    /// (trivially: a mutant always "conflicts" with itself, i.e. can only
    /// ever appear once in any batch) so callers never need a separate
    /// identity check before calling this.
    public func conflicts(_ a: MutationID, _ b: MutationID) -> Bool {
        a == b || (neighbors[a]?.contains(b) ?? false)
    }

    /// Degree — how many other mutants `id` is known to conflict with. `0`
    /// for a node present in the graph with no recorded conflicts (it still
    /// participated in coverage measurement; it just never shared a test
    /// with anything else in this input).
    public func degree(of id: MutationID) -> Int {
        neighbors[id]?.count ?? 0
    }
}

/// Builds `MutantConflictGraph` from a real `PerTestCoverageMap` and colors
/// it into batches — sets of mutants provably safe to test together in one
/// shared run, because no two of them were ever recorded as covered by the
/// same test.
///
/// **This does not decide whether, or how, batches actually get executed
/// together.** It is the planning half only — see
/// `Research/safe-mutant-mixing-2026-09/DESIGN.md` for what still has to be
/// true of the execution side (multi-mutation source application, and
/// fail-closed handling of a batch-wide crash/hang) before a `Plan` from
/// this type can safely drive a real run.
public enum MutantMixingPlanner {
    /// The output of planning: mixable mutants grouped into safe batches,
    /// plus the mutants this pass refused to make any claim about.
    public struct Plan: Sendable, Equatable {
        /// Deterministically ordered batches (graph-coloring color classes).
        /// Every mutant in every batch is pairwise non-conflicting with every
        /// other mutant in the *same* batch; batch order and each batch's
        /// internal order are both stable for a given input regardless of
        /// the order `points` was supplied in (`MutantMixingPlanner
        /// .colorGreedily`'s own doc comment).
        public let batches: [[MutationID]]
        /// Mutants excluded from every batch because their covering tests
        /// are unknown to `coverage` (never profiled, or a line profiling
        /// did not reach) — sorted by `MutationID` for the same determinism
        /// reason `batches` is ordered. These must always run in isolation,
        /// one at a time, exactly like a mutant `selectCoveringTests` cannot
        /// attribute already does today (`ExecutionSettings.testBatchSize`'s
        /// own doc comment: "Without a known selection the runner cannot
        /// tell which mutant a batch failure belongs to, so such a mutant
        /// still tests correctly, just alone.") — mixing inherits that same
        /// rule, for the same reason.
        public let unmixable: [MutationID]

        public init(batches: [[MutationID]], unmixable: [MutationID]) {
            self.batches = batches
            self.unmixable = unmixable
        }

        /// Total mutants this plan accounts for, mixed or not — every
        /// distinct `MutationID` among the `MutationPoint`s passed to
        /// `plan(points:coverage:)` shows up in exactly one of `batches` or
        /// `unmixable`, never both, never neither. ("Distinct `MutationID`,"
        /// not "`MutationPoint`," because this component is entirely
        /// ID-keyed throughout: two points that share one ID — which should
        /// never happen, `MutationID` being content-derived, but is not
        /// re-validated here — are the same mutant appearing twice in the
        /// input, not two mutants, so they are accounted for once, with
        /// their known covering tests merged; see `buildGraph`'s doc
        /// comment.)
        public var accountedForCount: Int {
            batches.reduce(0) { $0 + $1.count } + unmixable.count
        }
    }

    /// One mutant's known covering tests, using the exact same lookup and
    /// empty-means-unknown normalisation `MutationRunner`/
    /// `SchemataMutationRunner` already use to turn a `MutationPoint` into a
    /// selected-test set (`PerTestCoverageMap.testsCovering` — "an empty
    /// `-only-testing:` selection would run nothing and could be mistaken
    /// for a pass", the same reason this treats an empty set as "unknown",
    /// not as "known to cover nothing").
    private static func knownCoveringTests(
        for point: MutationPoint, in coverage: PerTestCoverageMap
    ) -> Set<TestIdentifier>? {
        coverage.testsCovering(file: point.file, line: point.line).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Builds the conflict graph and the unmixable set from a real coverage
    /// map and a real list of candidate mutants.
    ///
    /// **Why "shares a covering test" is the correct and sufficient
    /// conflict condition:** the whole point of mixing several mutants into
    /// one shared build+test run is that a test's outcome in that run has to
    /// be attributable back to exactly one of the mixed mutants. If two
    /// mixed mutants, A and B, were both covered by the same test T, and T
    /// failed in the shared run, there would be no way to tell — from T's
    /// result alone — whether A's mutation, B's mutation, or both caused it.
    /// Excluding every such pair from ever landing in the same batch is
    /// exactly what makes every subsequent test-failure-to-mutant
    /// attribution unambiguous by construction; see DESIGN.md's "Attribution
    /// argument" for the full statement and proof this graph is built to
    /// support.
    ///
    /// A mutant whose covering tests are unknown (`knownCoveringTests`
    /// returns `nil`) is never added as a graph node — there is no covering-
    /// test set to compare it against, so no edge to it could ever be
    /// justified as "these two provably never share a test." Treating an
    /// unknown mutant as conflict-free would be an *assumption* dressed up
    /// as a *proof*, which is exactly the gap this whole feature exists to
    /// avoid; treating it as graph-absent and reporting it via `unmixable`
    /// instead keeps every edge (and every batch) an actual, checked fact
    /// about the coverage map, never a default.
    ///
    /// **Duplicate `MutationID`s in `points` are merged, never overwritten.**
    /// `MutationID` is content-derived (`MutationID.compute`'s doc comment)
    /// so two genuinely different `MutationPoint`s sharing one should never
    /// happen — but `points` is caller-supplied and not re-validated here,
    /// so this defends against it rather than assuming it away. Verified,
    /// concretely: keying `coveringTestsByID[point.id] = tests` (plain
    /// assignment) on a repeated ID is last-write-wins — whichever
    /// occurrence of that ID is processed last silently discards every
    /// earlier occurrence's covering-test set. Two points sharing an ID but
    /// covered by different tests would then lose one occurrence's tests
    /// entirely, which can hide a real conflict (a mutant that should have
    /// been excluded from a batch reads as conflict-free instead) — exactly
    /// the false-negative category this whole component exists to rule out.
    /// Unioning every occurrence's known covering tests instead is
    /// monotonically safe: the merged set can only ever be a superset of
    /// what any single occurrence would have produced, so a real conflict
    /// can never be lost this way. An ID is reported `unmixable` only if
    /// *every* occurrence of it had unknown coverage — one occurrence with
    /// real, known coverage is real evidence, kept regardless of what other
    /// occurrences of the same ID lacked.
    public static func buildGraph(
        points: [MutationPoint], coverage: PerTestCoverageMap
    ) -> (graph: MutantConflictGraph, unmixable: [MutationID]) {
        var coveringTestsByID: [MutationID: Set<TestIdentifier>] = [:]
        var unmixableIDs: Set<MutationID> = []

        for point in points {
            if let tests = knownCoveringTests(for: point, in: coverage) {
                coveringTestsByID[point.id, default: []].formUnion(tests)
            } else {
                unmixableIDs.insert(point.id)
            }
        }
        // A duplicate ID that shows up both with known coverage (merged
        // above) and, elsewhere in `points`, with unknown coverage is
        // treated as known: real evidence from one occurrence is never
        // discarded because another occurrence of the same ID lacked it.
        unmixableIDs.subtract(coveringTestsByID.keys)

        // Invert covering-test-set -> mutant into mutant-per-test buckets:
        // every pair of mutants sharing a bucket is exactly the set of
        // conflicting pairs, found in O(mutants * tests-per-mutant) rather
        // than an O(mutants^2) all-pairs set intersection.
        var mutantsPerTest: [TestIdentifier: [MutationID]] = [:]
        for (id, tests) in coveringTestsByID {
            for test in tests {
                mutantsPerTest[test, default: []].append(id)
            }
        }

        var neighbors: [MutationID: Set<MutationID>] = [:]
        for id in coveringTestsByID.keys { neighbors[id] = [] }
        for ids in mutantsPerTest.values where ids.count > 1 {
            for i in ids.indices {
                for j in ids.indices where j > i {
                    neighbors[ids[i], default: []].insert(ids[j])
                    neighbors[ids[j], default: []].insert(ids[i])
                }
            }
        }

        let graph = MutantConflictGraph(neighbors: neighbors, nodes: Set(coveringTestsByID.keys))
        return (graph, unmixableIDs.sorted())
    }

    /// Greedy graph coloring, largest-degree-first (a standard, well-
    /// understood heuristic — Welsh-Powell ordering — chosen deliberately
    /// over a more sophisticated coloring algorithm; see DESIGN.md's
    /// "Why greedy coloring" section for the reasoning, which follows this
    /// codebase's own stated preference for simple, provably-correct
    /// approaches over clever ones). Every node gets the smallest color
    /// index not already used by a node it conflicts with. This can produce
    /// more colors (batches) than the graph's true chromatic number, which
    /// only costs a missed speedup opportunity — it can never place two
    /// conflicting mutants in the same color, which is the one property
    /// that has to be exact.
    ///
    /// **Correctness (no false negative):** by induction on `order`. When
    /// node `id` is colored, every neighbor already colored is excluded from
    /// its color choice by definition of `usedByNeighbors`; every neighbor
    /// colored *later* will, symmetrically, see `id`'s color in its own
    /// `usedByNeighbors` when its turn comes (adjacency is stored
    /// symmetrically by `buildGraph`). So for any two adjacent nodes, the one
    /// colored second always excludes the first's color. No two adjacent
    /// (conflicting) nodes can ever end up with the same color.
    ///
    /// **Determinism:** the visiting order is a total order over `MutationID`
    /// (degree descending, `MutationID` ascending as the tiebreak —
    /// `MutationID`'s own `Comparable` conformance, "sorting by ID is what
    /// makes run order deterministic without a seed") — the same graph
    /// colors identically no matter what order its nodes were discovered or
    /// supplied in, matching `PlanSharding`'s and `MutationRunner`'s own
    /// "two runs of the same plan produce the same report" guarantee.
    public static func colorGreedily(_ graph: MutantConflictGraph) -> [[MutationID]] {
        let order = graph.nodes.sorted { a, b in
            let degreeA = graph.degree(of: a)
            let degreeB = graph.degree(of: b)
            if degreeA != degreeB { return degreeA > degreeB }
            return a < b
        }

        var colorOf: [MutationID: Int] = [:]
        var membersOfColor: [Int: [MutationID]] = [:]

        for id in order {
            let usedByNeighbors = Set((graph.neighbors[id] ?? []).compactMap { colorOf[$0] })
            var color = 0
            while usedByNeighbors.contains(color) { color += 1 }
            colorOf[id] = color
            membersOfColor[color, default: []].append(id)
        }

        return membersOfColor.keys.sorted().map { membersOfColor[$0] ?? [] }
    }

    /// The end-to-end entry point: real points + a real coverage map in,
    /// a `Plan` out. Pure function, no I/O, safe to unit test directly.
    public static func plan(points: [MutationPoint], coverage: PerTestCoverageMap) -> Plan {
        let (graph, unmixable) = buildGraph(points: points, coverage: coverage)
        return Plan(batches: colorGreedily(graph), unmixable: unmixable)
    }
}
