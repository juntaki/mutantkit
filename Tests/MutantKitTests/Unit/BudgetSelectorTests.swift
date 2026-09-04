import Foundation
import MutationModel
@testable import MutationPlanner
import Testing

/// A budget is the difference between "this run finishes tonight" and "this run
/// never finishes", and it is also the one place where introducing randomness
/// would silently stop a plan from reproducing. These tests hold both lines:
/// the chosen set is deterministic with and without a seed, and `Int.random`
/// (or anything else seeded by the OS) cannot enter the selection.
@Suite("Budget selector")
struct BudgetSelectorTests {
    /// A seeded sample has to come out the same on every run — that is the
    /// entire reason the seed exists. The selection must also be a function of
    /// each mutant's own identity, so adding a file elsewhere does not reshuffle
    /// the chosen set.
    @Test("A seeded selection reproduces across runs")
    func seededSelectionIsStable() {
        let points = Self.points(count: 30)

        let first = BudgetSelector.select(points, limit: 10, seed: 42)
        let second = BudgetSelector.select(points, limit: 10, seed: 42)

        #expect(first.selected.map(\.id) == second.selected.map(\.id))
        #expect(first.dropped.map(\.id) == second.dropped.map(\.id))
    }

    /// Two different seeds have to be able to produce different selections. A
    /// deterministic fallback to stratified selection whenever the seed mattered
    /// would defeat the point of letting the user name one.
    @Test("Different seeds can produce different selections")
    func differentSeedsProduceDifferentSelections() {
        let points = Self.points(count: 30)

        let withSeedSeven = BudgetSelector.select(points, limit: 5, seed: 7)
        let withSeedFortyTwo = BudgetSelector.select(points, limit: 5, seed: 42)

        // It is *possible* for two seeds to pick the same few items, but across
        // 5 picks out of 30 we expect a meaningful overlap to be detectable as
        // a difference rather than a coincidence.
        #expect(withSeedSeven.selected.map(\.id) != withSeedFortyTwo.selected.map(\.id))
    }

    /// Each mutant's draw is a function of `(seed, its own ID)` — not of the
    /// other mutants present. So a mutant that wins a one-on-one always wins a
    /// one-on-one against the same opponent, even when thousands of other
    /// mutants are in the population. This is the property that lets a budget
    /// reproduce at all: a mutant's draw cannot depend on which other files
    /// happened to be parsed alongside it.
    @Test("A mutant's draw does not depend on who else is present")
    func drawsAreIndependentOfPopulation() {
        let a = Self.point(id: "a", file: "Sources/A.swift", rawID: "mut_alice")
        let b = Self.point(id: "b", file: "Sources/B.swift", rawID: "mut_bob")
        let c = Self.point(id: "c", file: "Sources/C.swift", rawID: "mut_carol")

        // Head-to-head: with limit 1 and the same seed, the winner is decided
        // purely by each mutant's draw, and draws are stable across populations.
        let abWinner = BudgetSelector.select([a, b], limit: 1, seed: 7).selected.first
        let abcWinner = BudgetSelector.select([a, b, c], limit: 1, seed: 7).selected.first

        // If `a` beat `b` head-to-head, `a` still beats `b` in any superset. So
        // the winner of `[a, b]` is the winner of `[a, b, c]` if and only if `c`
        // did not draw a smaller key than both — which we observe by also
        // testing `c` against the same opponents.
        let acWinner = BudgetSelector.select([a, c], limit: 1, seed: 7).selected.first
        let bcWinner = BudgetSelector.select([b, c], limit: 1, seed: 7).selected.first

        // The pairwise winner between any two must agree with the full set's
        // winner, whichever pair it was. Concretely: the full-set winner is the
        // one mutant that wins every pairwise comparison it is part of.
        let winner = abcWinner
        if winner?.id == a.id {
            #expect(abWinner?.id == a.id)
            #expect(acWinner?.id == a.id)
        } else if winner?.id == b.id {
            #expect(abWinner?.id == b.id)
            #expect(bcWinner?.id == b.id)
        } else {
            #expect(acWinner?.id == c.id)
            #expect(bcWinner?.id == c.id)
        }
    }

    /// Unseeded selection is round-robin over files and operators, so every
    /// file contributes its first mutant before any file contributes its
    /// second. The "first N by ID" alternative is exactly what a budget is not
    /// supposed to be — an arbitrary slice.
    @Test("Unseeded selection round-robins across files")
    func stratifiedRoundRobinsAcrossFiles() {
        let points = (0 ..< 4).flatMap { fileIndex in
            (0 ..< 5).map { mutationIndex in
                Self.point(
                    id: "f\(fileIndex)m\(mutationIndex)",
                    file: "Sources/File\(fileIndex).swift",
                    rawID: "f\(fileIndex)m\(mutationIndex)"
                )
            }
        }

        let selection = BudgetSelector.select(points, limit: 4, seed: nil)

        // One pick from each file. The first-N-by-ID alternative would put two
        // or three picks in the file whose hashes happen to sort first.
        let pickedFiles = Set(selection.selected.map(\.file))
        #expect(pickedFiles.count == 4)
    }

    /// Within a file, round-robin picks across operators: a single operator's
    /// sites do not crowd out another operator's. This is what makes "10 mutants
    /// per file" mean ten different things rather than ten near-duplicates.
    @Test("Unseeded selection round-robins across operators within a file")
    func stratifiedRoundRobinsAcrossOperators() {
        let boolPoints = (0 ..< 5).map { idx in
            Self.point(
                id: "bool\(idx)",
                file: "Sources/Foo.swift",
                rawID: "bool\(idx)",
                operatorID: "swift.core.bool-literal-inversion"
            )
        }
        let relationalPoints = (0 ..< 5).map { idx in
            Self.point(
                id: "rel\(idx)",
                file: "Sources/Foo.swift",
                rawID: "rel\(idx)",
                operatorID: "swift.core.relational-operator-replacement"
            )
        }

        let selection = BudgetSelector.select(boolPoints + relationalPoints, limit: 4, seed: nil)

        let pickedOperators = Set(selection.selected.map(\.operatorID))
        #expect(pickedOperators.count == 2)
    }

    /// Selection respects the limit exactly. Off-by-one here means a 50-mutant
    /// budget silently becomes 49 or 51, and the only signal is a score that
    /// does not match the run the user asked for.
    @Test("Selection respects the limit exactly")
    func selectionRespectsLimit() {
        let points = Self.points(count: 30)

        for limit in [1, 5, 15, 30] {
            let selection = BudgetSelector.select(points, limit: limit, seed: nil)
            #expect(selection.selected.count == limit, "limit \(limit) gave \(selection.selected.count)")
        }
    }

    @Test("A limit larger than the population keeps everything")
    func limitLargerThanPopulationKeepsAll() {
        let points = Self.points(count: 5)

        let selection = BudgetSelector.select(points, limit: 100, seed: nil)

        #expect(selection.selected.count == 5)
        #expect(selection.dropped.isEmpty)
    }

    /// Selected and dropped together partition the input exactly. A mutant in
    /// both lists would be double-counted; a mutant in neither would silently
    /// vanish from the plan — and from `discovered`.
    @Test("Selected and dropped partition the input")
    func selectionPartitionsInput() {
        let points = Self.points(count: 25)

        for seed in [nil, UInt64(1), UInt64(99)] {
            let selection = BudgetSelector.select(points, limit: 10, seed: seed)
            let selectedSet = Set(selection.selected.map(\.id))
            let droppedSet = Set(selection.dropped.map(\.id))

            #expect(selectedSet.isDisjoint(with: droppedSet))
            #expect(selectedSet.union(droppedSet).count == points.count)
        }
    }

    /// The planner outputs a sorted mutation list, so selection's output has to
    /// be sorted by ID too — otherwise the gate that builds `skipped` from
    /// `dropped` and the gate that keeps `mutations` would land on different
    /// orderings and the plan would no longer be byte-stable.
    @Test("Selected and dropped are returned sorted by ID")
    func selectionIsSortedByID() {
        let points = Self.points(count: 20)

        let seeded = BudgetSelector.select(points, limit: 7, seed: 5)
        let unseeded = BudgetSelector.select(points, limit: 7, seed: nil)

        #expect(seeded.selected.map(\.id) == seeded.selected.map(\.id).sorted())
        #expect(seeded.dropped.map(\.id) == seeded.dropped.map(\.id).sorted())
        #expect(unseeded.selected.map(\.id) == unseeded.selected.map(\.id).sorted())
        #expect(unseeded.dropped.map(\.id) == unseeded.dropped.map(\.id).sorted())
    }

    // MARK: - SplitMix64

    /// SplitMix64 is the only source of randomness the planner is allowed to
    /// use. If its sequence is not reproducible, no seeded plan reproduces
    /// either — the seed becomes a label rather than a guarantee.
    @Test("SplitMix64 produces the same sequence for the same seed")
    func splitMix64IsReproducible() {
        var generatorA = SplitMix64(seed: 0xDEAD_BEEF_BADC_0FFE)
        var generatorB = SplitMix64(seed: 0xDEAD_BEEF_BADC_0FFE)

        for _ in 0 ..< 1000 {
            #expect(generatorA.next() == generatorB.next())
        }
    }

    /// Different seeds produce different sequences. A broken `next()` that
    /// ignored the seed would still pass the previous test and silently turn
    /// the seed into documentation rather than behaviour.
    @Test("SplitMix64 produces different sequences for different seeds")
    func splitMix64DiffersBySeed() {
        var a = SplitMix64(seed: 1)
        var b = SplitMix64(seed: 2)

        var differences = 0
        for _ in 0 ..< 100 where a.next() != b.next() { differences += 1 }
        #expect(differences > 90)
    }

    /// StableHash.fnv1a64 is what shards and budget sampling key off. Swift's
    /// per-process `Hasher` would silently stop reproducing if it were used
    /// here; this test pins the value so a regression to `Hasher` shows up as a
    /// single number changing.
    @Test("FNV-1a 64 is process-independent and known")
    func fnv1aIsKnown() {
        #expect(StableHash.fnv1a64("") == 0xCBF2_9CE4_8422_2325)
        #expect(StableHash.fnv1a64("a") == 0xAF63_DC4C_8601_EC8C)
        #expect(StableHash.fnv1a64("foobar") == 0x8594_4171_F739_67E8)
    }

    // MARK: - Fixtures

    private static func points(count: Int, offset: Int = 0) -> [MutationPoint] {
        (0 ..< count).map { index in
            let id = "mut_\(String(format: "%04d", index + offset))"
            return point(id: "p\(index)", file: "Sources/File\(index % 3).swift", rawID: id)
        }
    }

    /// A point built for budget selection. The ID is what selection keys off,
    /// so the test sets `rawValue` directly to make assertions readable; the
    /// other fields are along for the ride.
    static func point(
        id label: String,
        file: String,
        rawID: String,
        operatorID: String = "swift.core.bool-literal-inversion",
        originalText: String = "true",
        replacementText: String = "false"
    ) -> MutationPoint {
        let declaration = DeclarationIdentity(path: ["Fixture", "value()"])
        return MutationPoint(
            id: MutationID(rawValue: rawID),
            file: file,
            enclosingDeclaration: declaration,
            operatorID: operatorID,
            operatorVersion: 1,
            occurrenceIndex: 0,
            utf8Range: ByteRange(start: 0, end: 4),
            originalText: originalText,
            replacementText: replacementText,
            prefixTokenFingerprint: "prefix",
            suffixTokenFingerprint: "suffix",
            sourceFileHash: ContentHash.of(file),
            expectedSyntaxKind: "booleanLiteralExpr",
            confidence: .high,
            executionMode: .isolated,
            line: 1,
            column: 1
        )
    }
}

/// `.subtype` stratifies by operator *and* by the exact original →
/// replacement pair — a real-project-shaped population (890 mutants, almost all
/// `relational-operator-replacement`, spread across ten distinct
/// replacement pairs) is exactly the case an operator/file-only stratum
/// cannot serve: every mutant in the same file competes in the same
/// round-robin slot regardless of which of the ten pairs it is, so a
/// 50-mutant budget could easily land all fifty on two or three pairs.
@Suite("Budget selector: subtype stratification")
struct BudgetSelectorSubtypeStratificationTests {
    /// Two operators, each with two distinct replacement pairs — four strata
    /// total. A budget that exhausts before every stratum contributes twice
    /// must still touch every stratum once.
    private static func fourStrataPoints() -> [MutationPoint] {
        let strata: [(operatorID: String, originalText: String, replacementText: String)] = [
            ("swift.core.relational-operator-replacement", ">", ">="),
            ("swift.core.relational-operator-replacement", ">=", ">"),
            ("swift.core.relational-operator-replacement", "<", "<="),
            ("swift.core.bool-literal-inversion", "true", "false")
        ]
        return strata.flatMap { stratum in
            (0 ..< 5).map { index in
                BudgetSelectorTests.point(
                    id: "\(stratum.operatorID)-\(stratum.originalText)-\(index)",
                    file: "Sources/Foo.swift",
                    rawID: "\(stratum.operatorID)_\(stratum.originalText)_\(stratum.replacementText)_\(index)",
                    operatorID: stratum.operatorID,
                    originalText: stratum.originalText,
                    replacementText: stratum.replacementText
                )
            }
        }
    }

    /// A stratum is keyed by (operator, original, replacement), not just
    /// operator — two replacement pairs on the same operator must not share a
    /// round-robin slot, or the majority pair crowds out the minority one
    /// exactly as an unstratified sample would.
    @Test("Selection round-robins across every distinct (operator, replacement) pair")
    func roundRobinsAcrossSubtypes() {
        let points = Self.fourStrataPoints()

        let selection = BudgetSelector.select(points, limit: 4, seed: nil, stratifyBy: .subtype)

        let pickedStrata = Set(selection.selected.map { "\($0.operatorID)/\($0.originalText)/\($0.replacementText)" })
        #expect(pickedStrata.count == 4, "\(pickedStrata)")
    }

    /// A limit smaller than the stratum count still spreads across strata
    /// rather than draining the first one alphabetically.
    @Test("A limit smaller than the stratum count still spreads across strata")
    func spreadsAcrossStrataEvenWhenBudgetIsTight() {
        let points = Self.fourStrataPoints()

        let selection = BudgetSelector.select(points, limit: 2, seed: nil, stratifyBy: .subtype)

        let pickedStrata = Set(selection.selected.map { "\($0.operatorID)/\($0.originalText)/\($0.replacementText)" })
        #expect(pickedStrata.count == 2, "\(pickedStrata)")
    }

    /// A budget bigger than one round still gives every stratum its second
    /// member before any stratum gets a third.
    @Test("A larger budget round-robins a second pass across strata")
    func secondPassStillRoundRobins() {
        let points = Self.fourStrataPoints()

        let selection = BudgetSelector.select(points, limit: 8, seed: nil, stratifyBy: .subtype)

        var countsByStratum: [String: Int] = [:]
        for point in selection.selected {
            countsByStratum["\(point.operatorID)/\(point.originalText)/\(point.replacementText)", default: 0] += 1
        }
        #expect(countsByStratum.count == 4, "\(countsByStratum)")
        #expect(countsByStratum.values.allSatisfy { $0 == 2 }, "\(countsByStratum)")
    }

    /// The whole reason a seed exists: the same plan and seed always draw the
    /// same fifty mutants.
    @Test("The same seed reproduces the same selection")
    func sameSeedReproduces() {
        let points = Self.fourStrataPoints()

        let first = BudgetSelector.select(points, limit: 10, seed: 42, stratifyBy: .subtype)
        let second = BudgetSelector.select(points, limit: 10, seed: 42, stratifyBy: .subtype)

        #expect(first.selected.map(\.id) == second.selected.map(\.id))
    }

    /// Two seeds still select from the same strata — this option's whole
    /// point is that stratum coverage does not depend on the seed — but the
    /// specific member drawn from a stratum can differ.
    @Test("Different seeds keep the same strata but can differ in which member wins")
    func differentSeedsSameStrataDifferentMembers() {
        let points = Self.fourStrataPoints()

        let withSeedSeven = BudgetSelector.select(points, limit: 4, seed: 7, stratifyBy: .subtype)
        let withSeedFortyTwo = BudgetSelector.select(points, limit: 4, seed: 42, stratifyBy: .subtype)

        let strataSeven = Set(withSeedSeven.selected.map { "\($0.operatorID)/\($0.originalText)/\($0.replacementText)" })
        let strataFortyTwo = Set(
            withSeedFortyTwo.selected.map { "\($0.operatorID)/\($0.originalText)/\($0.replacementText)" }
        )
        #expect(strataSeven == strataFortyTwo)
        #expect(withSeedSeven.selected.map(\.id) != withSeedFortyTwo.selected.map(\.id))
    }

    /// Without a seed, the member chosen from each stratum is the lowest ID —
    /// deterministic, not arbitrary, and not dependent on discovery order.
    @Test("Unseeded selection within a stratum is ordered by ID")
    func unseededOrdersByID() {
        let points = Self.fourStrataPoints()

        let selection = BudgetSelector.select(points, limit: 4, seed: nil, stratifyBy: .subtype)

        for point in selection.selected {
            let siblings = points.filter {
                $0.operatorID == point.operatorID
                    && $0.originalText == point.originalText
                    && $0.replacementText == point.replacementText
            }
            let lowestID = siblings.map(\.id).min()!
            #expect(point.id == lowestID)
        }
    }

    /// `stratifyBy: nil` must select exactly what it selected before this
    /// option existed — this is what makes the option additive rather than a
    /// change to every existing config.
    @Test("Omitting stratifyBy leaves the original file/operator selection unchanged")
    func omittingStratifyByPreservesOriginalBehavior() {
        let points = Self.fourStrataPoints()

        let withoutStratifyBy = BudgetSelector.select(points, limit: 6, seed: nil)
        let withNilStratifyBy = BudgetSelector.select(points, limit: 6, seed: nil, stratifyBy: nil)

        #expect(withoutStratifyBy.selected.map(\.id) == withNilStratifyBy.selected.map(\.id))
    }
}

/// `.operatorSubtype` exists so a run against a real project's mutant pool
/// gives every enabled operator *some* signal, not just the operators whose
/// candidates happen to be a large share of the pool — confirmed against a
/// real internal validation corpus, where a 100-mutant
/// `stratifyBy: subtype` sample drew zero `ternary-branch-swap` and zero
/// `unary-not-removal` candidates out of 1242 discovered, forcing a separate
/// single-operator run just to measure either one.
@Suite("Budget selector: operator/subtype balanced")
struct BudgetSelectorOperatorSubtypeTests {
    /// Three operators with very different pool sizes: one dominant (20
    /// candidates), one small (3), one tiny (1) — the exact shape that
    /// starves the minority operators under proportional sampling.
    private static func skewedPoints() -> [MutationPoint] {
        let dominant = (0 ..< 20).map { index in
            BudgetSelectorTests.point(
                id: "dom\(index)", file: "Sources/Foo.swift", rawID: "dom\(index)",
                operatorID: "swift.core.relational-operator-replacement"
            )
        }
        let small = (0 ..< 3).map { index in
            BudgetSelectorTests.point(
                id: "small\(index)", file: "Sources/Foo.swift", rawID: "small\(index)",
                operatorID: "swift.core.ternary-branch-swap"
            )
        }
        let tiny = [
            BudgetSelectorTests.point(
                id: "tiny0", file: "Sources/Foo.swift", rawID: "tiny0",
                operatorID: "swift.core.unary-not-removal"
            )
        ]
        return dominant + small + tiny
    }

    /// RED #1: 7 operators, >1000 candidates, 100-mutant budget — every
    /// operator with a candidate must get at least one slot. This is the
    /// exact Run B shape (1242 discovered, 100 budgeted) that drew 0
    /// ternary-branch-swap and 0 unary-not-removal candidates under the old
    /// alphabetical-stratum-key `.subtype` mode.
    @Test("Every one of 7 operators over a >1000-candidate pool gets at least 1 slot at a 100 budget")
    func sevenOperatorsOverLargePoolAllRepresented() {
        let operatorIDs = [
            "swift.core.bool-literal-inversion",
            "swift.core.logical-connector-replacement",
            "swift.core.relational-operator-replacement",
            "swift.core.ternary-branch-swap",
            "swift.core.unary-not-removal",
            "swift.core.nil-coalescing-fallback",
            "swift.core.return-value-replacement"
        ]
        // Skewed like a real corpus pool: the first operator alone
        // contributes most of the 1000+ candidates, the rest a handful each —
        // mirroring relational-operator-replacement's dominance in Run A/B.
        var points: [MutationPoint] = []
        for (operatorIndex, operatorID) in operatorIDs.enumerated() {
            let count = operatorIndex == 0 ? 1000 : 10
            for index in 0 ..< count {
                points.append(BudgetSelectorTests.point(
                    id: "\(operatorID)-\(index)", file: "Sources/Foo.swift",
                    rawID: "\(operatorID)_\(index)", operatorID: operatorID
                ))
            }
        }

        let selection = BudgetSelector.selectByOperatorSubtype(
            points, limit: 100, seed: 42, minimumPerOperator: 5
        )

        #expect(selection.selected.count == 100)
        for operatorID in operatorIDs {
            #expect((selection.assignedPerOperator[operatorID] ?? 0) >= 1, "\(operatorID) got none")
        }
    }

    /// RED #2: an operator whose every candidate has distinct `originalText`/
    /// `replacementText` — one subtype per site, the shape return-value- and
    /// nil-coalescing-style whole-expression operators actually have in a
    /// real corpus — must not crowd out other operators just because it has
    /// many more *subtypes* than they do.
    @Test("An operator with many unique-text subtypes does not exclude other operators")
    func manyUniqueSubtypesDoNotExcludeOtherOperators() {
        let manySubtypes = (0 ..< 50).map { index in
            BudgetSelectorTests.point(
                id: "rv\(index)", file: "Sources/Foo.swift", rawID: "rv\(index)",
                operatorID: "swift.core.return-value-replacement",
                originalText: "expr\(index)", replacementText: "nil"
            )
        }
        let onePerOperator = ["swift.core.ternary-branch-swap", "swift.core.unary-not-removal"].map { operatorID in
            BudgetSelectorTests.point(
                id: operatorID, file: "Sources/Foo.swift", rawID: operatorID, operatorID: operatorID
            )
        }

        let selection = BudgetSelector.selectByOperatorSubtype(
            manySubtypes + onePerOperator, limit: 5, seed: 42, minimumPerOperator: 1
        )

        #expect((selection.assignedPerOperator["swift.core.ternary-branch-swap"] ?? 0) >= 1)
        #expect((selection.assignedPerOperator["swift.core.unary-not-removal"] ?? 0) >= 1)
    }

    /// RED #3: the input array's order must not matter — the same set of
    /// points in reverse order selects identically. `selectByOperatorSubtype`
    /// always re-derives a sorted base order before applying `seededOrder`,
    /// so discovery/iteration order can never leak into the result.
    @Test("Reversing operator/point order does not change the selection")
    func reversedInputOrderSelectsIdentically() {
        let points = Self.skewedPoints()

        let forward = BudgetSelector.selectByOperatorSubtype(
            points, limit: 6, seed: 42, minimumPerOperator: 1
        )
        let reversed = BudgetSelector.selectByOperatorSubtype(
            points.reversed(), limit: 6, seed: 42, minimumPerOperator: 1
        )

        #expect(forward.selected.map(\.id) == reversed.selected.map(\.id))
        #expect(forward.assignedPerOperator == reversed.assignedPerOperator)
    }

    /// The entire point of this mode: an operator with only 1/24 of the pool
    /// still gets a slot, which proportional sampling at this budget would
    /// not guarantee.
    @Test("Every operator with a candidate gets at least its minimum")
    func everyOperatorGetsItsMinimum() {
        let points = Self.skewedPoints()

        let selection = BudgetSelector.selectByOperatorSubtype(
            points, limit: 6, seed: 42, minimumPerOperator: 1
        )

        let selectedOperators = Set(selection.selected.map(\.operatorID))
        #expect(selectedOperators == [
            "swift.core.relational-operator-replacement",
            "swift.core.ternary-branch-swap",
            "swift.core.unary-not-removal"
        ])
        #expect(selection.assignedPerOperator["swift.core.unary-not-removal"] == 1)
        #expect(selection.assignedPerOperator["swift.core.ternary-branch-swap"]! >= 1)
    }

    /// RED #8/#9: `minimumPerOperator` above 1 reserves more than a single
    /// slot per operator, capped at that operator's candidate count — an
    /// operator with fewer candidates than the minimum contributes *all* of
    /// them and no more, returning the rest of its would-be minimum to the
    /// round-robin for other operators still under their own minimum.
    @Test("minimumPerOperator above 1 is honored up to each operator's candidate count")
    func higherMinimumIsHonored() {
        let points = Self.skewedPoints()

        let selection = BudgetSelector.selectByOperatorSubtype(
            points, limit: 10, seed: 42, minimumPerOperator: 3
        )

        // ternary has exactly 3 candidates: minimum 3 exhausts it exactly.
        #expect(selection.assignedPerOperator["swift.core.ternary-branch-swap"] == 3)
        // unary-not has only 1 candidate: the minimum cannot exceed what exists,
        // and the unspent 2 slots aren't just lost — they flow to relational's
        // remainder share instead (checked below).
        #expect(selection.assignedPerOperator["swift.core.unary-not-removal"] == 1)
        // limit 10 = 3 (relational min) + 3 (ternary min, exhausts) + 1 (unary
        // exhausts) + 3 leftover, all of which must go somewhere since
        // relational has 20 candidates of remaining capacity.
        #expect(selection.assignedPerOperator["swift.core.relational-operator-replacement"] == 6)
        #expect(selection.selected.count == 10)
    }

    /// RED #7: when the budget cannot cover every operator's minimum, which
    /// operators are included is a deterministic function of `(operatorIDs,
    /// seed)` — calling twice with the same seed always drops the same
    /// operator.
    @Test("A budget smaller than the operator count is deterministic across repeated calls")
    func scarceBudgetIsDeterministic() {
        let points = Self.skewedPoints()

        let first = BudgetSelector.selectByOperatorSubtype(points, limit: 2, seed: 42, minimumPerOperator: 1)
        let second = BudgetSelector.selectByOperatorSubtype(points, limit: 2, seed: 42, minimumPerOperator: 1)

        #expect(first.selected.count == 2)
        #expect(first.assignedPerOperator == second.assignedPerOperator)
    }

    /// RED #5/#7: a scarce budget's *which-operators-survive* decision is
    /// seed-dependent, not a fixed alphabetical prefix — two different seeds
    /// can (and, empirically, do) drop a different operator. This is the
    /// specific gap `.subtype`'s alphabetical stratum order has (see its doc
    /// comment) that `.operatorSubtype` exists to close.
    @Test("Different seeds can drop a different operator under a scarce budget")
    func differentSeedsCanDropDifferentOperatorUnderScarceBudget() {
        let points = Self.skewedPoints()

        // Sweep enough seeds that if operator inclusion were secretly fixed
        // (e.g. still alphabetical), this would fail; if it's seed-dependent,
        // at least one seed should disagree with seed 1's dropped operator.
        let baseline = BudgetSelector.selectByOperatorSubtype(points, limit: 2, seed: 1, minimumPerOperator: 1)
        let baselineIncluded = Set(baseline.assignedPerOperator.keys)

        let disagreements = (2 ... 40).contains { seedValue in
            let selection = BudgetSelector.selectByOperatorSubtype(
                points, limit: 2, seed: UInt64(seedValue), minimumPerOperator: 1
            )
            return Set(selection.assignedPerOperator.keys) != baselineIncluded
        }
        #expect(disagreements, "expected at least one of 39 seeds to include a different operator pair")
    }

    /// RED #6: seed also decides which *subtypes* survive when a single
    /// operator's distinct (original, replacement) pairs outnumber its
    /// allocated slots — not just which member of an already-included
    /// subtype is drawn (that part `.subtype` already did).
    @Test("Different seeds can select different subtypes within one operator's slice")
    func differentSeedsCanSelectDifferentSubtypesWithinOperator() {
        let pairs: [(String, String)] = [(">", ">="), ("<", "<="), ("==", "!="), (">=", ">"), ("<=", "<")]
        let points = pairs.flatMap { original, replacement in
            (0 ..< 3).map { index in
                BudgetSelectorTests.point(
                    id: "\(original)-\(index)", file: "Sources/Foo.swift",
                    rawID: "\(original)_\(replacement)_\(index)",
                    operatorID: "swift.core.relational-operator-replacement",
                    originalText: original, replacementText: replacement
                )
            }
        }

        // minimumPerOperator: 2 with a single operator and 5 subtypes means
        // only 2 of the 5 pairs can be represented — which 2 must vary by seed.
        func pickedPairs(seed: UInt64) -> Set<String> {
            let selection = BudgetSelector.selectByOperatorSubtype(
                points, limit: 2, seed: seed, minimumPerOperator: 2
            )
            return Set(selection.selected.map { "\($0.originalText)/\($0.replacementText)" })
        }

        let baseline = pickedPairs(seed: 1)
        let disagreements = (2 ... 40).contains { pickedPairs(seed: UInt64($0)) != baseline }
        #expect(disagreements, "expected at least one of 39 seeds to select a different subtype pair")
    }

    /// After every operator's minimum is reserved, the remaining budget
    /// should track each operator's remaining candidate pool — the dominant
    /// operator's leftover candidates get most of the remainder.
    @Test("Remainder budget is distributed proportionally to remaining candidates")
    func remainderIsProportional() {
        let points = Self.skewedPoints()

        // limit 12: 3 minimums (1 each) reserved first, 9 left. Remaining
        // capacity: relational 19, ternary 2, unary-not 0 (already exhausted
        // at its single candidate) — relational should get the lion's share.
        let selection = BudgetSelector.selectByOperatorSubtype(
            points, limit: 12, seed: 42, minimumPerOperator: 1
        )

        #expect(selection.selected.count == 12)
        let relational = selection.assignedPerOperator["swift.core.relational-operator-replacement"]!
        let ternary = selection.assignedPerOperator["swift.core.ternary-branch-swap"]!
        #expect(selection.assignedPerOperator["swift.core.unary-not-removal"] == 1)
        #expect(relational > ternary)
        #expect(relational + ternary + 1 == 12)
    }

    /// No operator is ever assigned more than it has candidates for, no
    /// matter how much budget or how skewed the remainder split is.
    @Test("No operator is ever over-assigned beyond its candidate count")
    func neverExceedsCandidateCount() {
        let points = Self.skewedPoints()

        let selection = BudgetSelector.selectByOperatorSubtype(
            points, limit: 24, seed: 42, minimumPerOperator: 1
        )

        #expect(selection.assignedPerOperator["swift.core.relational-operator-replacement"] == 20)
        #expect(selection.assignedPerOperator["swift.core.ternary-branch-swap"] == 3)
        #expect(selection.assignedPerOperator["swift.core.unary-not-removal"] == 1)
        #expect(selection.selected.count == 24)
    }

    /// RED #4: same inputs, same seed: the same selection every time.
    @Test("The same seed reproduces the same selection")
    func sameSeedReproduces() {
        let points = Self.skewedPoints()

        let first = BudgetSelector.selectByOperatorSubtype(points, limit: 10, seed: 42, minimumPerOperator: 1)
        let second = BudgetSelector.selectByOperatorSubtype(points, limit: 10, seed: 42, minimumPerOperator: 1)

        #expect(first.selected.map(\.id) == second.selected.map(\.id))
        #expect(first.assignedPerOperator == second.assignedPerOperator)
    }

    /// RED #5: two different seeds can select different *sites* even when
    /// they agree on operator/subtype inclusion — the within-stratum member
    /// draw is still seed-dependent, same as `.subtype`.
    @Test("Different seeds can select different sites even with the same operator/subtype coverage")
    func differentSeedsSelectDifferentSites() {
        let points = Self.skewedPoints()

        let withSeedOne = BudgetSelector.selectByOperatorSubtype(points, limit: 10, seed: 1, minimumPerOperator: 1)
        let withSeedTwo = BudgetSelector.selectByOperatorSubtype(points, limit: 10, seed: 2, minimumPerOperator: 1)

        #expect(withSeedOne.selected.map(\.id) != withSeedTwo.selected.map(\.id))
    }

    /// An operator's reserved slots spread across its distinct (original,
    /// replacement) pairs, not just its most common one — within-operator
    /// stratification is unconditional under `.operatorSubtype`, not an
    /// opt-in.
    @Test("An operator's slots spread across its distinct subtype pairs")
    func operatorSlotsSpreadAcrossSubtypes() {
        let pairs: [(String, String)] = [(">", ">="), ("<", "<="), ("==", "!=")]
        let points = pairs.flatMap { original, replacement in
            (0 ..< 4).map { index in
                BudgetSelectorTests.point(
                    id: "\(original)-\(index)", file: "Sources/Foo.swift",
                    rawID: "\(original)_\(replacement)_\(index)",
                    operatorID: "swift.core.relational-operator-replacement",
                    originalText: original, replacementText: replacement
                )
            }
        }

        let selection = BudgetSelector.selectByOperatorSubtype(
            points, limit: 3, seed: nil, minimumPerOperator: 3
        )

        let pickedPairs = Set(selection.selected.map { "\($0.originalText)/\($0.replacementText)" })
        #expect(pickedPairs.count == 3, "\(pickedPairs)")
    }

    /// Every eligible candidate is reported per operator, whether or not it
    /// was selected — this is what lets a report reconstruct
    /// discovered/eligible/selected per operator from the plan alone (see
    /// `SkippedMutation.operatorID`).
    @Test("candidatesPerOperator counts every eligible point, selected or not")
    func candidatesPerOperatorCountsEverything() {
        let points = Self.skewedPoints()

        let selection = BudgetSelector.selectByOperatorSubtype(
            points, limit: 6, seed: 42, minimumPerOperator: 1
        )

        #expect(selection.candidatesPerOperator["swift.core.relational-operator-replacement"] == 20)
        #expect(selection.candidatesPerOperator["swift.core.ternary-branch-swap"] == 3)
        #expect(selection.candidatesPerOperator["swift.core.unary-not-removal"] == 1)
    }

    /// Selected and dropped together partition the input exactly, same
    /// invariant as proportional `select`.
    @Test("Selected and dropped partition the input")
    func selectionPartitionsInput() {
        let points = Self.skewedPoints()

        let selection = BudgetSelector.selectByOperatorSubtype(
            points, limit: 8, seed: 42, minimumPerOperator: 1
        )

        let selectedSet = Set(selection.selected.map(\.id))
        let droppedSet = Set(selection.dropped.map(\.id))
        #expect(selectedSet.isDisjoint(with: droppedSet))
        #expect(selectedSet.union(droppedSet).count == points.count)
    }

    /// Selected and dropped are sorted by ID, same as proportional `select` —
    /// required for a byte-stable plan.
    @Test("Selected and dropped are returned sorted by ID")
    func selectionIsSortedByID() {
        let points = Self.skewedPoints()

        let selection = BudgetSelector.selectByOperatorSubtype(
            points, limit: 8, seed: 42, minimumPerOperator: 1
        )

        #expect(selection.selected.map(\.id) == selection.selected.map(\.id).sorted())
        #expect(selection.dropped.map(\.id) == selection.dropped.map(\.id).sorted())
    }

    /// A limit at or above the total candidate count keeps everything —
    /// balancing has nothing to ration.
    @Test("A limit covering every candidate keeps everything")
    func limitCoveringEverythingKeepsAll() {
        let points = Self.skewedPoints()

        let selection = BudgetSelector.selectByOperatorSubtype(
            points, limit: 100, seed: 42, minimumPerOperator: 1
        )

        #expect(selection.selected.count == points.count)
        #expect(selection.dropped.isEmpty)
    }

    /// Regression: a budget too small to cover every operator's
    /// `minimumPerOperator > 1` must still give each eligible operator *one*
    /// slot before any operator gets a second — not hand the entire budget to
    /// whichever operator sorts first.
    @Test("A budget too small for every minimum still spreads one-per-operator before any second")
    func scarceBudgetWithHighMinimumStillSpreadsOnePerOperator() {
        let points = Self.skewedPoints()

        let selection = BudgetSelector.selectByOperatorSubtype(
            points, limit: 3, seed: 42, minimumPerOperator: 5
        )

        #expect(selection.selected.count == 3)
        #expect(selection.assignedPerOperator["swift.core.relational-operator-replacement"] == 1)
        #expect(selection.assignedPerOperator["swift.core.ternary-branch-swap"] == 1)
        #expect(selection.assignedPerOperator["swift.core.unary-not-removal"] == 1)
    }
}
