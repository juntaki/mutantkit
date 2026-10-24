import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Fills `RelationalOperatorReplacementSchemataLowerer.unsafetyReason`'s
/// remaining per-syntax-kind branches — the same gap
/// `TernaryBranchSwapSchemataLowererOperandKindTests`/
/// `ArithmeticOperatorReplacementSchemataLowererOperandKindTests` closed for
/// their sibling lowerers, since all three share this exact classification
/// structure.
@Suite("RelationalOperatorReplacementSchemataLowerer: operand-kind classification")
struct RelationalOperatorReplacementSchemataLowererOperandKindTests {
    private let lowerer = RelationalOperatorReplacementSchemataLowerer()

    private func point(_ source: String, replacement: String, relativePath: String = "Sample.swift") throws -> MutationPoint {
        let points = try discover(source, path: relativePath, using: Operators.relational)
        return try #require(points.first { $0.replacementText == replacement }, "no candidate with replacementText \(replacement)")
    }

    private func unsupportedOperandReason(_ source: String, replacement: String = ">=") throws -> String {
        let mutation = try point(source, replacement: replacement)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly for: \(source)")
            return ""
        }
        guard case let .unsupportedOperand(detail) = reason else {
            Issue.record("expected .unsupportedOperand, got \(reason) for: \(source)")
            return ""
        }
        return detail
    }

    @Test("An implicit-member operand (base inferred from context) is safe, with nothing to recurse into")
    func implicitMemberOperandIsSafe() throws {
        let source = "func f(a: Int) -> Bool { a < .max }"
        let mutation = try point(source, replacement: ">=")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A subscript operand is accepted on either side, unless it contains try")
    func subscriptOperandIsAccepted() throws {
        for source in ["func f(a: [Int], b: Int) -> Bool { a[0] < b }", "func f(a: [Int], b: Int) -> Bool { b < a[0] }"] {
            let mutation = try point(source, replacement: ">=")
            #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible, "\(source)")
        }
        let reason = try unsupportedOperandReason(
            "func i() throws -> Int { 0 }\nfunc f(a: [Int], b: Int) throws -> Bool { a[try i()] < b }"
        )
        #expect(reason.contains("subscript operand"))
    }

    @Test("A function-call left operand is accepted, as is the right one")
    func functionCallOperandsAreAccepted() throws {
        for source in ["func f(g: () -> Int, b: Int) -> Bool { g() < b }", "func f(g: () -> Int, b: Int) -> Bool { b < g() }"] {
            let mutation = try point(source, replacement: ">=")
            #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible, "\(source)")
        }
    }

    @Test("An optional-chaining operand, reached by recursing through a member-access base, is accepted")
    func optionalChainingOperandIsAccepted() throws {
        let source = "struct S { var v: Int }\nfunc f(s: S?, b: Int) -> Bool? { s?.v.magnitude < b }"
        let mutation = try point(source, replacement: ">=")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A force-unwrap operand is accepted")
    func forceUnwrapOperandIsAccepted() throws {
        let source = "func f(a: Int?, b: Int) -> Bool { a! < b }"
        let mutation = try point(source, replacement: ">=")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("An unrecognized operand kind (an array literal) is unsupported via the catch-all branch")
    func unrecognizedOperandKindIsUnsupportedViaCatchAll() throws {
        let source = "func f(a: [Int]) -> Bool { a.count < [1, 2, 3].count }"
        let mutation = try point(source, replacement: ">=")
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .unsupportedOperand(reason: "unrecognized operand kind arrayExpr: [1, 2, 3]"))
    }

    @Test("A try-wrapped infix (the whole comparison under try) is asyncOrThrowingExpression")
    func tryWrappedInfixIsAsyncOrThrowing() throws {
        let source = """
        func risky() throws -> Int { 1 }
        func f(a: Int) throws -> Bool {
            try (a < risky())
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.relational)
        let mutation = try #require(points.first)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .asyncOrThrowingExpression)
    }
}
