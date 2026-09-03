import Foundation
import MutationExecution
import MutationModel
import Testing

/// EXPERIMENTAL (Research/safe-mutant-mixing-2026-09/DESIGN.md).
///
/// `MutantMixingPlanner` exists to make one guarantee, and this suite's job
/// is to prove it holds: two mutants that share a covering test must *never*
/// end up in the same batch (color). That is the one property mixed
/// execution's whole correctness argument rests on — see DESIGN.md's
/// "Attribution argument" — so every case below that produces a `Plan`
/// re-derives the answer independently (by intersecting covering-test sets
/// directly from the same map) and checks the plan against that, rather than
/// trusting the algorithm's own bookkeeping.
@Suite("Mutant conflict graph and mixing planner")
struct MutantConflictGraphTests {
    private let addTest = TestIdentifier(target: "CalcTests", qualifiedName: "CalcTests/testAdd")
    private let subtractTest = TestIdentifier(target: "CalcTests", qualifiedName: "CalcTests/testSubtract")
    private let addUsingHelperTest = TestIdentifier(target: "CalcTests", qualifiedName: "CalcTests/testAddUsingHelper")
    private let subtractUsingHelperTest = TestIdentifier(
        target: "CalcTests", qualifiedName: "CalcTests/testSubtractUsingHelper"
    )

    // MARK: - Real-fixture case: a shared helper is the one real conflict

    /// A small, realistic source shape — one shared helper called from two
    /// otherwise-independent functions — discovered through the same
    /// `MutationDiscovery` entry point the planner uses, paired with a
    /// hand-built `PerTestCoverageMap` whose covering-test relationships are
    /// exactly what a real per-test coverage run of this shape would
    /// produce (confirmed against a real build in
    /// `MutantMixingRealFixtureAcceptanceTests`, gated behind
    /// `MUTANTKIT_ACCEPTANCE=1` since it shells out to `swift build`/`swift
    /// test`): `add`/`subtract` each covered by exactly one independent
    /// test, `helper` covered by *both* tests that call it, and each
    /// `*UsingHelper` function covered only by its own test.
    ///
    /// This is deliberately not a toy with zero conflicts: `helper` is a
    /// real conflict (shared by two tests), `add`/`subtract` are real
    /// no-conflict mutants, and `addUsingHelper`/`subtractUsingHelper` are a
    /// real non-obvious no-conflict pair — two different lines, two
    /// disjoint tests, safe to mix even though both call the same helper.
    private static let calcSource = """
    public enum Calc {
        public static func add(_ x: Int, _ y: Int) -> Int {
            x + y
        }

        public static func subtract(_ x: Int, _ y: Int) -> Int {
            x - y
        }

        public static func helper(_ x: Int) -> Int {
            x + 1
        }

        public static func addUsingHelper(_ x: Int, _ y: Int) -> Int {
            helper(x) + y
        }

        public static func subtractUsingHelper(_ x: Int, _ y: Int) -> Int {
            helper(x) - y
        }
    }
    """

    private func line(containing needle: String) throws -> Int {
        try #require(Self.calcSource.components(separatedBy: "\n").firstIndex { $0.contains(needle) }) + 1
    }

    private func discoverCalcPoints() throws -> [MutationPoint] {
        try discover(Self.calcSource, path: "Sources/Calc.swift", using: Operators.arithmetic)
    }

    /// The `MutationID` of the one point discovered at a given line — asserts
    /// exactly one match, since every case this is used from relies on each
    /// fixture line containing exactly one binary-operator mutation site.
    private func idAt(line targetLine: Int, in points: [MutationPoint]) throws -> MutationID {
        try #require(points.first { $0.line == targetLine }).id
    }

    private func calcCoverageMap() throws -> PerTestCoverageMap {
        PerTestCoverageMap(
            coveringTests: [
                "Sources/Calc.swift": [
                    try line(containing: "x + y"): [addTest],
                    try line(containing: "x - y"): [subtractTest],
                    try line(containing: "x + 1"): [addUsingHelperTest, subtractUsingHelperTest],
                    try line(containing: "helper(x) + y"): [addUsingHelperTest],
                    try line(containing: "helper(x) - y"): [subtractUsingHelperTest]
                ]
            ],
            source: "test"
        )
    }

    /// Point (a): the conflict graph has no false negative. Independently
    /// recomputes, for every pair placed in the same batch, whether they
    /// actually share a covering test — the exact property mixed execution
    /// depends on — and fails if the planner ever got it wrong in the unsafe
    /// direction.
    @Test("No two mutants sharing a covering test ever land in the same batch")
    func noFalseNegativeAcrossRealFixture() throws {
        let points = try discoverCalcPoints()
        let coverage = try calcCoverageMap()
        let plan = MutantMixingPlanner.plan(points: points, coverage: coverage)

        let testsByID = Dictionary(
            uniqueKeysWithValues: points.map { ($0.id, coverage.testsCovering(file: $0.file, line: $0.line) ?? []) }
        )

        for batch in plan.batches {
            for i in batch.indices {
                for j in batch.indices where j > i {
                    let a = testsByID[batch[i]] ?? []
                    let b = testsByID[batch[j]] ?? []
                    #expect(
                        a.isDisjoint(with: b),
                        "\(batch[i]) and \(batch[j]) share a covering test but were placed in the same batch"
                    )
                }
            }
        }
    }

    @Test("Every discovered mutant is accounted for exactly once, batched or unmixable")
    func everyMutantAccountedForExactlyOnce() throws {
        let points = try discoverCalcPoints()
        let plan = MutantMixingPlanner.plan(points: points, coverage: try calcCoverageMap())

        #expect(plan.accountedForCount == points.count)
        #expect(plan.unmixable.isEmpty, "every point in this fixture has known, non-empty coverage")

        let allBatched = plan.batches.flatMap { $0 }
        #expect(Set(allBatched).count == allBatched.count, "no mutant should appear in more than one batch")
    }

    /// The one real conflict this fixture has: `helper` is covered by both
    /// `*UsingHelper` tests, so it must share a batch with neither of the
    /// mutants those tests also cover.
    @Test("The shared helper is never batched with either function that calls it")
    func sharedHelperConflictsWithBothCallers() throws {
        let points = try discoverCalcPoints()
        let plan = MutantMixingPlanner.plan(points: points, coverage: try calcCoverageMap())

        let helperLine = try line(containing: "x + 1")
        let addUsingHelperLine = try line(containing: "helper(x) + y")
        let subtractUsingHelperLine = try line(containing: "helper(x) - y")

        let helperID = try idAt(line: helperLine, in: points)
        let addUsingHelperID = try idAt(line: addUsingHelperLine, in: points)
        let subtractUsingHelperID = try idAt(line: subtractUsingHelperLine, in: points)

        let helperBatch = try #require(plan.batches.first { $0.contains(helperID) })
        #expect(!helperBatch.contains(addUsingHelperID))
        #expect(!helperBatch.contains(subtractUsingHelperID))
    }

    /// The non-obvious safe pair: both call `helper`, but their own covering
    /// tests are disjoint, so per-line coverage — not per-file, not
    /// per-declaration — correctly allows mixing them. This is the case
    /// that makes the coloring non-trivial rather than "every mutant alone".
    @Test("Two functions that share a callee but not a covering test can still be mixed")
    func callersOfSharedHelperCanBeMixedWithEachOther() throws {
        let points = try discoverCalcPoints()
        let plan = MutantMixingPlanner.plan(points: points, coverage: try calcCoverageMap())

        let addUsingHelperID = try idAt(line: line(containing: "helper(x) + y"), in: points)
        let subtractUsingHelperID = try idAt(line: line(containing: "helper(x) - y"), in: points)

        let batchOfAdd = try #require(plan.batches.first { $0.contains(addUsingHelperID) })
        #expect(batchOfAdd.contains(subtractUsingHelperID))
    }

    @Test("Five real mutants with one real conflict color into exactly two batches")
    func nonTrivialColoringOnRealFixture() throws {
        let points = try discoverCalcPoints()
        #expect(points.count == 5, "fixture is expected to yield exactly 5 arithmetic mutation points")

        let plan = MutantMixingPlanner.plan(points: points, coverage: try calcCoverageMap())

        // Not asserting greedy coloring is optimal in general (it need not
        // be) — asserting this specific, hand-verified graph's true
        // chromatic number, which greedy achieves here: `helper` conflicts
        // with two mutants that do not conflict with each other or with
        // `add`/`subtract`, so 2 colors both suffices and is necessary.
        #expect(plan.batches.count == 2)
    }

    // MARK: - Determinism

    @Test("The plan does not depend on the order points were supplied in")
    func planIsOrderIndependent() throws {
        let points = try discoverCalcPoints()
        let coverage = try calcCoverageMap()

        let forward = MutantMixingPlanner.plan(points: points, coverage: coverage)
        let reversed = MutantMixingPlanner.plan(points: points.reversed(), coverage: coverage)
        let shuffled = MutantMixingPlanner.plan(points: points.shuffled(), coverage: coverage)

        #expect(forward.batches == reversed.batches)
        #expect(forward.batches == shuffled.batches)
        #expect(forward.unmixable == reversed.unmixable)
    }

    // MARK: - Unknown / empty coverage

    @Test("A mutant with no coverage-map entry is reported unmixable, never batched")
    func unknownCoverageIsUnmixable() throws {
        let known = TestIdentifier(target: "T", qualifiedName: "C/profiled")
        // "profiled"/"unprofiled" rather than a "known"/"unknown" pair:
        // `"unknown()".contains("known()")` would be true, so a
        // substring-based line lookup needs names with no such containment.
        let source = """
        enum E {
            static func profiled() -> Int { 1 + 1 }
            static func unprofiled() -> Int { 2 + 2 }
        }
        """
        let points = try discover(source, path: "Sources/E.swift", using: Operators.arithmetic)
        #expect(points.count == 2)

        let profiledLine = try #require(
            source.components(separatedBy: "\n").firstIndex { $0.contains("profiled()") }
        ) + 1
        // Only the profiled line has a coverage-map entry at all —
        // `unprofiled`'s file+line is simply absent, exactly like a line
        // profiling never reached.
        let coverage = PerTestCoverageMap(coveringTests: ["Sources/E.swift": [profiledLine: [known]]], source: "test")

        let plan = MutantMixingPlanner.plan(points: points, coverage: coverage)

        let unprofiledID = try #require(points.first { $0.line != profiledLine }).id
        #expect(plan.unmixable == [unprofiledID])
        #expect(!plan.batches.flatMap { $0 }.contains(unprofiledID))
    }

    @Test("An empty covering-test set at a known line is treated as unknown, not as conflict-free")
    func emptyCoverageSetIsTreatedAsUnknown() throws {
        // Defensive case: `PerTestCoverageMap`'s own doc comment says a real
        // measurement never stores an empty set (an uncovered line is
        // classified `.noCoverage` before reaching selection), but this
        // planner must not silently mis-mix if one ever appears — same
        // "empty selection is never treated as narrowed" rule
        // `TestSelecting`'s callers already apply everywhere else.
        let point = try #require(
            discover("enum E { static func f() -> Int { 1 + 1 } }", path: "S.swift", using: Operators.arithmetic).first
        )
        let coverage = PerTestCoverageMap(coveringTests: ["S.swift": [point.line: []]], source: "test")

        let plan = MutantMixingPlanner.plan(points: [point], coverage: coverage)

        #expect(plan.unmixable == [point.id])
        #expect(plan.batches.isEmpty)
    }

    // MARK: - Graph fundamentals

    @Test("A mutant always conflicts with itself")
    func selfConflict() throws {
        let point = try #require(
            discover("enum E { static func f() -> Int { 1 + 1 } }", path: "S.swift", using: Operators.arithmetic).first
        )
        let coverage = PerTestCoverageMap(coveringTests: ["S.swift": [point.line: [addTest]]], source: "test")
        let (graph, _) = MutantMixingPlanner.buildGraph(points: [point], coverage: coverage)

        #expect(graph.conflicts(point.id, point.id))
    }

    /// Coverage granularity is per (file, line), the same granularity the
    /// real coverage map is measured at — never per-mutation-candidate. Two
    /// different mutants sitting at the identical line therefore always
    /// read the identical covering-test set and always conflict when that
    /// set is non-empty, regardless of which operator produced each one.
    /// This is an honest, load-bearing limitation of line-level coverage
    /// carried into the graph as-is, not a planner bug — see DESIGN.md's
    /// "Granularity" section.
    @Test("Two mutants at the identical (file, line) always conflict when that line is covered")
    func sameLineMutantsAlwaysConflict() {
        let coverage = PerTestCoverageMap(coveringTests: ["S.swift": [10: [addTest]]], source: "test")
        let a = makeMutationID("a")
        let b = makeMutationID("b")
        let points = [
            makePoint(id: a, file: "S.swift", line: 10),
            makePoint(id: b, file: "S.swift", line: 10)
        ]

        let (graph, unmixable) = MutantMixingPlanner.buildGraph(points: points, coverage: coverage)

        #expect(unmixable.isEmpty)
        #expect(graph.conflicts(a, b))
        #expect(MutantMixingPlanner.colorGreedily(graph).count == 2)
    }

    /// The degenerate case the task explicitly asked to watch for: if every
    /// mutant is covered by one common test (a shared `setUp`, or coverage
    /// too coarse to distinguish sites), the graph correctly becomes
    /// complete and greedy coloring correctly refuses to merge any of them —
    /// zero speedup, reported honestly as N batches of 1, never as a false
    /// non-conflict.
    @Test("A common covering test makes every mutant conflict with every other — no speedup, reported honestly")
    func fullyOverlappingCoverageProducesOneMutantPerBatch() {
        let shared = addTest
        var coveringTests: [Int: Set<TestIdentifier>] = [:]
        var points: [MutationPoint] = []
        for n in 0..<6 {
            coveringTests[n] = [shared]
            points.append(makePoint(id: makeMutationID("m\(n)"), file: "S.swift", line: n))
        }
        let coverage = PerTestCoverageMap(coveringTests: ["S.swift": coveringTests], source: "test")

        let plan = MutantMixingPlanner.plan(points: points, coverage: coverage)

        #expect(plan.unmixable.isEmpty)
        #expect(plan.batches.count == points.count, "a fully-shared test must force one mutant per batch")
        #expect(plan.batches.allSatisfy { $0.count == 1 })
    }

    @Test("No mutants at all produces an empty plan, not an error")
    func emptyInputProducesEmptyPlan() {
        let plan = MutantMixingPlanner.plan(points: [], coverage: PerTestCoverageMap(coveringTests: [:], source: "test"))
        #expect(plan.batches.isEmpty)
        #expect(plan.unmixable.isEmpty)
        #expect(plan.accountedForCount == 0)
    }

    // MARK: - Hardening: reviewer-verified footguns

    /// The reviewer's exact demonstrated failure: `MutantConflictGraph`'s
    /// public memberwise initializer accepted a one-directional `neighbors`
    /// map verbatim, so `colorGreedily` — which only ever consults a node's
    /// *own* neighbor set when choosing its color — could place two mutants
    /// in the same batch even though `conflicts` reports them as
    /// conflicting the other direction. Constructs exactly that malformed
    /// shape directly (bypassing `buildGraph`, which always builds a
    /// symmetric map correctly on its own) and checks the initializer now
    /// symmetrizes it rather than trusting it.
    @Test("An asymmetric neighbors map passed directly to the initializer is symmetrized, so colorGreedily never mixes the pair")
    func initializerSymmetrizesAsymmetricAdjacency() throws {
        let a = makeMutationID("a")
        let b = makeMutationID("b")

        // `a` records a conflict with `b`; `b`'s own entry does not record
        // the conflict back — the malformed, one-directional shape the
        // `neighbors` doc comment already claimed could never happen.
        let oneDirectional = MutantConflictGraph(neighbors: [a: [b], b: []], nodes: [a, b])
        #expect(oneDirectional.conflicts(a, b))
        #expect(oneDirectional.conflicts(b, a), "the reverse direction must be derived, not left missing")
        for batch in MutantMixingPlanner.colorGreedily(oneDirectional) {
            #expect(!(batch.contains(a) && batch.contains(b)), "a and b conflict; they must never share a batch")
        }

        // Same check for the even more minimal malformed shape: `b` has no
        // entry in `neighbors` at all, not even an empty one.
        let missingEntry = MutantConflictGraph(neighbors: [a: [b]], nodes: [a, b])
        #expect(missingEntry.conflicts(b, a))
        for batch in MutantMixingPlanner.colorGreedily(missingEntry) {
            #expect(!(batch.contains(a) && batch.contains(b)))
        }
    }

    /// The reviewer's exact demonstrated failure: two `MutationPoint`s
    /// sharing one `MutationID` (which should never happen, but `points` is
    /// not re-validated) used to hit `coveringTestsByID[point.id] = tests`
    /// — plain assignment — so whichever occurrence was processed last
    /// silently discarded the other's covering-test set. Here `dup`'s
    /// line-10 occurrence is covered by `testX`, its line-20 occurrence by
    /// `testY`, and `other` is covered by `testX` too — the real conflict
    /// between `dup` and `other` is visible only through the line-10
    /// occurrence. Last-write-wins (line 20 processed after line 10) would
    /// have thrown that occurrence's tests away and missed the conflict.
    @Test("Two points sharing one MutationID have their known covering tests merged, not last-write-wins overwritten")
    func duplicateMutationIDMergesCoveringTestsInsteadOfOverwriting() throws {
        let dup = makeMutationID("dup")
        let other = makeMutationID("other")
        let testX = TestIdentifier(target: "T", qualifiedName: "C/testX")
        let testY = TestIdentifier(target: "T", qualifiedName: "C/testY")

        let dupAtLine10 = makePoint(id: dup, file: "S.swift", line: 10)
        let dupAtLine20 = makePoint(id: dup, file: "S.swift", line: 20)
        let otherPoint = makePoint(id: other, file: "S.swift", line: 30)

        let coverage = PerTestCoverageMap(
            coveringTests: ["S.swift": [10: [testX], 20: [testY], 30: [testX]]],
            source: "test"
        )

        let (graph, unmixable) = MutantMixingPlanner.buildGraph(
            points: [dupAtLine10, dupAtLine20, otherPoint], coverage: coverage
        )

        #expect(unmixable.isEmpty, "every occurrence of every ID here has known coverage")
        #expect(
            graph.conflicts(dup, other),
            "dup's line-10 occurrence shares testX with other; merging must not lose that conflict"
        )
        for batch in MutantMixingPlanner.colorGreedily(graph) {
            #expect(!(batch.contains(dup) && batch.contains(other)))
        }

        // Order independence: the same merge must hold regardless of which
        // occurrence of `dup` is processed first.
        let (reversedGraph, _) = MutantMixingPlanner.buildGraph(
            points: [dupAtLine20, dupAtLine10, otherPoint], coverage: coverage
        )
        #expect(reversedGraph.conflicts(dup, other))
    }
}

// MARK: - Minimal hand-built points

/// `MutantConflictGraphTests`' own graph-fundamentals cases care only about
/// `id`/`file`/`line` — everything else about a `MutationPoint` is
/// irrelevant to conflict-graph construction, which never reads the edit
/// itself. Built directly, rather than by discovering real source and
/// patching it with the shared `.with(...)` extension in `Builders.swift`,
/// because that extension has no `file`/`line` override and these cases need
/// several distinct, explicit (file, line) pairs that do not correspond to
/// any real source text.
private func makeMutationID(_ seed: String) -> MutationID { MutationID(rawValue: "mut_\(seed)") }

private func makePoint(id: MutationID, file: String, line: Int) -> MutationPoint {
    MutationPoint(
        id: id,
        file: file,
        enclosingDeclaration: .topLevel,
        operatorID: "test.fixture",
        operatorVersion: 1,
        occurrenceIndex: 0,
        utf8Range: ByteRange(start: 0, end: 1),
        originalText: "x",
        replacementText: "y",
        prefixTokenFingerprint: "",
        suffixTokenFingerprint: "",
        sourceFileHash: "",
        expectedSyntaxKind: "",
        confidence: .high,
        executionMode: .isolated,
        line: line,
        column: 1
    )
}
