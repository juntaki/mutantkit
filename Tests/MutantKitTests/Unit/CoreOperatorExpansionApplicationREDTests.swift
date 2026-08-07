import Foundation
import SwiftFrontend
import Testing

@Suite("RED: core operator application and determinism")
struct CoreOperatorExpansionApplicationREDTests {
    private struct Case {
        let operatorID: String
        let source: String
        let expected: String
    }

    private let cases: [Case] = [
        Case(
            operatorID: "swift.core.ternary-branch-swap",
            source: "func value(_ flag: Bool) -> Int { flag ? 1 : 0 }",
            expected: "func value(_ flag: Bool) -> Int { flag ? 0 : 1 }"
        ),
        Case(
            operatorID: "swift.core.unary-not-removal",
            source: "func value(_ flag: Bool) -> Bool { !flag }",
            expected: "func value(_ flag: Bool) -> Bool { flag }"
        ),
        Case(
            operatorID: "swift.core.arithmetic-operator-replacement",
            source: "func value(_ lhs: Int, _ rhs: Int) -> Int { lhs + rhs }",
            expected: "func value(_ lhs: Int, _ rhs: Int) -> Int { lhs - rhs }"
        ),
        Case(
            operatorID: "swift.core.assignment-operator-replacement",
            source: "func update(_ value: inout Int) { value += 1 }",
            expected: "func update(_ value: inout Int) { value -= 1 }"
        ),
        Case(
            operatorID: "swift.core.nil-coalescing-fallback",
            source: "func value(_ cached: Int?) -> Int { cached ?? 0 }",
            expected: "func value(_ cached: Int?) -> Int { 0 }"
        ),
        Case(
            operatorID: "swift.core.return-value-replacement",
            source: "func value() -> Int { return 42 }",
            expected: "func value() -> Int { return 0 }"
        )
    ]

    @Test("Every operator emits stable IDs across repeated discovery")
    func discoveryIsDeterministic() throws {
        for testCase in cases {
            let first = try CoreOperatorExpansionTestSupport.discover(
                testCase.source,
                operatorID: testCase.operatorID
            )
            let second = try CoreOperatorExpansionTestSupport.discover(
                testCase.source,
                operatorID: testCase.operatorID
            )

            #expect(first.count == 1, "\(testCase.operatorID) should emit exactly one candidate")
            #expect(second.count == 1, "\(testCase.operatorID) should emit exactly one candidate")
            #expect(first[0].id == second[0].id, "\(testCase.operatorID) emitted an unstable MutationID")
            #expect(first[0].recomputedID == first[0].id)
        }
    }

    @Test("Every operator's planned byte splice produces the exact expected source")
    func mutationsApplyExactly() throws {
        for testCase in cases {
            let points = try CoreOperatorExpansionTestSupport.discover(
                testCase.source,
                operatorID: testCase.operatorID
            )
            let point = try #require(points.only, "\(testCase.operatorID) should emit exactly one candidate")
            let applied = try MutationApplication.apply(point, to: Data(testCase.source.utf8))
            let mutated = String(decoding: applied.mutatedSource, as: UTF8.self)

            #expect(mutated == testCase.expected)
            #expect(applied.evidence.provesSourceApplication)
            #expect(!applied.evidence.sourceDiff.isEmpty)
        }
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
