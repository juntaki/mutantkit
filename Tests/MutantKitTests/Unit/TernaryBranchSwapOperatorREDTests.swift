import Foundation
import MutationModel
import SwiftFrontend
import Testing

@Suite("RED: ternary branch swap operator")
struct TernaryBranchSwapOperatorREDTests {
    private let operatorID = "swift.core.ternary-branch-swap"

    @Test("Swaps the true and false branches without replacing the condition")
    func swapsBranches() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func label(enabled: Bool) -> String {
                enabled ? "enabled" : "disabled"
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
        #expect(points[0].operatorID == operatorID)
        #expect(points[0].originalText == "enabled ? \"enabled\" : \"disabled\"")
        #expect(points[0].replacementText == "enabled ? \"disabled\" : \"enabled\"")
        #expect(points[0].confidence == .high)
    }

    @Test("Discovers separate ternary sites independently")
    func discoversIndependentSites() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func title(active: Bool) -> String { active ? "A" : "I" }
            func count(ready: Bool) -> Int { ready ? 1 : 0 }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 2)
        #expect(Set(points.map(\.replacementText)) == [
            "active ? \"I\" : \"A\"",
            "ready ? 0 : 1"
        ])
        #expect(Set(points.map(\.id)).count == points.count)
    }

    @Test("Does not treat if-expressions or nil coalescing as ternaries")
    func ignoresOtherConditionalForms() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func value(flag: Bool, optional: Int?) -> Int {
                if flag { 1 } else { optional ?? 0 }
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("Mutation ID is stable when an unrelated declaration is inserted")
    func IDIsStableAcrossUnrelatedDeclarations() throws {
        let original = try CoreOperatorExpansionTestSupport.discover(
            """
            func label(enabled: Bool) -> String {
                enabled ? "enabled" : "disabled"
            }
            """,
            operatorID: operatorID
        )
        let shifted = try CoreOperatorExpansionTestSupport.discover(
            """
            func unrelated() -> Int { 42 }

            func label(enabled: Bool) -> String {
                enabled ? "enabled" : "disabled"
            }
            """,
            operatorID: operatorID
        )

        #expect(original.count == 1)
        #expect(shifted.count == 1)
        #expect(original[0].id == shifted[0].id)
    }

    @Test("A ternary nested in another ternary's branch is discovered independently of the outer one")
    func nestedTernaryIsDiscoveredIndependently() throws {
        let source = """
        func value(_ a: Bool, _ b: Bool) -> Int {
            a ? (b ? 1 : 2) : 3
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        #expect(points.count == 2, "expected one mutation for the outer ternary and one for the inner")
        #expect(Set(points.map(\.id)).count == 2, "outer and inner must not share a MutationID")

        let outer = try #require(points.first { $0.originalText.hasPrefix("a ?") })
        let inner = try #require(points.first { $0.originalText.hasPrefix("b ?") })

        #expect(outer.originalText == "a ? (b ? 1 : 2) : 3")
        #expect(outer.replacementText == "a ? 3 : (b ? 1 : 2)")
        #expect(inner.originalText == "b ? 1 : 2")
        #expect(inner.replacementText == "b ? 2 : 1")

        // Both must independently survive full anchor re-verification and
        // apply to the exact expected byte-spliced source — proving the
        // inner site is a real, self-contained mutation, not an artifact of
        // the outer one's discovery.
        for (point, expected) in [
            (outer, "func value(_ a: Bool, _ b: Bool) -> Int {\n    a ? 3 : (b ? 1 : 2)\n}"),
            (inner, "func value(_ a: Bool, _ b: Bool) -> Int {\n    a ? (b ? 2 : 1) : 3\n}")
        ] {
            let applied = try MutationApplication.apply(point, to: Data(source.utf8))
            #expect(String(decoding: applied.mutatedSource, as: UTF8.self) == expected)
            #expect(applied.evidence.provesSourceApplication)

            let verification = SourceAnchorVerifier.verify(point, against: Data(source.utf8), depth: .full)
            #expect(verification.isValid, "anchor rejected: \(verification.failures)")
        }
    }

    @Test("Comments attached to the condition, the ?/: tokens, or either branch are not silently dropped")
    func preservesCommentsAndTrivia() throws {
        let source = """
        func value(_ flag: Bool) -> Int {
            flag
                ? /* true branch */ 1
                : /* false branch */ 2
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        #expect(points.count == 1)
        let point = try #require(points.first)

        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        let mutated = String(decoding: applied.mutatedSource, as: UTF8.self)

        // The condition, both comments, and every token stay exactly where
        // they were — only the two literal values traded places.
        #expect(mutated == """
        func value(_ flag: Bool) -> Int {
            flag
                ? /* true branch */ 2
                : /* false branch */ 1
        }
        """)
        #expect(mutated.contains("/* true branch */"), "the true-branch comment must not be dropped")
        #expect(mutated.contains("/* false branch */"), "the false-branch comment must not be dropped")

        let verification = SourceAnchorVerifier.verify(point, against: Data(source.utf8), depth: .full)
        #expect(verification.isValid, "anchor rejected: \(verification.failures)")
    }
}
