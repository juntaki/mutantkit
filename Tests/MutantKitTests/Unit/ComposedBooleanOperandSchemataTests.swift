import Foundation
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins the narrow "composed boolean/comparison operand" widening shared by
/// `LogicalConnectorReplacementSchemataLowerer`,
/// `RelationalOperatorReplacementSchemataLowerer` and
/// `TernaryBranchSwapSchemataLowerer` (`ComposedBooleanOperand`): an operand
/// that is itself `&&`/`||`/`==`/`!=`/`<`/`<=`/`>`/`>=`/`!` over
/// already-accepted leaves is now eligible; everything else keeps its own
/// distinct fallback reason.
@Suite("ComposedBooleanOperand: analyze")
struct ComposedBooleanOperandAnalyzeTests {
    private func points(_ source: String, operatorID: String) throws -> [MutationPoint] {
        try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
    }

    /// The mutation point whose operator token is `opText` found inside the
    /// first occurrence of `context` in `source`.
    private func point(
        _ source: String, operatorID: String, opText: String, in context: String, replacement: String? = nil
    ) throws -> MutationPoint {
        let contextRange = try #require(source.range(of: context), "context \(context) not found")
        let opRange = try #require(context.range(of: opText), "operator \(opText) not in context")
        let offset = source.utf8.distance(from: source.startIndex, to: contextRange.lowerBound)
            + context.utf8.distance(from: context.startIndex, to: opRange.lowerBound)
        let found = try points(source, operatorID: operatorID).filter {
            $0.utf8Range.start == offset && (replacement == nil || $0.replacementText == replacement)
        }
        return try #require(found.first, "no mutation point at \(context)")
    }

    private func logical(_ source: String, opText: String, in context: String) throws -> SchemataEligibility {
        let p = try point(source, operatorID: LogicalConnectorReplacementOperator.descriptor.id, opText: opText, in: context)
        return LogicalConnectorReplacementSchemataLowerer().analyze(p, source: Data(source.utf8))
    }

    private func relational(_ source: String, opText: String, in context: String) throws -> SchemataEligibility {
        let p = try point(source, operatorID: RelationalOperatorReplacementOperator.descriptor.id, opText: opText, in: context)
        return RelationalOperatorReplacementSchemataLowerer().analyze(p, source: Data(source.utf8))
    }

    private func ternary(_ source: String) throws -> SchemataEligibility {
        let p = try #require(try points(source, operatorID: TernaryBranchSwapOperator.descriptor.id).first)
        return TernaryBranchSwapSchemataLowerer().analyze(p, source: Data(source.utf8))
    }

    private func unsupportedReason(_ eligibility: SchemataEligibility) -> String? {
        guard case let .isolatedOnly(reason) = eligibility else { return nil }
        if case let .unsupportedOperand(text) = reason { return text }
        return "\(reason)"
    }

    // MARK: - newly eligible

    @Test("Logical connector: a comparison / logical / negated operand over member chains is eligible")
    func logicalComposedOperandsEligible() throws {
        let src = """
        struct S { let a: Bool; let b: Bool; let c: Bool; let n: Int; let m: Int }
        func f(s: S) -> Bool { s.a && s.b || s.c }
        func g(s: S) -> Bool { s.n < 3 && s.m >= 2 }
        func h(s: S) -> Bool { !s.a || s.b == s.c }
        func i(s: S) -> Bool { (s.n == 1 || s.m != 2) && (s.a) }
        """
        #expect(try logical(src, opText: "||", in: "s.a && s.b || s.c").isEligible)
        #expect(try logical(src, opText: "&&", in: "s.a && s.b || s.c").isEligible)
        #expect(try logical(src, opText: "&&", in: "s.n < 3 && s.m >= 2").isEligible)
        #expect(try logical(src, opText: "||", in: "!s.a || s.b == s.c").isEligible)
        #expect(try logical(src, opText: "&&", in: "(s.n == 1 || s.m != 2) && (s.a)").isEligible)
    }

    @Test("Relational: a comparison whose operand is itself a comparison/logical expression is eligible")
    func relationalComposedOperandEligible() throws {
        let src = "struct S { let a: Bool; let b: Bool; let c: Bool }\nfunc f(s: S) -> Bool { (s.a && s.b) == s.c }"
        #expect(try relational(src, opText: "==", in: "(s.a && s.b) == s.c").isEligible)
    }

    @Test("Ternary: a composed condition over member chains is eligible")
    func ternaryComposedConditionEligible() throws {
        let src = "struct S { let n: Int; let m: Int }\nfunc f(s: S) -> Int { (s.n == 1 || s.m != 2) ? s.n : s.m }"
        #expect(try ternary(src).isEligible)
    }

    @Test("The envelope of a widened site covers the whole infix expression, not just the operator token")
    func envelopeCoversWholeExpression() throws {
        let src = "func f(a: Bool, b: Bool, c: Bool) -> Bool { a && b || c }"
        let p = try point(src, operatorID: LogicalConnectorReplacementOperator.descriptor.id, opText: "||", in: "a && b || c")
        guard case let .eligible(_, envelope, _) = LogicalConnectorReplacementSchemataLowerer().analyze(p, source: Data(src.utf8)) else {
            Issue.record("expected eligible")
            return
        }
        let text = String(decoding: Array(Data(src.utf8))[envelope.range], as: UTF8.self)
        #expect(text == "a && b || c")
    }

    // MARK: - still rejected, each with its own reason

    @Test("A call inside a composed operand is accepted")
    func callInsideComposedOperandAccepted() throws {
        let src = "func g() -> Int { 1 }\nfunc f(a: Bool, b: Bool) -> Bool { g() == 1 && b }"
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "g() == 1 && b")) == nil)
    }

    @Test("A call that contains try or await, a macro, or is too long still falls back")
    func hazardousOrLongCallsStillFallBack() throws {
        let long = String(repeating: "x", count: 160) // the call is then longer than the 160-character limit
        let src = """
        func g(_ v: Int) -> Int { v }
        func h() throws -> Int { 1 }
        func a() async -> Int { 1 }
        func f1(b: Bool) throws -> Bool { g(try h()) == 1 && b }
        func f2(b: Bool) async -> Bool { g(await a()) == 1 && b }
        func f3(b: Bool) -> Bool { g(#line) == 1 && b }
        func f4(b: Bool) -> Bool { g("\(long)".count) == 1 && b }
        func f5(b: Bool) -> Bool { { 1 }() == 1 && b }
        """
        for text in ["g(try h()) == 1 && b", "g(await a()) == 1 && b", "g(#line) == 1 && b", "g(\"\(long)\".count) == 1 && b", "{ 1 }() == 1 && b"] {
            #expect(unsupportedReason(try logical(src, opText: "&&", in: text)) != nil, "\(text.prefix(40))")
        }
    }

    @Test("Standard arithmetic and nil-coalescing operators in an operand are accepted")
    func arithmeticOperandAccepted() throws {
        let src = """
        func f(a: Int, b: Int, c: Bool) -> Bool { a + b == 3 && c }
        func g(a: Int, b: Int, c: Bool) -> Bool { a &+ b == 3 && c }
        func h(a: Int?, b: Int, c: Bool) -> Bool { (a ?? b) == 3 && c }
        """
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "a + b == 3 && c")) == nil)
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "a &+ b == 3 && c")) == nil)
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "(a ?? b) == 3 && c")) == nil)
    }

    @Test("A custom or range operator in an operand falls back with a reason naming that operator")
    func customOperatorOperandRejected() throws {
        let src = """
        infix operator <+>: AdditionPrecedence
        func <+> (lhs: Int, rhs: Int) -> Int { lhs + rhs }
        func f(a: Int, b: Int, c: Bool) -> Bool { a <+> b == 3 && c }
        func g(a: Int, b: Int, c: Bool) -> Bool { (a ..< b).contains(3) == true && c }
        func h(a: Int, b: Int, c: Bool) -> Bool { (a ... b == (1 ... 2)) && c }
        """
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "a <+> b == 3 && c"))?.contains("operator '<+>'") == true)
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "(a ... b == (1 ... 2)) && c"))?.contains("operator '...'") == true)
    }

    @Test("A prefix operator other than ! in an operand falls back with its own reason")
    func nonNotPrefixOperandRejected() throws {
        let src = "func f(a: Int, b: Int, c: Bool) -> Bool { -a == b && c }"
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "-a == b && c"))?.contains("other than '!'") == true)
    }

    @Test("An optional chain, force unwrap or subscript inside a composed operand is accepted")
    func accessLeavesInsideComposedOperandAccepted() throws {
        let src = """
        struct S { let o: S?; let b: Bool; let xs: [Bool] }
        func f(s: S, c: Bool) -> Bool { s.o?.b == true && c }
        func g(s: S, c: Bool) -> Bool { s.o!.b == true && c }
        func h(s: S, c: Bool) -> Bool { s.xs[0] == true && c }
        """
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "s.o?.b == true && c")) == nil)
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "s.o!.b == true && c")) == nil)
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "s.xs[0] == true && c")) == nil)
    }

    @Test("A subscript with try inside, a try or an immediately invoked closure inside a composed operand still falls back")
    func hazardousLeavesInsideComposedOperandRejected() throws {
        let src = """
        struct S { let b: Bool; let xs: [Bool] }
        func k() throws -> Int { 0 }
        func i(s: S, c: Bool) throws -> Bool { (try s.b == true) && c }
        func j(s: S, c: Bool) -> Bool { { s.b }() == true && c }
        func l(s: S, c: Bool) throws -> Bool { s.xs[try k()] == true && c }
        """
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "(try s.b == true) && c")) != nil)
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "{ s.b }() == true && c")) != nil)
        #expect(unsupportedReason(try logical(src, opText: "&&", in: "s.xs[try k()] == true && c"))?.hasPrefix("subscript") == true)
    }

    @Test("An assignment-shaped operand is not accepted as a composed boolean operand")
    func assignmentOperandRejected() throws {
        let src = "func f(a: inout Bool, b: Bool, c: Bool) -> Bool { (a = b) == () && c }"
        let eligibility = try logical(src, opText: "&&", in: "(a = b) == () && c")
        #expect(!eligibility.isEligible)
    }

    @Test("An oversized composed operand falls back with its own size reason")
    func oversizedComposedOperandRejected() throws {
        let leaves = (0 ..< 10).map { "s.a\($0)" }.joined(separator: " && ")
        let src = "struct S { \((0 ..< 10).map { "let a\($0): Bool" }.joined(separator: "; ")) }\nfunc f(s: S, c: Bool) -> Bool { (\(leaves)) || c }"
        let eligibility = try logical(src, opText: "||", in: ") || c")
        #expect(unsupportedReason(eligibility)?.hasPrefix("composed operand too large") == true)
    }
}

@Suite("ComposedBooleanOperand: planner waves")
struct ComposedBooleanOperandPlannerTests {
    private static let backend = SchemataBackendInfo(
        backendID: "swiftpm-process-executor", backendVersion: 1,
        toolchainHash: "sha256:toolchain", buildArgumentsHash: "sha256:args"
    )
    private static let appTarget = SchemataTargetInfo(
        projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
    )

    /// `a && b && c` is `(a && b) && c`: two distinct operator tokens whose
    /// rewrite envelopes nest. Before the planner split waves on the
    /// envelope, both sites landed in one chunk, `lower()` threw
    /// `overlappingRewriteEnvelopes`, and every point in the batch fell back.
    @Test("Nested connector sites with overlapping envelopes land in separate chunks and both embed")
    func nestedEnvelopesSplitIntoWaves() throws {
        let source = "func f(a: Bool, b: Bool, c: Bool) -> Bool { a && b && c }\n"
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: LogicalConnectorReplacementOperator.descriptor.id, relativePath: "W.swift"
        )
        #expect(points.count == 2)
        #expect(points[0].utf8Range.end <= points[1].utf8Range.start || points[1].utf8Range.end <= points[0].utf8Range.start)

        let mutationPlan = makePlan(mutations: points)
        let registry = try SchemataLowererRegistry(lowerers: [LogicalConnectorReplacementSchemataLowerer()])
        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["W.swift": Data(source.utf8)], targetInfo: ["W.swift": [Self.appTarget]], backend: Self.backend
        )
        #expect(result.programs.count == 2)
        let fallenBack = result.schemataPlan.entries.filter { !$0.isEmbedded }
        #expect(fallenBack.isEmpty, "\(fallenBack.map(\.fallbackReason))")
    }
}
