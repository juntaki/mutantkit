import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// `TernaryBranchSwapSchemataLowererTests` already covers the common
/// operand shapes (function calls, result-builder bodies, loop
/// conditions); this fills the rest of `unsafeOperandReason`'s own
/// per-syntax-kind classification, one real, minimal snippet per branch,
/// plus the two structural checks (`isDirectlyWrappedInTryOrAwait`,
/// member-access/nested-ternary recursion) neither existing suite exercises.
@Suite("TernaryBranchSwapSchemataLowerer: operand-kind classification")
struct TernaryBranchSwapSchemataLowererOperandKindTests {
    private let lowerer = TernaryBranchSwapSchemataLowerer()

    private func point(_ source: String, relativePath: String = "Sample.swift") throws -> MutationPoint {
        let points = try discover(source, path: relativePath, using: [TernaryBranchSwapOperator()])
        return try #require(points.first)
    }

    private func unsupportedOperandReason(_ source: String) throws -> String {
        let mutation = try point(source)
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
        let reason = try unsupportedOperandReason("func f(cond: Bool, arr: [Int], b: Int) -> Int { cond ? arr[0] : b }")
        #expect(reason.contains("subscript operand"))
    }

    @Test("A closure operand is unsupported")
    func closureOperandIsUnsupported() throws {
        let reason = try unsupportedOperandReason("func f(cond: Bool) -> () -> Int { cond ? { 1 } : { 2 } }")
        #expect(reason.contains("closure operand"))
    }

    @Test("An optional-chaining operand is unsupported")
    func optionalChainingOperandIsUnsupported() throws {
        let reason = try unsupportedOperandReason(
            "struct S { var v: Int? }\nfunc f(cond: Bool, s: S?, b: Int?) -> Int? { cond ? s?.v : b }"
        )
        #expect(reason.contains("optional-chaining operand"))
    }

    @Test("A force-unwrap operand is unsupported")
    func forceUnwrapOperandIsUnsupported() throws {
        let reason = try unsupportedOperandReason("func f(cond: Bool, a: Int?, b: Int) -> Int { cond ? a! : b }")
        #expect(reason.contains("force-unwrap operand"))
    }

    @Test("A key-path operand is unsupported")
    func keyPathOperandIsUnsupported() throws {
        let reason = try unsupportedOperandReason(
            "struct S { var v: Int }\nfunc f(cond: Bool, b: AnyKeyPath) -> AnyKeyPath { cond ? \\S.v : b }"
        )
        #expect(reason.contains("key-path operand"))
    }

    @Test("A try-wrapped ternary (the whole ternary under try) is asyncOrThrowingExpression")
    func tryWrappedTernaryIsAsyncOrThrowing() throws {
        let source = """
        func risky() throws -> Int { 1 }
        func f(cond: Bool, a: Int, b: Int) throws -> Int {
            try (cond ? a : b)
        }
        """
        let mutation = try point(source)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .asyncOrThrowingExpression)
    }

    @Test("A member-access operand recurses onto its base, unwrapping to the base's own operand kind")
    func memberAccessOperandRecursesOntoBase() throws {
        let source = """
        func f(cond: Bool, a: (Int, Int)?, b: Int) -> Int? {
            cond ? a?.0 : b
        }
        """
        let mutation = try point(source)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .unsupportedOperand(reason: "optional-chaining operand: a?"))
    }

    @Test("A nested ternary in one branch recurses into that ternary's own condition and both sub-branches")
    func nestedTernaryRecursesIntoItsOwnOperands() throws {
        let source = """
        func f(cond: Bool, sub: Bool, arr: [Int], a: Int, b: Int) -> Int {
            cond ? (sub ? arr[0] : a) : b
        }
        """
        let mutation = try point(source)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .unsupportedOperand(reason: "subscript operand: arr[0]"))
    }

    @Test("A safe leaf operand (integer/float/string/bool/nil literal, or a plain identifier) is eligible")
    func safeLeafOperandsAreEligible() throws {
        for source in [
            "func f(cond: Bool, a: Int) -> Int { cond ? a : 1 }",
            "func f(cond: Bool, a: Double) -> Double { cond ? a : 1.5 }",
            "func f(cond: Bool, a: String) -> String { cond ? a : \"x\" }",
            "func f(cond: Bool, a: Bool) -> Bool { cond ? a : true }",
            "func f(cond: Bool, a: Int?) -> Int? { cond ? a : nil }"
        ] {
            let mutation = try point(source)
            guard case .eligible = lowerer.analyze(mutation, source: Data(source.utf8)) else {
                Issue.record("expected .eligible for: \(source)")
                continue
            }
        }
    }
}
