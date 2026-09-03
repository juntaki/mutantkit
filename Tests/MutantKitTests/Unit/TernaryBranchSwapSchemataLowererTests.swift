import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `TernaryBranchSwapSchemataLowerer` — deliberately never registered
/// in `SchemataLowererRegistry.builtIn` yet.
@Suite("TernaryBranchSwapSchemataLowerer")
struct TernaryBranchSwapSchemataLowererTests {
    private let lowerer = TernaryBranchSwapSchemataLowerer()

    private func point(_ source: String, relativePath: String = "Sample.swift") throws -> MutationPoint {
        let points = try discover(source, path: relativePath, using: [TernaryBranchSwapOperator()])
        return try #require(points.first)
    }

    @Test("descriptor reports this lowerer's own identity and its one supported operator")
    func descriptorReportsIdentity() {
        let descriptor = lowerer.descriptor
        #expect(descriptor.lowererID == TernaryBranchSwapSchemataLowerer.lowererID)
        #expect(descriptor.supportedOperatorIDs == [TernaryBranchSwapOperator.descriptor.id])
    }

    @Test("A ternary of plain identifiers is eligible for expressionTernary")
    func eligibleForIdentifierBranches() throws {
        let source = "func f(cond: Bool, a: Int, b: Int) -> Int { cond ? a : b }"
        let mutation = try point(source)
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .eligible(loweringKind, _, _) = eligibility else {
            Issue.record("expected .eligible, got \(eligibility)")
            return
        }
        #expect(loweringKind == .expressionTernary)
    }

    @Test("A point from another operator is not eligible")
    func foreignOperatorNotEligible() throws {
        let source = "func f() -> Bool { true }"
        let points = try discover(source, path: "Sample.swift", using: Operators.boolLiteral)
        let mutation = try #require(points.first)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        guard case .operatorNotYetLowered = reason else {
            Issue.record("expected .operatorNotYetLowered, got \(reason)")
            return
        }
    }

    @Test("A function-call condition falls back to isolated")
    func functionCallConditionFallsBack() throws {
        let source = "func isReady() -> Bool { true }\nfunc f(a: Int, b: Int) -> Int { isReady() ? a : b }"
        let mutation = try point(source)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        guard case .unsupportedOperand = reason else {
            Issue.record("expected .unsupportedOperand, got \(reason)")
            return
        }
    }

    @Test("A function-call then-branch falls back to isolated")
    func functionCallThenBranchFallsBack() throws {
        let source = "func computeA() -> Int { 1 }\nfunc f(cond: Bool, b: Int) -> Int { cond ? computeA() : b }"
        let mutation = try point(source)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        guard case .unsupportedOperand = reason else {
            Issue.record("expected .unsupportedOperand, got \(reason)")
            return
        }
    }

    @Test("A negation inside a @ViewBuilder-style result-builder body is not eligible")
    func resultBuilderBodyNotEligible() throws {
        let source = """
        @ViewBuilder
        func f(cond: Bool, a: Int, b: Int) -> Int {
            if true {
                cond ? a : b
            }
        }
        """
        let mutation = try point(source)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .resultBuilderBody)
    }

    /// `while true ? true : true { }` compiles with no trailing
    /// return, the same reachability fact `while true` does (confirmed
    /// empirically, real `swiftc -typecheck`) — a lowering here would
    /// rewrite it into a runtime selector call, the same whole-chunk-build
    /// hazard `.controlFlowConstant` already exists for
    /// `BoolLiteralSchemataLowerer`.
    @Test("A ternary used as a while loop's whole condition falls back to isolated — controlFlowConstant")
    func whileLoopConditionNotEligible() throws {
        let source = """
        func f() -> Int {
            while true ? true : false {
            }
        }
        """
        let mutation = try point(source)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .controlFlowConstant)
    }

    @Test("Lowering one point embeds a ternary that references the point's own real originalText/replacementText verbatim")
    func loweredCodeReferencesRealTextVerbatim() throws {
        let source = "func f(cond: Bool, a: Int, b: Int) -> Int { cond ? a : b }"
        let mutation = try point(source)
        #expect(mutation.originalText == "cond ? a : b")
        #expect(mutation.replacementText == "cond ? b : a")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        let lowered = try #require(program.loweredSources.first)
        #expect(lowered.contents.contains("(cond ? b : a)"))
        #expect(lowered.contents.contains("(cond ? a : b)"))
        #expect(program.entries.count == 1)
    }

    // MARK: - Neutral-path equivalence (trust corpus, 2026-09)

    /// The property this test exists to pin: `lower(_:sources:)`'s own real,
    /// produced source text — not a hand-written stand-in — must put the
    /// bare, unmutated `cond ? a : b` in the branch selected when
    /// `__mutantkitIsActiveV3` returns `false` (the neutral path), and the
    /// swapped `cond ? b : a` in the branch selected when it returns `true`.
    ///
    /// The test directly above this one (`loweredCodeReferencesRealText
    /// Verbatim`) checks `.contains("(cond ? b : a)")` and
    /// `.contains("(cond ? a : b)")` *separately* — for most lowerers two
    /// separate substring checks like this would still catch a branch swap
    /// (the two texts differ enough that a swap changes what's adjacent to
    /// what), but here both of `TernaryBranchSwapOperator`'s own candidate
    /// texts are themselves full `cond ? x : y` expressions, wrapped in
    /// their own parens by this lowerer's template — so `"(cond ? b : a)"`
    /// and `"(cond ? a : b)"` are two self-contained, independently-
    /// searchable substrings that stay present (each exactly once) in the
    /// output regardless of which one lands in the true branch and which in
    /// the false one. A regression that swapped `point.replacementText`/
    /// `point.originalText` in the production template would still pass
    /// both of those checks. `RelationalOperatorReplacementSchemataLowererTests`/
    /// `LogicalConnectorReplacementSchemataLowererTests` already closed this
    /// exact class of gap for their own two lowerers (competitive-proof
    /// corpus C3); this closes it here too, anchoring the *adjacency* to
    /// `__mutantkitIsActiveV3(...) ? ... : ...` itself so a swap cannot pass
    /// unnoticed. Falsified locally per that same review's own instruction:
    /// temporarily swapping `point.replacementText`/`point.originalText` in
    /// `TernaryBranchSwapSchemataLowerer.swift`'s own template makes this
    /// test fail (while `loweredCodeReferencesRealTextVerbatim` above stays
    /// green, proving that test alone would have missed the swap);
    /// reverting makes it pass again.
    @Test("The neutral (inactive-token) branch lowers to exactly the bare unmutated `cond ? a : b`, verbatim, in the false-branch position")
    func neutralBranchMatchesBareUnmutatedExpression() throws {
        let source = "func f(cond: Bool, a: Int, b: Int) -> Int { cond ? a : b }"
        let mutation = try point(source)
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        let lowered = try #require(program.loweredSources.first)
        // The real lowered shape: `isActive(...) ? (replacementText) : (originalText)`.
        // Neutral (false) branch must be exactly the bare, unmutated
        // `cond ? a : b`; active (true) branch must carry the swapped
        // `cond ? b : a`.
        #expect(
            lowered.contents.contains(
                #/__mutantkitIsActiveV3\(__mutantkitUnitDescriptor_[0-9a-f]{12}, \d+, \d+\) \? \(cond \? b : a\) : \(cond \? a : b\)/#
            ),
            "neutral (false) branch must be the bare unmutated `cond ? a : b`; active (true) branch must be the swapped `cond ? b : a`"
        )
    }

    @Test("An empty chunk makes lower(_:sources:) throw")
    func emptyChunkThrows() throws {
        let chunk = SchemataChunk(chunkID: "chunk-1", points: [], projectIdentity: "P", target: "T", module: "M", product: "Prod")
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [])
        }
    }

    @Test("Two ternaries in the same file are both spliced without corrupting each other's offsets")
    func twoPointsSameFileSpliceCorrectly() throws {
        let source = """
        func f(cond: Bool, a: Int, b: Int, c: Int, d: Int) -> Int {
            let x = cond ? a : b
            let y = cond ? c : d
            return x + y
        }
        """
        let points = try discover(source, path: "Sample.swift", using: [TernaryBranchSwapOperator()])
        #expect(points.count == 2)
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: points, projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        #expect(program.entries.count == 2)
        #expect(parsesWithoutError(Data(program.loweredSources[0].contents.utf8)))
    }

    @Test("A ternary conditional evaluates only its selected branch, never both")
    func ternarySelectsOnlyOneBranchAtRuntime() {
        var conditionEvaluations = 0
        var aEvaluations = 0
        var bEvaluations = 0
        func cond() -> Bool { conditionEvaluations += 1; return true }
        func a() -> Int { aEvaluations += 1; return 1 }
        func b() -> Int { bEvaluations += 1; return 2 }

        func isActive() -> Bool { true }
        _ = isActive() ? (cond() ? b() : a()) : (cond() ? a() : b())

        #expect(conditionEvaluations == 1)
        #expect(aEvaluations + bEvaluations == 1, "only the branch the (single) condition evaluation selects may run")
    }
}
