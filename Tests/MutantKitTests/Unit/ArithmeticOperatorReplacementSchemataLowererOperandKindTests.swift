import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Fills `ArithmeticOperatorReplacementSchemataLowerer.unsafeOperandReason`'s
/// remaining per-syntax-kind branches — the same gap
/// `TernaryBranchSwapSchemataLowererOperandKindTests` closed for its sibling
/// lowerer, since both share this exact classification structure.
@Suite("ArithmeticOperatorReplacementSchemataLowerer: operand-kind classification")
struct ArithmeticOperatorReplacementSchemataLowererOperandKindTests {
    private let lowerer = ArithmeticOperatorReplacementSchemataLowerer()

    private func point(_ source: String, replacement: String, relativePath: String = "Sample.swift") throws -> MutationPoint {
        let points = try discover(source, path: relativePath, using: Operators.arithmetic)
        return try #require(points.first { $0.replacementText == replacement }, "no candidate with replacementText \(replacement)")
    }

    private func unsupportedOperandReason(_ source: String, replacement: String = "-") throws -> String {
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

    @Test("A subscript operand is unsupported")
    func subscriptOperandIsUnsupported() throws {
        let reason = try unsupportedOperandReason("func f(arr: [Int], b: Int) -> Int { arr[0] + b }")
        #expect(reason.contains("subscript operand"))
    }

    @Test("A function-call operand is unsupported")
    func functionCallOperandIsUnsupported() throws {
        let reason = try unsupportedOperandReason("func f(g: (Int) -> Int, b: Int) -> Int { g(1) + b }")
        #expect(reason.contains("function call operand"))
    }

    @Test("An await-wrapped operand (not the whole infix) is asyncOrThrowingExpression")
    func awaitWrappedOperandIsAsyncOrThrowing() throws {
        let source = """
        func fetch() async -> Int { 1 }
        func f(a: Int) async -> Int {
            a + (await fetch())
        }
        """
        let mutation = try point(source, replacement: "-")
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .asyncOrThrowingExpression)
    }

    @Test("An optional-chaining operand, reached by recursing through a member-access base, is unsupported")
    func optionalChainingOperandIsUnsupported() throws {
        let source = "struct S { var v: Int }\nfunc f(s: S?, b: Int) -> Int? { s?.v + b }"
        let mutation = try point(source, replacement: "-")
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .unsupportedOperand(reason: "optional-chaining operand: s?"))
    }

    @Test("A force-unwrap operand is unsupported")
    func forceUnwrapOperandIsUnsupported() throws {
        let reason = try unsupportedOperandReason("func f(a: Int?, b: Int) -> Int { a! + b }")
        #expect(reason.contains("force-unwrap operand"))
    }

    @Test("An async/throwing infix expression (the whole infix under try) is asyncOrThrowingExpression")
    func tryWrappedInfixIsAsyncOrThrowing() throws {
        let source = """
        func risky() throws -> Int { 1 }
        func f(a: Int) throws -> Int {
            try (a + risky())
        }
        """
        // Both candidate replacements (-, *, /) hit the same infix-level
        // try-wrap check before any per-operand check runs.
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .asyncOrThrowingExpression)
    }

    @Test("A member-access operand recurses onto its base, unwrapping to the base's own operand kind")
    func memberAccessOperandRecursesOntoBase() throws {
        let source = "func f(arr: [Int], b: Int) -> Int { arr[0].magnitude + b }"
        let mutation = try point(source, replacement: "-")
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .unsupportedOperand(reason: "subscript operand: arr[0]"))
    }

    @Test("A safe leaf operand (integer/float literal or a plain identifier) is eligible")
    func safeLeafOperandsAreEligible() throws {
        for source in [
            "func f(a: Int) -> Int { a + 1 }",
            "func f(a: Double) -> Double { a + 1.5 }"
        ] {
            let mutation = try point(source, replacement: "-")
            guard case .eligible = lowerer.analyze(mutation, source: Data(source.utf8)) else {
                Issue.record("expected .eligible for: \(source)")
                continue
            }
        }
    }
}
