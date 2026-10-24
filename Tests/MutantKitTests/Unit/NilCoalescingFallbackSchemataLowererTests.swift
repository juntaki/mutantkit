import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins which `??` sites `NilCoalescingFallbackSchemataLowerer` embeds and which stay isolated.
/// Behaviour of the embedded text is proven by `NilCoalescingFallbackDifferentialTests`.
@Suite("NilCoalescingFallbackSchemataLowerer")
struct NilCoalescingFallbackSchemataLowererTests {
    private let lowerer = NilCoalescingFallbackSchemataLowerer()

    private func eligibility(_ source: String) throws -> SchemataEligibility {
        let points = try discover(source, path: "Sample.swift", using: [NilCoalescingFallbackOperator()])
        let point = try #require(points.first)
        return lowerer.analyze(point, source: Data(source.utf8))
    }

    private func reason(_ source: String) throws -> SchemataUnsupportedReason? {
        guard case let .isolatedOnly(reason) = try eligibility(source) else { return nil }
        return reason
    }

    @Test("descriptor reports this lowerer's own identity and its one supported operator")
    func descriptorReportsIdentity() {
        let descriptor = lowerer.descriptor
        #expect(descriptor.lowererID == NilCoalescingFallbackSchemataLowerer.lowererID)
        #expect(descriptor.supportedOperatorIDs == [NilCoalescingFallbackOperator.descriptor.id])
    }

    @Test("Any operand shape is eligible: calls, subscripts, optional chains and closures evaluate once in either arm")
    func operandShapesAreEligible() throws {
        let sources = [
            "func f(a: Int?) -> Int { a ?? 0 }",
            "func g() -> Int? { nil }\nfunc f() -> Int { g() ?? 1 }",
            "func f(a: [Int?]) -> Int { a[0] ?? a.count }",
            "struct S { var v: Int? }\nfunc f(s: S?) -> Int { s?.v ?? 3 }",
            "func f(a: Int?, b: Int?) -> Int { a ?? b ?? 7 }",
            "func f(a: Int?) -> Int { a ?? { 4 }() }"
        ]
        for source in sources {
            #expect(try eligibility(source).isEligible, "\(source)")
        }
    }

    @Test("A try or await covering the expression, or inside an operand, stays isolated")
    func tryAndAwaitStayIsolated() throws {
        let sources = [
            "func g() throws -> Int? { nil }\nfunc f() throws -> Int { try g() ?? 1 }",
            "func g() async -> Int? { nil }\nfunc f() async -> Int { await g() ?? 1 }",
            "func h() throws -> Int { 1 }\nfunc f(a: Int?) throws -> Int { a ?? (try h()) }"
        ]
        for source in sources {
            #expect(try reason(source) == .asyncOrThrowingExpression, "\(source)")
        }
    }

    @Test("A `??` inside a result-builder body stays isolated")
    func resultBuilderBodyStaysIsolated() throws {
        let source = """
        @ViewBuilder
        func f(a: Int?) -> Int {
            if (a ?? 0) > 0 {
                1
            }
        }
        """
        #expect(try reason(source) == .resultBuilderBody)
    }

    @Test("A `??` inside a loop condition stays isolated")
    func loopConditionStaysIsolated() throws {
        let source = """
        func f(a: Bool?) -> Int {
            while a ?? true {
            }
        }
        """
        #expect(try reason(source) == .controlFlowConstant)
    }

    @Test("Another operator's point is never this lowerer's")
    func otherOperatorIsNotLowered() throws {
        let source = "func f(a: Bool) -> Bool { !a }"
        let points = try discover(source, path: "Sample.swift", using: [UnaryNotRemovalOperator()])
        let point = try #require(points.first)
        guard case let .isolatedOnly(reason) = lowerer.analyze(point, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .operatorNotYetLowered(operatorID: UnaryNotRemovalOperator.descriptor.id))
    }
}
