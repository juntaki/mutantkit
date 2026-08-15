import Foundation
import MutationModel
import Testing

/// The plan is the single source of truth for a run: it shards, resumes and
/// reproduces without any live process state. All of that rests on the file
/// being deterministic and on the tool refusing one it does not understand.
@Suite("Mutation plan")
struct MutationPlanTests {
    private func realisticPlan() throws -> MutationPlan {
        let source = try Fixture.text("RealisticViewModel")
        let path = "Sources/CartViewModel.swift"
        let points = try discover(source, path: path)

        return makePlan(
            mutations: points,
            skipped: [SkippedMutation(
                id: points[0].id,
                file: path,
                reason: .budgetExceeded,
                detail: "over the per-run cap"
            )],
            sourceFileHashes: [path: ContentHash.of(Data(source.utf8))]
        )
    }

    /// CI diffs and caches this file. Identical input has to produce identical
    /// bytes, or every run looks like a change.
    @Test("Encoding is deterministic across a decode round trip")
    func encodingIsByteIdentical() throws {
        let plan = try realisticPlan()

        let first = try plan.encoded()
        let decoded = try MutationPlan.decode(from: first)
        let second = try decoded.encoded()

        #expect(first == second)
        #expect(try decoded.encoded() == second, "encoding must also be idempotent")
    }

    @Test("Encoding the same plan twice produces the same bytes")
    func encodingIsStable() throws {
        let plan = try realisticPlan()

        #expect(try plan.encoded() == plan.encoded())
    }

    /// ADR-0007 invariant 8/B.8: a v1 plan (no `budgetInclusionReasons`) must
    /// encode byte-identically to how it always has. A synthesized encoder
    /// would emit `"budgetInclusionReasons": []` for every plan since the
    /// field was added — a Codex integration review caught this as a High
    /// (breaks the "existing configs produce byte-identical plans"
    /// guarantee) — so the key must be omitted entirely when empty, not
    /// present-but-empty.
    @Test("A v1 plan (no budgetInclusionReasons) omits the key entirely, not [] ")
    func v1PlanOmitsBudgetInclusionReasonsKey() throws {
        let plan = try realisticPlan()
        #expect(plan.budgetInclusionReasons.isEmpty)

        let json = try String(data: plan.encoded(), encoding: .utf8)
        #expect(json?.contains("budgetInclusionReasons") == false)
    }

    /// The symmetric case: a v2 plan's non-empty reasons are present and
    /// round-trip through decode/re-encode unchanged.
    @Test("A v2 plan's budgetInclusionReasons round-trips through decode/re-encode")
    func v2PlanRoundTripsBudgetInclusionReasons() throws {
        let source = try Fixture.text("RealisticViewModel")
        let path = "Sources/CartViewModel.swift"
        let points = try discover(source, path: path)
        let reason = InclusionReason(
            mutationID: points[0].id,
            reasonCode: .minimumReservation,
            stratumPath: [points[0].operatorID],
            selectionOrdinal: 0
        )
        let plan = MutationPlan(
            planID: "plan_test",
            createdAt: Date(timeIntervalSince1970: 0),
            projectRoot: "/tmp",
            toolchain: ToolchainFingerprint(
                toolVersion: "0.1.0", toolCommitSHA: nil, swiftVersion: "6.3.3",
                swiftSyntaxVersion: "603.0.2", xcodeVersion: nil
            ),
            configurationHash: "cfg",
            sourceFileHashes: [path: ContentHash.of(Data(source.utf8))],
            mutations: [points[0]],
            skipped: [],
            operators: [],
            budgetInclusionReasons: [reason]
        )

        let decoded = try MutationPlan.decode(from: try plan.encoded())
        #expect(decoded.budgetInclusionReasons == [reason])
    }

    @Test("A decoded plan carries the same mutations")
    func decodePreservesMutations() throws {
        let plan = try realisticPlan()

        let decoded = try MutationPlan.decode(from: try plan.encoded())

        #expect(decoded.mutations == plan.mutations)
        #expect(decoded.planID == plan.planID)
        #expect(decoded.configurationHash == plan.configurationHash)
        #expect(decoded.skipped == plan.skipped)
        #expect(decoded.sourceFileHashes == plan.sourceFileHashes)
        #expect(decoded.discoveredCount == plan.discoveredCount)
    }

    /// Execution order has to be deterministic without a seed, and sorting by ID
    /// is what makes it so.
    @Test("Mutations are stored sorted by ID regardless of input order")
    func mutationsAreSorted() throws {
        let points = try discover(try Fixture.text("RealisticViewModel"), path: "Sources/CartViewModel.swift")

        let forward = makePlan(mutations: points)
        let reversed = makePlan(mutations: points.reversed())

        #expect(forward.mutations.map(\.id) == forward.mutations.map(\.id).sorted())
        #expect(forward.mutations == reversed.mutations)
        #expect(try forward.encoded() == reversed.encoded())
    }

    /// Catching a hand-edited or foreign ID here — rather than after an hour of
    /// builds — is the whole point of making IDs recomputable from content.
    @Test("A plan with a tampered ID is rejected")
    func tamperedIDIsRejected() throws {
        let point = try makeAnchoredPoint()
        let tampered = point.with(id: MutationID(rawValue: "mut_0000000000000000"))
        let plan = makePlan(mutations: [tampered])

        let violations = IntegrityChecker.validatePlan(plan)

        #expect(violations.kinds == [.unstableMutationID])
        #expect(violations.first?.mutationID == tampered.id)
        #expect(tampered.recomputedID != tampered.id)
    }

    /// An ID that no longer matches its own components means the components were
    /// edited, not just the ID — so the mutation the plan names is not the
    /// mutation it describes.
    @Test("A plan whose components were edited under a valid ID is rejected")
    func editedComponentsAreRejected() throws {
        let point = try makeAnchoredPoint()
        let renumbered = point.with(occurrenceIndex: 7)
        let plan = makePlan(mutations: [renumbered])

        #expect(IntegrityChecker.validatePlan(plan).kinds == [.unstableMutationID])
    }

    /// `IntegrityChecker.check`/`CheckpointStore.loadAll` both index
    /// `plan.mutations` by ID — decode is the one place every caller
    /// already passes through to get a plan from disk, so a duplicate ID
    /// belongs here, not left to trap whichever of those runs first.
    @Test("A plan with a duplicate mutation ID is rejected at decode, not left to trap downstream")
    func duplicateIDIsRejectedAtDecode() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point, point])

        #expect(throws: PlanError.self) {
            _ = try MutationPlan.decode(from: try plan.encoded())
        }
    }

    @Test("A plan with a tampered ID is rejected at decode too")
    func tamperedIDIsRejectedAtDecode() throws {
        let point = try makeAnchoredPoint()
        let tampered = point.with(id: MutationID(rawValue: "mut_0000000000000000"))
        let plan = makePlan(mutations: [tampered])

        #expect(throws: PlanError.self) {
            _ = try MutationPlan.decode(from: try plan.encoded())
        }
    }

    @Test("An untouched plan validates")
    func untouchedPlanValidates() throws {
        #expect(IntegrityChecker.validatePlan(try realisticPlan()).isEmpty)
    }

    /// A reader that does not recognise a version must refuse the file rather
    /// than guess at its shape.
    @Test("An unsupported schema version is rejected")
    func unsupportedSchemaVersionIsRejected() throws {
        let plan = try realisticPlan()
        var object = try #require(
            try JSONSerialization.jsonObject(with: plan.encoded()) as? [String: Any]
        )
        object["schemaVersion"] = SchemaVersion.plan + 1
        let future = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: PlanError.self) {
            try MutationPlan.decode(from: future)
        }

        do {
            _ = try MutationPlan.decode(from: future)
            Issue.record("expected the plan to be refused")
        } catch let error as PlanError {
            guard case let .unsupportedSchemaVersion(found, expected) = error else {
                Issue.record("expected an unsupportedSchemaVersion error, got \(error)")
                return
            }
            #expect(found == SchemaVersion.plan + 1)
            #expect(expected == SchemaVersion.plan)
        }
    }

    @Test("A plan written by this tool declares the current schema version")
    func planDeclaresCurrentSchemaVersion() throws {
        #expect(try realisticPlan().schemaVersion == SchemaVersion.plan)
    }

    @Test("Discovered count includes skipped mutations")
    func discoveredCountIncludesSkipped() throws {
        let plan = try realisticPlan()

        #expect(plan.discoveredCount == plan.mutations.count + plan.skipped.count)
        #expect(plan.skipped.count == 1)
    }
}
