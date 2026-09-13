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

    @Test("A function-call left operand is unsupported (not just the right operand)")
    func functionCallLeftOperandIsUnsupported() throws {
        let reason = try unsupportedOperandReason("func f(g: () -> Int, b: Int) -> Bool { g() < b }")
        #expect(reason.contains("function call operand"))
    }

    @Test("An optional-chaining operand, reached by recursing through a member-access base, is unsupported")
    func optionalChainingOperandIsUnsupported() throws {
        let source = "struct S { var v: Int }\nfunc f(s: S?, b: Int) -> Bool? { s?.v.magnitude < b }"
        let mutation = try point(source, replacement: ">=")
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .unsupportedOperand(reason: "optional-chaining operand: s?"))
    }

    @Test("A force-unwrap operand is unsupported")
    func forceUnwrapOperandIsUnsupported() throws {
        let reason = try unsupportedOperandReason("func f(a: Int?, b: Int) -> Bool { a! < b }")
        #expect(reason.contains("force-unwrap operand"))
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
