import Foundation
import MutationModel
import MutationPlanner
import Testing

/// The planner is where every gate — confidence, diff, budget — meets, and
/// where the `discovered == mutations + skipped` invariant has to hold exactly.
/// A regression in any one gate shows up here as a mutant that silently
/// vanishes, which is the failure mode the integrity checker exists to refuse.
@Suite("Mutation planner")
struct MutationPlannerEndToEndTests {
    private let root: URL = Self.makeRoot()
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0",
        toolCommitSHA: nil,
        swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2",
        xcodeVersion: nil
    )

    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-planner-\(UUID().uuidString)")
    }

    private func write(_ relativePath: String, _ source: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(source.utf8).write(to: url)
    }

    private func makePlan(
        configuration: Configuration = Configuration(),
        diffScope: DiffScope? = nil
    ) async throws -> MutationPlan {
        try await MutationPlanner().makePlan(
            configuration: configuration,
            projectRoot: root,
            toolchain: toolchain,
            diffScope: diffScope
        )
    }

    // MARK: - The `discovered == mutations + skipped` invariant

    /// The integrity checker enforces `discovered == mutations + skipped`. The
    /// planner has to actually produce input that satisfies it: every dropped
    /// mutation leaves at exactly one gate, and lands in `skipped` with that
    /// gate's reason.
    @Test("discovered equals mutations plus skipped, regardless of which gates fire")
    func discoveredReconcilesWithMutationsAndSkipped() async throws {
        try write("Sources/A.swift", """
        struct A {
            var enabled = true
            var disabled = false
            func check() -> Bool { return enabled }
        }
        """)

        try write("Sources/B.swift", """
        struct B {
            var enabled = true
            var isReady = false
            var visible = true
        }
        """)

        // A budget drops some, the diff drops more, and confidence drops none
        // (BoolLiteralInversion is `.high`). Every gate has the chance to fire.
        let diffScope = DiffScope(changedLines: ["Sources/A.swift": [1 ..< 10]])
        let configuration = Configuration(
            execution: ExecutionSettings(budget: BudgetSettings(maxMutants: 1, seed: 7))
        )

        let plan = try await makePlan(configuration: configuration, diffScope: diffScope)

        #expect(plan.discoveredCount == plan.mutations.count + plan.skipped.count)
        #expect(plan.mutations.count == 1)
        // The diff drops every B.swift mutant; the budget drops the rest of A.
        let reasons = Dictionary(grouping: plan.skipped, by: \.reason)
            .mapValues { $0.count }
        #expect(reasons[.outsideDiff] != nil)
        #expect(reasons[.budgetExceeded] != nil)
        // No mutation in B should have survived — they are all outside the diff.
        #expect(plan.mutations.allSatisfy { $0.file == "Sources/A.swift" })
    }

    @Test("A clean plan has no skipped mutations")
    func cleanPlanHasNoSkipped() async throws {
        try write("Sources/A.swift", """
        struct A { var enabled = true }
        """)

        let plan = try await makePlan()

        #expect(plan.skipped.isEmpty)
        #expect(plan.discoveredCount == plan.mutations.count)
        #expect(plan.integrityPassesValidation)
    }

    // MARK: - ID stability across re-runs

    /// Re-planning the same tree with the same config has to produce the same
    /// `planID` and the same set of mutation IDs. This is what lets a cache, a
    /// resume, or a sharded run recognise each other.
    @Test("Re-planning an unchanged tree produces the same plan ID")
    func replanningIsStable() async throws {
        try write("Sources/Cart.swift", """
        struct Cart {
            var enabled = true
            var visible = false
            var ready = true
        }
        """)

        let first = try await makePlan()
        let second = try await makePlan()

        #expect(first.planID == second.planID)
        #expect(first.mutations.map(\.id) == second.mutations.map(\.id))
        #expect(first.configurationHash == second.configurationHash)
        #expect(first.sourceFileHashes == second.sourceFileHashes)
    }

    /// Editing an unrelated file must not change the mutation IDs in the files
    /// that did not change. The ID is content-derived: same file, same
    /// declaration, same operator, same text → same ID, even when a new file is
    /// added or another file is edited.
    @Test("Mutation IDs are stable when other files change")
    func idsAreStableAcrossFiles() async throws {
        try write("Sources/Stable.swift", """
        struct Stable { var enabled = true }
        """)

        let first = try await makePlan()
        let stableIDs = first.mutations.map(\.id)

        // Add a new file and re-plan. The stable file's mutations must keep
        // their IDs — IDs are not global counters, so a new file is invisible
        // to a stable one's identity.
        try write("Sources/New.swift", """
        struct New { var enabled = true }
        """)

        let second = try await makePlan()

        let stableIDSet = Set(stableIDs)
        let survivingInSecond = second.mutations
            .filter { stableIDSet.contains($0.id) }
            .map(\.id)
        #expect(survivingInSecond == stableIDs)
    }

    /// Discovery parses files concurrently, but the IDs in the plan must be
    /// identical to a serial discovery's. The same is true of the mutations
    /// array's order — completion order must not leak in.
    @Test("Mutation IDs do not depend on parallel completion order")
    func idsDoNotDependOnCompletionOrder() async throws {
        // Enough files to give the task group real parallelism.
        for index in 0 ..< 12 {
            try write("Sources/File\(index).swift", """
            struct File\(index) {
                var enabled = true
                var visible = false
                var ready = true
            }
            """)
        }

        // Three independent plans. The IDs and the order have to match exactly
        // across runs — file completion order is non-deterministic, but the
        // plan is sorted by ID, so the run is the same every time.
        let planA = try await makePlan()
        let planB = try await makePlan()
        let planC = try await makePlan()

        #expect(planA.mutations.map(\.id) == planB.mutations.map(\.id))
        #expect(planA.mutations.map(\.id) == planC.mutations.map(\.id))
        #expect(planA.mutations.map(\.id) == planA.mutations.map(\.id).sorted())
        #expect(planA.planID == planB.planID)
    }

    // MARK: - Determinism across machine shape

    /// The plan does not depend on the machine's core count, even though
    /// discovery parallelism is bounded by `ProcessInfo.activeProcessorCount`.
    /// A plan that changed shape between a 4-core laptop and a 16-core CI
    /// runner would silently break every cache and every shard.
    @Test("A plan is independent of how many cores discovered it")
    func planDoesNotVaryWithCores() async throws {
        try write("Sources/Cart.swift", """
        struct Cart {
            var enabled = true
            func check() -> Bool { return enabled }
        }
        """)

        // The planner bounds the task group to `ProcessInfo.activeProcessorCount`.
        // We can't change that value from a test, but we can run the planner
        // repeatedly and assert the plan is identical across runs — the only way a
        // core-count-dependent plan would reveal itself here.
        // Excluded from the comparison: `createdAt` and the derived `planID`
        // (which includes `createdAt` indirectly through the plan structure),
        // because they are time-dependent by design.
        let first = try await makePlan()
        let second = try await makePlan()

        #expect(first.mutations.map(\.id) == second.mutations.map(\.id))
        #expect(first.configurationHash == second.configurationHash)
        #expect(first.sourceFileHashes == second.sourceFileHashes)
        #expect(first.discoveredCount == second.discoveredCount)
        #expect(first.planID == second.planID)
    }

    // MARK: - Diff gate integration

    /// A diff scope narrows the plan to in-scope files and records every
    /// out-of-scope mutant as `.outsideDiff`. The skipped record's file must
    /// point at the file the mutant was in, not the diff's file.
    @Test("The diff gate records every dropped mutant as outsideDiff")
    func diffGateRecordsOutsideDiff() async throws {
        try write("Sources/Foo.swift", """
        struct Foo {
            var enabled = true
            var visible = false
        }
        """)

        try write("Sources/Bar.swift", """
        struct Bar {
            var enabled = true
        }
        """)

        let scope = DiffScope(changedLines: ["Sources/Foo.swift": [1 ..< 10]])
        let plan = try await makePlan(diffScope: scope)

        #expect(plan.mutations.allSatisfy { $0.file == "Sources/Foo.swift" })
        // Every Bar mutant is in `skipped` with `.outsideDiff`, not vanished.
        let droppedFromBar = plan.skipped.filter { $0.file == "Sources/Bar.swift" }
        #expect(!droppedFromBar.isEmpty)
        #expect(droppedFromBar.allSatisfy { $0.reason == .outsideDiff })
    }

    /// A diff base in configuration without a scope supplied is refused. The
    /// alternative — silently planning the whole project — would be a far
    /// larger run than the one the user asked for, and the user would only find
    /// out from the bill.
    @Test("A diff base without a scope is refused, not silently widened")
    func diffBaseWithoutScopeIsRefused() async throws {
        try write("Sources/Foo.swift", "struct Foo { var enabled = true }")

        let configuration = Configuration(
            execution: ExecutionSettings(diffBase: "origin/main")
        )

        await #expect(throws: PlannerError.self) {
            try await makePlan(configuration: configuration, diffScope: nil)
        }
    }

    // MARK: - Budget gate integration

    @Test("The budget gate drops mutants as budgetExceeded")
    func budgetGateDropsAsBudgetExceeded() async throws {
        try write("Sources/Big.swift", """
        struct Big {
            var a = true
            var b = true
            var c = true
            var d = true
            var e = true
        }
        """)

        let configuration = Configuration(
            execution: ExecutionSettings(budget: BudgetSettings(maxMutants: 2, seed: nil))
        )
        let plan = try await makePlan(configuration: configuration)

        #expect(plan.mutations.count == 2)
        #expect(plan.skipped.allSatisfy { $0.reason == .budgetExceeded })
        #expect(plan.skipped.count == plan.discoveredCount - 2)
    }

    /// The budget's seed is what makes a budgeted plan reproducible. Two runs
    /// with the same seed have to pick the same mutants.
    @Test("A seeded budget reproduces across runs")
    func seededBudgetReproduces() async throws {
        try write("Sources/Big.swift", """
        struct Big {
            var a = true
            var b = true
            var c = true
            var d = true
            var e = true
            var f = true
            var g = true
            var h = true
        }
        """)

        let configuration = Configuration(
            execution: ExecutionSettings(budget: BudgetSettings(maxMutants: 3, seed: 1234))
        )

        let first = try await makePlan(configuration: configuration)
        let second = try await makePlan(configuration: configuration)

        #expect(first.mutations.map(\.id) == second.mutations.map(\.id))
        #expect(first.planID == second.planID)
    }

    // MARK: - Budget Selection v2 (ADR-0007, opt-in)

    /// `selection: v2` reaches `BudgetSelectorV2` end to end: the plan is
    /// budget-limited exactly like v1, and — the capability v1 never had —
    /// every selected mutant carries a `budgetInclusionReasons` record
    /// (ADR-0007 B.7).
    @Test("selection: v2 budget-limits the plan and records an InclusionReason for every selected mutant")
    func budgetSelectionV2ProducesInclusionReasons() async throws {
        try write("Sources/Big.swift", """
        struct Big {
            var a = true
            var b = true
            var c = true
            var d = true
            var e = true
        }
        """)

        let configuration = Configuration(
            execution: ExecutionSettings(budget: BudgetSettings(maxMutants: 2, selection: .v2))
        )
        let plan = try await makePlan(configuration: configuration)

        #expect(plan.mutations.count == 2)
        #expect(plan.skipped.allSatisfy { $0.reason == .budgetExceeded })
        #expect(Set(plan.budgetInclusionReasons.map(\.mutationID)) == Set(plan.mutations.map(\.id)))
        #expect(plan.budgetInclusionReasons.count == plan.mutations.count)
    }

    /// v1 never populates `budgetInclusionReasons` — the field exists on
    /// every plan, but stays empty unless `selection: v2` was actually used
    /// (ADR-0007 B.8: v2 is opt-in, v1 unaffected).
    @Test("Under v1 (the default), budgetInclusionReasons stays empty")
    func budgetInclusionReasonsEmptyUnderV1() async throws {
        try write("Sources/Big.swift", "struct Big { var a = true; var b = true; var c = true }")

        let configuration = Configuration(
            execution: ExecutionSettings(budget: BudgetSettings(maxMutants: 1))
        )
        let plan = try await makePlan(configuration: configuration)

        #expect(plan.budgetInclusionReasons.isEmpty)
    }

    /// A duplicate `MutationID` is a precondition violation `BudgetSelectorV2`
    /// itself refuses (ADR-0007 invariant 4) — `applyBudgetGate` must surface
    /// that refusal as a `PlannerError`, not let it escape unwrapped or, worse,
    /// silently succeed.
    @Test("selection: v2 surfaces BudgetSelectorV2's own errors as PlannerError")
    func budgetSelectionV2InvalidWeightSurfacesAsPlannerError() async throws {
        try write("Sources/Big.swift", "struct Big { var a = true; var b = true }")

        let configuration = Configuration(
            execution: ExecutionSettings(budget: BudgetSettings(
                maxMutants: 1, selection: .v2, weight: ["nonexistentOperator": 1]
            ))
        )

        await #expect(throws: PlannerError.self) {
            try await makePlan(configuration: configuration)
        }
    }

    /// A budget of zero is impossible to honour: it asks the planner to plan
    /// nothing while pretending to plan something. Refused, not silently empty.
    @Test("A zero budget is refused")
    func zeroBudgetIsRefused() async throws {
        try write("Sources/Foo.swift", "struct Foo { var enabled = true }")

        let configuration = Configuration(
            execution: ExecutionSettings(budget: BudgetSettings(maxMutants: 0))
        )

        await #expect(throws: PlannerError.self) {
            try await makePlan(configuration: configuration)
        }
    }

    /// Full wiring, config to plan: `stratifyBy: .operatorSubtype` reaches
    /// `BudgetSelector.selectByOperatorSubtype` and every enabled operator
    /// with a candidate in this file — bool-literal-inversion (`true`) and
    /// relational-operator-replacement (`>`) — shows up in the plan, not just
    /// whichever one a proportional round-robin would have favored.
    @Test("operatorSubtype sampling reaches every operator with a candidate")
    func operatorSubtypeReachesEveryOperator() async throws {
        try write("Sources/Mixed.swift", """
        struct Mixed {
            var flag = true
            func compare(_ a: Int, _ b: Int) -> Bool { a > b }
        }
        """)

        let configuration = Configuration(
            execution: ExecutionSettings(
                budget: BudgetSettings(maxMutants: 2, seed: 42, stratifyBy: .operatorSubtype)
            )
        )
        let plan = try await makePlan(configuration: configuration)

        let selectedOperators = Set(plan.mutations.map(\.operatorID))
        #expect(selectedOperators.count == 2, "\(selectedOperators)")
        #expect(plan.skipped.allSatisfy { $0.reason == .budgetExceeded })
        #expect(plan.skipped.allSatisfy { $0.operatorID != nil })
    }

    // MARK: - Integrity validation

    /// The planner validates the plan it just built. If a future edit breaks an
    /// invariant — unstable IDs, duplicate IDs — the planner is the first to
    /// see it, and refusing the plan here costs milliseconds rather than an
    /// hour of builds.
    @Test("A plan the planner emits passes its own integrity check")
    func emittedPlanPassesIntegrity() async throws {
        try write("Sources/Foo.swift", """
        struct Foo {
            var enabled = true
            var ready = false
        }
        """)

        let plan = try await makePlan()

        #expect(IntegrityChecker.validatePlan(plan).isEmpty)
        #expect(plan.integrityPassesValidation)
    }

    // MARK: - Empty input

    @Test("An empty project yields an empty plan, not an error")
    func emptyProjectIsEmptyPlan() async throws {
        // Create the root directory but put no Swift files in it.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )

        let plan = try await makePlan()

        #expect(plan.mutations.isEmpty)
        #expect(plan.skipped.isEmpty)
        #expect(plan.discoveredCount == 0)
    }
}

private extension MutationPlan {
    /// A boolean view of the integrity checker's verdict, for tests that want
    /// to assert "the plan was valid" rather than restate the check.
    var integrityPassesValidation: Bool {
        IntegrityChecker.validatePlan(self).isEmpty
    }
}
