import Foundation
import MutationModel
import Reporting
import Testing

@Suite("TestObligationAnalyzer")
struct TestObligationAnalyzerTests {
    // MARK: - Per-operator obligation derivation, against REAL discovered text

    /// `RelationalOperatorReplacementOperator` emits both a boundary and a
    /// negation candidate for `>` (see that type's own `Visitor.visit`) —
    /// `MutationDiscovery.finalize`'s own final sort (byte offset, operator
    /// ID, then replacement text) does not preserve emission order between
    /// two same-site candidates, so the boundary one is found by its real
    /// replacement text (`>=`) rather than by position.
    @Test("Relational boundary (>) is classified relationalBoundary, high confidence")
    func relationalBoundaryWidened() throws {
        let points = try discover(
            "struct Example { func check(x: Int) -> Bool { x > 10 } }", using: Operators.relational
        )
        #expect(points.count == 2, "> has both a boundary and a negation form")
        let boundary = try #require(points.first { $0.replacementText == ">=" })
        #expect(boundary.originalText == ">")

        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: boundary.operatorID, originalText: boundary.originalText, replacementText: boundary.replacementText
        )
        #expect(obligation.kind == .relationalBoundary)
        #expect(obligation.confidence == .high)
        #expect(obligation.description.contains(">"))
        #expect(obligation.description.contains(">="))
        #expect(obligation.description.lowercased().contains("widened"))
    }

    @Test("Relational boundary (<=) is classified relationalBoundary and narrowed")
    func relationalBoundaryNarrowed() throws {
        let points = try discover(
            "struct Example { func check(x: Int) -> Bool { x <= 10 } }", using: Operators.relational
        )
        let boundary = try #require(points.first { $0.replacementText == "<" })
        #expect(boundary.originalText == "<=")

        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .fullSuite),
            operatorID: boundary.operatorID, originalText: boundary.originalText, replacementText: boundary.replacementText
        )
        #expect(obligation.kind == .relationalBoundary)
        #expect(obligation.confidence == .high)
        #expect(obligation.description.lowercased().contains("narrowed"))
    }

    /// Medium, not high: unlike the boundary form, an ordering negation
    /// pair (`<`⇄`>=`) is an exact complement only for a genuine total
    /// order -- Swift's floating-point types deviate from that for `NaN`
    /// (both `x < 10` and `x >= 10` are `false` when `x` is `.nan`), and
    /// whether the compared operand is such a type is not visible from the
    /// two bare operator tokens alone. See `relationalObligation`'s own
    /// doc comment for the full derivation.
    @Test("Relational negation (ordering) is classified relationalNegation, medium confidence")
    func relationalNegation() throws {
        let points = try discover(
            "struct Example { func check(x: Int) -> Bool { x > 10 } }", using: Operators.relational
        )
        let negation = try #require(points.first { $0.replacementText == "<=" })
        #expect(negation.originalText == ">")

        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: negation.operatorID, originalText: negation.originalText, replacementText: negation.replacementText
        )
        #expect(obligation.kind == .relationalNegation)
        #expect(obligation.confidence == .medium)
        #expect(obligation.description.contains("reversed"))
    }

    /// `==`/`!=` have no boundary form (`RelationalOperatorReplacementOperator
    /// .replacements["=="] == (nil, "!=")`) — exactly one candidate, negation
    /// only. Unlike the ordering pairs, `==`/`!=` stays high confidence: `!=`
    /// is defined as the unconditional Boolean negation of `==` for every
    /// `Equatable` conformance, `NaN` included, so there is no type-dependent
    /// exception to hedge against.
    @Test("Equality replacement has no boundary form -- only negation, and stays high confidence")
    func equalityHasNoBoundaryForm() throws {
        let points = try discover(
            "struct Example { func check(x: Int) -> Bool { x == 10 } }", using: Operators.relational
        )
        #expect(points.count == 1)
        #expect(points[0].originalText == "==")
        #expect(points[0].replacementText == "!=")

        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: points[0].operatorID, originalText: points[0].originalText, replacementText: points[0].replacementText
        )
        #expect(obligation.kind == .relationalNegation)
        #expect(obligation.confidence == .high)
    }

    @Test("Logical connector swap is classified logicalConnectorCombination, high confidence")
    func logicalConnectorSwap() throws {
        let points = try discover(
            "struct Example { func check(a: Bool, b: Bool) -> Bool { a && b } }", using: Operators.logicalConnector
        )
        #expect(points.count == 1)
        #expect(points[0].originalText == "&&")
        #expect(points[0].replacementText == "||")

        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: points[0].operatorID, originalText: points[0].originalText, replacementText: points[0].replacementText
        )
        #expect(obligation.kind == .logicalConnectorCombination)
        #expect(obligation.confidence == .high)
        #expect(obligation.description.contains("&&"))
        #expect(obligation.description.contains("||"))
    }

    /// Medium, not high: whether the swapped branches actually produce a
    /// different runtime value is a fact about those two expressions, not
    /// something the swap operation itself proves -- see `ternaryObligation`'s
    /// own doc comment.
    @Test("Ternary branch swap (branches differ) is classified ternaryBranchObservation, medium confidence")
    func ternaryBranchSwap() throws {
        let points = try discover(
            "struct Example { func pick(flag: Bool) -> Int { flag ? 1 : 2 } }", using: Operators.ternaryBranchSwap
        )
        #expect(points.count == 1)
        #expect(points[0].originalText == "flag ? 1 : 2")
        #expect(points[0].replacementText == "flag ? 2 : 1")

        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: points[0].operatorID, originalText: points[0].originalText, replacementText: points[0].replacementText
        )
        #expect(obligation.kind == .ternaryBranchObservation)
        #expect(obligation.confidence == .medium)
    }

    /// `TernaryBranchSwapOperator` has no check that its two branches
    /// differ (unlike `ReturnValueReplacementOperator`'s own
    /// skip-if-already-neutral check for its own candidates) -- a ternary
    /// whose branches are literally identical text produces a same-text
    /// "swap" that is a genuine equivalent mutant, provable directly from
    /// `original == replacement` with no operand semantics needed, hence
    /// high confidence for a very different claim ("unkillable", not "add
    /// an assertion").
    @Test("Ternary branch swap (identical branches) is classified ternaryBranchObservation, high confidence, as an equivalent mutant")
    func ternaryBranchSwapIdenticalBranches() {
        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: "swift.core.ternary-branch-swap", originalText: "flag ? x : x", replacementText: "flag ? x : x"
        )
        #expect(obligation.kind == .ternaryBranchObservation)
        #expect(obligation.confidence == .high)
        #expect(obligation.description.lowercased().contains("equivalent"))
    }

    @Test("Unary not removal is classified unaryNotPolarity, high confidence")
    func unaryNotRemoval() throws {
        let points = try discover(
            "struct Example { func check(flag: Bool) -> Bool { !flag } }", using: Operators.unaryNotRemoval
        )
        #expect(points.count == 1)
        #expect(points[0].originalText == "!flag")
        #expect(points[0].replacementText == "flag")

        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: points[0].operatorID, originalText: points[0].originalText, replacementText: points[0].replacementText
        )
        #expect(obligation.kind == .unaryNotPolarity)
        #expect(obligation.confidence == .high)
    }

    @Test("Bool literal inversion is classified boolLiteralValue, high confidence")
    func boolLiteralInversion() throws {
        let points = try discover(
            "struct Example { func isReady() -> Bool { true } }", using: Operators.boolLiteral
        )
        #expect(points.count == 1)
        #expect(points[0].originalText == "true")
        #expect(points[0].replacementText == "false")

        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: points[0].operatorID, originalText: points[0].originalText, replacementText: points[0].replacementText
        )
        #expect(obligation.kind == .boolLiteralValue)
        #expect(obligation.confidence == .high)
    }

    @Test("Return value replacement (literal neutral default) is classified returnValueAssertion, medium confidence")
    func returnValueReplacementLiteral() throws {
        let points = try discover(
            "struct Example { func value() -> Int { return 42 } }", using: Operators.returnValueReplacement
        )
        #expect(points.count == 1)
        #expect(points[0].originalText == "42")
        #expect(points[0].replacementText == "0")

        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: points[0].operatorID, originalText: points[0].originalText, replacementText: points[0].replacementText
        )
        #expect(obligation.kind == .returnValueAssertion)
        #expect(obligation.confidence == .medium, "one hop from the mutation site (the caller) -- ranks below the condition operators")
    }

    @Test("Return value replacement (Optional -> nil) is also classified returnValueAssertion")
    func returnValueReplacementOptional() throws {
        let points = try discover(
            "struct Example { func find() -> Int? { return 42 } }", using: Operators.returnValueReplacement
        )
        #expect(points.count == 1)
        #expect(points[0].originalText == "42")
        #expect(points[0].replacementText == "nil")

        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: points[0].operatorID, originalText: points[0].originalText, replacementText: points[0].replacementText
        )
        #expect(obligation.kind == .returnValueAssertion)
        #expect(obligation.confidence == .medium)
    }

    // MARK: - noCoverage always wins, regardless of operator

    @Test("mutationSiteNotCovered always produces .reachability, regardless of which operator produced the mutant")
    func noCoverageOverridesOperator() throws {
        let points = try discover(
            "struct Example { func check(x: Int) -> Bool { x > 10 } }", using: Operators.relational
        )
        let obligation = TestObligationAnalyzer.obligation(
            reason: .mutationSiteNotCovered,
            operatorID: points[0].operatorID, originalText: points[0].originalText, replacementText: points[0].replacementText
        )
        #expect(obligation.kind == .reachability)
        #expect(obligation.confidence == .high)
        #expect(obligation.description.lowercased().contains("not reached"))
    }

    // MARK: - Honest fallback for anything not modeled

    /// Grounded in `ArithmeticOperatorReplacementOperator`'s own real,
    /// fixed `replacements` table (`"+": "-"`) — a real operator ID and a
    /// real replacement pair it would actually produce, just one this
    /// analyzer has not modeled (it is not a default-profile operator).
    @Test("An operator this analyzer has not modeled falls back to .unmodeledOperator, low confidence")
    func unmodeledOperatorFallsBack() {
        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: "swift.core.arithmetic-operator-replacement", originalText: "+", replacementText: "-"
        )
        #expect(obligation.kind == .unmodeledOperator)
        #expect(obligation.confidence == .low)
        #expect(obligation.description.contains("+"))
        #expect(obligation.description.contains("-"))
    }

    /// A hand-edited or corrupted report could carry an (original,
    /// replacement) pair that does not match `RelationalOperatorReplacementOperator`'s
    /// own real table at all -- the classifier must fall back honestly
    /// rather than misclassify.
    @Test("An unrecognized relational pair falls back to .unmodeledOperator rather than guessing")
    func relationalUnrecognizedPairFallsBack() {
        let obligation = TestObligationAnalyzer.obligation(
            reason: .coveredButNotCaught(testScope: .unknown),
            operatorID: "swift.core.relational-operator-replacement", originalText: "<", replacementText: "<<"
        )
        #expect(obligation.kind == .unmodeledOperator)
        #expect(obligation.confidence == .low)
    }

    // MARK: - Confidence ordering

    @Test("Confidence is ordered high > medium > low")
    func confidenceOrdering() {
        #expect(TestObligation.Confidence.high > .medium)
        #expect(TestObligation.Confidence.medium > .low)
        #expect(TestObligation.Confidence.high > .low)
    }

    // MARK: - buildFixPlan: report-wide wiring

    @Test("buildFixPlan produces one entry per survivor, with real facts and a working reproduce command")
    func buildFixPlanWiring() throws {
        let points = try discover(
            "struct Example { func check(x: Int) -> Bool { x > 10 } }", using: Operators.relational
        )
        #expect(points.count == 2)
        let results = points.map { makeResult(point: $0, outcome: .survived, evidence: nil) }
        let report = makeReport(plan: makePlan(mutations: points), results: results)

        let entries = TestObligationAnalyzer.buildFixPlan(from: report)
        #expect(entries.count == 2)

        for entry in entries {
            #expect(entry.reproduceCommand == "mutantkit reproduce \(entry.facts.mutantID)")
            #expect(entry.facts.outcome == .survived)
            #expect(entry.facts.clusterSize == entries.count, "both mutants share the declaration and (unknown) test scope -- one cluster")
            #expect(!entry.obligation.description.isEmpty)
        }

        let kinds = Set(entries.map(\.inference.gapKind))
        #expect(kinds == [.relationalBoundary, .relationalNegation])
    }

    @Test("buildFixPlan reports .reachability for a noCoverage mutant even though the operator would otherwise be modeled")
    func buildFixPlanNoCoverage() throws {
        let point = try makeAnchoredPoint()
        let result = makeResult(point: point, outcome: .noCoverage)
        let report = makeReport(plan: makePlan(mutations: [point]), results: [result])

        let entries = TestObligationAnalyzer.buildFixPlan(from: report)
        let entry = try #require(entries.first)
        #expect(entry.facts.outcome == .noCoverage)
        #expect(entry.inference.gapKind == .reachability)
        #expect(entry.facts.testsRun == nil, "noCoverage never carries a testSummary -- see ExecutedMutationProof's own doc comment")
        #expect(entry.facts.testScope == nil, "no test scope applies when the site was never reached")
    }

    /// A hand-edited or otherwise corrupted `report.json` can carry two
    /// `MutationResult`s that share the same mutant ID: `RunReport`'s only
    /// non-Decodable initializer goes through a `ResultLedger`, which
    /// refuses a duplicate `mutationRef` at insert time, but
    /// `RunReport.init(from:)` decodes `results` as a plain `[MutationResult]`
    /// array with no such re-check -- exactly the path `FixPlanCommand`/
    /// `NextCommand` read a report through. `buildFixPlan` used to key a
    /// lookup dictionary with `Dictionary(uniqueKeysWithValues:)`, which
    /// traps the whole process on this input; it must now degrade instead.
    @Test("buildFixPlan tolerates a report.json where two results share the same mutant ID, instead of trapping")
    func buildFixPlanToleratesDuplicateMutantID() throws {
        let pointA = try discover(
            "struct A { func isReady() -> Bool { true } }", path: "Sources/A.swift", using: Operators.boolLiteral
        )[0]
        let pointB = try discover(
            "struct B { func isReady() -> Bool { true } }", path: "Sources/B.swift", using: Operators.boolLiteral
        )[0]
        #expect(pointA.id != pointB.id, "start from two genuinely distinct IDs so the ledger accepts both while building the fixture")

        let resultA = makeResult(point: pointA, outcome: .survived, diagnosis: "first result")
        let resultB = makeResult(point: pointB, outcome: .noCoverage, diagnosis: "second result")
        let report = makeReport(plan: makePlan(mutations: [pointA, pointB]), results: [resultA, resultB])

        // Corrupt it after the fact, the same way a hand edit would: force
        // the second result's mutant ID to collide with the first's.
        let decoded = try JSONSerialization.jsonObject(with: report.encoded())
        var json = try #require(decoded as? [String: Any])
        var results = try #require(json["results"] as? [[String: Any]])
        let firstPoint = try #require(results[0]["point"] as? [String: Any])
        var secondPoint = try #require(results[1]["point"] as? [String: Any])
        secondPoint["id"] = firstPoint["id"]
        results[1]["point"] = secondPoint
        json["results"] = results
        let corruptedData = try JSONSerialization.data(withJSONObject: json)
        let corrupted = try MutationPlan.decoder().decode(RunReport.self, from: corruptedData)
        #expect(corrupted.results[0].point.id == corrupted.results[1].point.id, "the fixture must actually collide, or this test proves nothing")

        // The actual assertion: this exact input used to trap the whole
        // process. It must now return normally.
        let entries = TestObligationAnalyzer.buildFixPlan(from: corrupted)
        #expect(entries.count == 2, "both members are still reported even though their ID now collides")
        // Documented collision policy: the first `MutationResult` in
        // `report.results`'s own order wins the lookup for every member
        // sharing that ID -- so every entry resolves to `resultA`'s
        // outcome (`.survived`), never `resultB`'s (`.noCoverage`).
        #expect(entries.allSatisfy { $0.facts.outcome == .survived })
        #expect(entries.allSatisfy { $0.facts.mutantID == corrupted.results[0].point.id.rawValue })
    }

    @Test("TestObligationFixPlan.build stamps the real planID and schemaVersion")
    func fixPlanEnvelope() throws {
        let point = try makeAnchoredPoint()
        let report = makeReport(plan: makePlan(mutations: [point]), results: [makeResult(point: point, outcome: .survived)])

        let plan = TestObligationFixPlan.build(from: report)
        #expect(plan.planID == report.planID)
        #expect(plan.schemaVersion == SchemaVersion.testObligationFixPlan)
        #expect(plan.entries.count == 1)
    }
}
