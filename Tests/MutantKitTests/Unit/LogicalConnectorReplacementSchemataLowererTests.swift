import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `LogicalConnectorReplacementSchemataLowerer` — deliberately never
/// registered in `SchemataLowererRegistry.builtIn` yet (see that type's own
/// doc comment): every test here constructs and calls the lowerer directly,
/// the same seam the eventual promotion commit will simply add to the
/// registry, changing no lowering logic. Structured to mirror
/// `RelationalOperatorReplacementSchemataLowererTests` closely — the two
/// lowerers share the same "operator text duplicated across ternary
/// branches, only one branch ever evaluates" shape.
@Suite("LogicalConnectorReplacementSchemataLowerer")
struct LogicalConnectorReplacementSchemataLowererTests {
    private let lowerer = LogicalConnectorReplacementSchemataLowerer()

    private func point(_ source: String, relativePath: String = "Sample.swift", replacement: String) throws -> MutationPoint {
        let points = try discover(source, path: relativePath, using: Operators.logicalConnector)
        return try #require(points.first { $0.replacementText == replacement }, "no candidate with replacementText \(replacement)")
    }

    // MARK: - descriptor

    @Test("descriptor reports this lowerer's own identity and its one supported operator")
    func descriptorReportsIdentity() {
        let descriptor = lowerer.descriptor
        #expect(descriptor.lowererID == LogicalConnectorReplacementSchemataLowerer.lowererID)
        #expect(descriptor.lowererVersion == LogicalConnectorReplacementSchemataLowerer.lowererVersion)
        #expect(descriptor.runtimeABIVersion == LogicalConnectorReplacementSchemataLowerer.runtimeABIVersion)
        #expect(descriptor.supportedOperatorIDs == [LogicalConnectorReplacementOperator.descriptor.id])
    }

    // MARK: - analyze: eligible cases

    @Test("A connector between two plain identifiers is eligible for expressionTernary")
    func eligibleForIdentifierOperands() throws {
        let source = "func f(a: Bool, b: Bool) -> Bool { a && b }"
        let mutation = try point(source, replacement: "||")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .eligible(loweringKind, _, _) = eligibility else {
            Issue.record("expected .eligible, got \(eligibility)")
            return
        }
        #expect(loweringKind == .expressionTernary)
    }

    @Test("A simple member access (self.x) is eligible")
    func eligibleForSelfMemberAccess() throws {
        let source = """
        struct S {
            let x: Bool
            let y: Bool
            func f() -> Bool { self.x && self.y }
        }
        """
        let mutation = try point(source, replacement: "||")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A parenthesized safe expression is eligible")
    func eligibleForParenthesizedOperand() throws {
        let source = "func f(a: Bool, b: Bool) -> Bool { (a) && (b) }"
        let mutation = try point(source, replacement: "||")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("An || site is eligible the same way && is")
    func eligibleForOrConnector() throws {
        let source = "func f(a: Bool, b: Bool) -> Bool { a || b }"
        let mutation = try point(source, replacement: "&&")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    // MARK: - analyze: ineligible cases

    @Test("A point from another operator is not eligible")
    func foreignOperatorNotEligible() throws {
        let source = "func f() -> Bool { true }"
        let points = try discover(source, path: "Sample.swift", using: Operators.boolLiteral)
        let mutation = try #require(points.first)
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        guard case .operatorNotYetLowered = reason else {
            Issue.record("expected .operatorNotYetLowered, got \(reason)")
            return
        }
    }

    @Test("A point whose anchor no longer matches the given source is not eligible")
    func anchorMismatchNotEligible() throws {
        let source = "func f(a: Bool, b: Bool) -> Bool { a && b }"
        let mutation = try point(source, replacement: "||")
        let changed = "func f(a: Bool, b: Bool) -> Bool { a &&  b }" // extra space shifts offsets
        #expect(!lowerer.analyze(mutation, source: Data(changed.utf8)).isEligible)
    }

    @Test("A connector inside a @ViewBuilder-style result-builder body is not eligible")
    func resultBuilderBodyNotEligible() throws {
        let source = """
        @ViewBuilder
        func f(a: Bool, b: Bool) -> Bool {
            if a && b {
                true
            }
        }
        """
        let mutation = try point(source, replacement: "||")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .resultBuilderBody)
    }

    /// `while true && true { }` compiles with no trailing return,
    /// the same reachability fact `while true` does (confirmed
    /// empirically, real `swiftc -typecheck`) — a lowering here would
    /// rewrite it into a runtime selector call, the same whole-chunk-build
    /// hazard `.controlFlowConstant` already exists for
    /// `BoolLiteralSchemataLowerer`.
    @Test("A connector used as a while loop's whole condition falls back to isolated — controlFlowConstant")
    func whileLoopConditionNotEligible() throws {
        let source = """
        func f() -> Int {
            while true && true {
            }
        }
        """
        let mutation = try point(source, replacement: "||")
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .controlFlowConstant)
    }

    @Test("A function-call operand falls back to isolated — the common `isValid() && hasPermission()` shape")
    func functionCallOperandFallsBack() throws {
        let source = "func lhs() -> Bool { true }\nfunc f(b: Bool) -> Bool { lhs() && b }"
        let mutation = try point(source, replacement: "||")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        guard case .unsupportedOperand = reason else {
            Issue.record("expected .unsupportedOperand, got \(reason)")
            return
        }
    }

    @Test("A try operand falls back to isolated")
    func tryOperandFallsBack() throws {
        let wrappedSource = "func f(a: Bool, b: Bool) throws -> Bool { try (a && b) }"
        let wrappedMutation = try point(wrappedSource, replacement: "||")
        guard case let .isolatedOnly(reason) = lowerer.analyze(wrappedMutation, source: Data(wrappedSource.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .asyncOrThrowingExpression)
    }

    @Test("An await operand falls back to isolated")
    func awaitOperandFallsBack() throws {
        let wrappedSource = "func f(a: Bool, b: Bool) async -> Bool { await (a && b) }"
        let wrappedMutation = try point(wrappedSource, replacement: "||")
        guard case let .isolatedOnly(reason) = lowerer.analyze(wrappedMutation, source: Data(wrappedSource.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .asyncOrThrowingExpression)
    }

    // MARK: - Variant table consistency

    @Test("Every replacement this lowerer embeds matches the real, unmodified isolated operator — never a separate table")
    func schemataNeverInventsItsOwnReplacementTable() throws {
        let source = "func f(a: Bool, b: Bool, c: Bool, d: Bool) -> Bool { (a && b) || (c && d) }"
        let points = try discover(source, path: "Sample.swift", using: Operators.logicalConnector)
        #expect(!points.isEmpty)
        let variants = points.map { LogicalConnectorMutationVariant(originalOperator: $0.originalText, replacementOperator: $0.replacementText) }
        let knownPairs: Set<LogicalConnectorMutationVariant> = [
            .init(originalOperator: "&&", replacementOperator: "||"),
            .init(originalOperator: "||", replacementOperator: "&&")
        ]
        for variant in variants {
            #expect(knownPairs.contains(variant), "unexpected variant \(variant) not produced by the real isolated operator's own table")
        }
    }

    // MARK: - lower(_:sources:): structural correctness

    @Test("Lowering one point embeds a closure that references the point's own real originalText/replacementText verbatim")
    func loweredCodeReferencesRealOperatorTextVerbatim() throws {
        let source = "func f(a: Bool, b: Bool) -> Bool { a && b }"
        let mutation = try point(source, replacement: "||")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        let lowered = try #require(program.loweredSources.first)
        #expect(lowered.contents.contains("a || b"), "must reference the real, discovered replacementText")
        #expect(lowered.contents.contains("a && b"), "must reference the real, discovered originalText")
        #expect(program.entries.count == 1)
        #expect(program.entries.first?.mutationID == mutation.id)
    }

    @Test("A point from another operator makes lower(_:sources:) throw")
    func foreignOperatorMakesLowerThrow() throws {
        let source = "func f() -> Bool { true }"
        let points = try discover(source, path: "Sample.swift", using: Operators.boolLiteral)
        let mutation = try #require(points.first)
        let chunk = SchemataChunk(chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod")
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        }
    }

    @Test("An empty chunk makes lower(_:sources:) throw")
    func emptyChunkThrows() throws {
        let chunk = SchemataChunk(chunkID: "chunk-1", points: [], projectIdentity: "P", target: "T", module: "M", product: "Prod")
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [])
        }
    }

    @Test("A duplicate MutationID in the same chunk makes lower(_:sources:) throw")
    func duplicateMutationIDThrows() throws {
        let source = "func f(a: Bool, b: Bool) -> Bool { a && b }"
        let mutation = try point(source, replacement: "||")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation, mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        }
    }

    @Test("A point whose file is missing from sources makes lower(_:sources:) throw")
    func missingSourceThrows() throws {
        let source = "func f(a: Bool, b: Bool) -> Bool { a && b }"
        let mutation = try point(source, replacement: "||")
        let chunk = SchemataChunk(chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod")
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Other.swift", contents: source)])
        }
    }

    @Test("Two connectors in the same file are both spliced without corrupting each other's offsets")
    func twoPointsSameFileSpliceCorrectly() throws {
        // Two independent statements, not nested — `(a && b) || (c && d)`
        // would make the outer `||`'s rewrite envelope (the whole
        // expression) legitimately overlap the inner `&&`'s (a sub-range of
        // it), which the overlap guard correctly rejects; that is not what
        // this test is about.
        let source = """
        func f(a: Bool, b: Bool, c: Bool, d: Bool) -> Bool {
            let x = a && b
            let y = c || d
            return x && y
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.logicalConnector)
        let first = try #require(points.first { $0.originalText == "&&" && $0.replacementText == "||" && $0.line == 2 })
        let second = try #require(points.first { $0.originalText == "||" && $0.replacementText == "&&" && $0.line == 3 })
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [first, second], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        #expect(program.entries.count == 2)
        #expect(parsesWithoutError(Data(program.loweredSources[0].contents.utf8)), "lowered output must remain syntactically valid Swift")
    }

    // MARK: - Evaluation count and short-circuit preservation

    @Test("A ternary conditional evaluates only its selected branch, never both")
    func ternarySelectsOnlyOneBranchAtRuntime() {
        var lhsEvaluations = 0
        var rhsEvaluations = 0
        // lhs=true so the selected `&&` branch cannot short-circuit away
        // from rhs — isolates "the text is duplicated across branches, but
        // only the selected branch's own operands evaluate" from the
        // separate short-circuit property `selectedBranchStillShortCircuits`
        // below covers.
        func lhs() -> Bool { lhsEvaluations += 1; return true }
        func rhs() -> Bool { rhsEvaluations += 1; return true }

        func isActive() -> Bool { true }
        _ = isActive() ? (lhs() && rhs()) : (lhs() || rhs())

        #expect(lhsEvaluations == 1, "lhs must be evaluated exactly once regardless of which branch's operator text is selected")
        #expect(rhsEvaluations == 1, "rhs must be evaluated exactly once regardless of which branch's operator text is selected")
    }

    /// The property this lowerer's whole safety argument depends on beyond
    /// ROR's: `&&`/`||` short-circuit their *own* right operand, and the
    /// lowered ternary must not turn that into eager evaluation. Proves the
    /// selected branch's short-circuit still holds even though `rhs`
    /// appears a second time, unevaluated, in the ternary's other arm.
    @Test("The selected branch's own short-circuit still applies: rhs is not evaluated when && short-circuits on a false lhs")
    func selectedBranchStillShortCircuits() {
        var rhsEvaluations = 0
        func lhs() -> Bool { false }
        func rhs() -> Bool { rhsEvaluations += 1; return true }

        func isActive() -> Bool { true } // selects the && branch: lhs() && rhs()
        _ = isActive() ? (lhs() && rhs()) : (lhs() || rhs())

        #expect(rhsEvaluations == 0, "&& must still short-circuit on a false lhs even inside the lowered ternary")
    }

    // MARK: - Neutral-path equivalence (competitive-proof corpus C3)

    /// The property this test exists to pin: `lower(_:sources:)`'s own
    /// real, produced source text — not a hand-written stand-in — must put
    /// the bare, unmutated `&&` in the branch selected when
    /// `__mutantkitIsActiveV3` returns `false` (the neutral path — the
    /// case for every embedded mutation's own dispatch site during every
    /// *other* mutation's own test run, not a rare corner case), and the
    /// replacement `||` in the branch selected when it returns `true`.
    /// Calls the real lowerer and regex-matches the real lowered source
    /// text, the same technique
    /// `BoolLiteralSchemataLowererTests.lowersTwoPointsInSameFile` uses —
    /// so a regression that swaps `point.replacementText`/
    /// `point.originalText` in the lowerer's own template
    /// (`LogicalConnectorReplacementSchemataLowerer.swift`) flips which
    /// operator lands in which branch and makes this regex fail to match.
    /// (Verified locally: swapping those two identifiers in the production
    /// template makes this test fail; reverting makes it pass again.)
    @Test("The neutral (inactive-token) branch lowers to exactly the bare unmutated && expression, verbatim, in the false-branch position")
    func neutralBranchMatchesBareUnmutatedExpression() throws {
        let source = "func f(a: Bool, b: Bool) -> Bool { a && b }"
        let mutation = try point(source, replacement: "||")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        let lowered = try #require(program.loweredSources.first)
        // The real lowered shape: `isActive(...) ? (lhs replacementText rhs) : (lhs originalText rhs)`.
        // Neutral (false) branch must be exactly the bare, unmutated
        // `a && b`; active (true) branch must carry the replacement
        // `a || b`.
        #expect(
            lowered.contents.contains(
                #/__mutantkitIsActiveV3\(__mutantkitUnitDescriptor_[0-9a-f]{12}, \d+, \d+\) \? \(a \|\| b\) : \(a && b\)/#
            ),
            "neutral (false) branch must be the bare unmutated `a && b`; active (true) branch must be the replacement `a || b`"
        )
    }
}
