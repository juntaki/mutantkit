import Foundation
import MutationModel
import SwiftFrontend
import Testing

@Suite("RED: unary-not removal operator")
struct UnaryNotRemovalOperatorREDTests {
    private let operatorID = "swift.core.unary-not-removal"

    @Test("Removes a boolean prefix negation")
    func removesPrefixNot() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func isBlocked(enabled: Bool) -> Bool {
                return !enabled
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
        #expect(points[0].operatorID == operatorID)
        #expect(points[0].originalText == "!enabled")
        #expect(points[0].replacementText == "enabled")
        #expect(points[0].confidence == .medium)
    }

    @Test("Preserves parentheses when removing negation from a compound condition")
    func preservesCompoundExpressionGrouping() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func denied(ready: Bool, allowed: Bool) -> Bool {
                !(ready && allowed)
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
        #expect(points[0].originalText == "!(ready && allowed)")
        #expect(points[0].replacementText == "(ready && allowed)")
    }

    @Test("Does not remove unary minus, force unwrap, or optional chaining")
    func ignoresOtherPrefixAndPostfixSyntax() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func negate(_ value: Int) -> Int { -value }
            func unwrap(_ value: Int?) -> Int { value! }
            func count(_ value: [Int]?) -> Int? { value?.count }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("Does not mistake inequality's `!=` for a prefix negation")
    func ignoresInequalityOperator() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func differ(_ a: Int, _ b: Int) -> Bool { a != b }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("Does not mistake an implicitly-unwrapped optional's `!` type annotation for a prefix negation")
    func ignoresImplicitlyUnwrappedOptionalTypeSyntax() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            struct Holder {
                var value: Int!
                func read() -> Int! { value }
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("`!!` is never assumed to be two stacked built-in negations — it may be a user-defined operator")
    func doesNotMutateACustomBangBangOperator() throws {
        let source = """
        prefix operator !!

        struct Value {
            static prefix func !! (_ value: Value) -> Bool {
                true
            }
        }

        func test(_ value: Value) -> Bool {
            !!value
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        #expect(points.isEmpty, "`!!` is a single lexed token this operator has no symbol resolution to identify")
    }

    @Test("A run of three `!` characters is likewise left alone, not assumed to be built-in negation stacked three deep")
    func doesNotMutateTripleBang() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            "func value(_ flag: Bool) -> Bool { !!!flag }",
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test(
        """
        A genuine double negation, written with parentheses so it lexes as two separate ! tokens, \
        is found as two independent, non-colliding sites
        """
    )
    func realDoubleNegationViaParenthesesIsFoundAsTwoIndependentSites() throws {
        let source = """
        func value(_ flag: Bool) -> Bool {
            !(!flag)
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        #expect(points.count == 2, "the parenthesized inner `!flag` is a genuinely separate token from the outer `!`")
        #expect(Set(points.map(\.id)).count == 2)

        let outer = try #require(points.first { $0.originalText == "!(!flag)" })
        let inner = try #require(points.first { $0.originalText == "!flag" })

        let outerApplied = try MutationApplication.apply(outer, to: Data(source.utf8))
        let innerApplied = try MutationApplication.apply(inner, to: Data(source.utf8))
        let outerResult = String(decoding: outerApplied.mutatedSource, as: UTF8.self)
        let innerResult = String(decoding: innerApplied.mutatedSource, as: UTF8.self)

        #expect(outerResult != innerResult, "removing the outer ! and removing the inner ! must not produce identical mutated source")
        #expect(outerResult == """
        func value(_ flag: Bool) -> Bool {
            (!flag)
        }
        """)
        #expect(innerResult == """
        func value(_ flag: Bool) -> Bool {
            !(flag)
        }
        """)

        for point in [outer, inner] {
            let verification = SourceAnchorVerifier.verify(point, against: Data(source.utf8), depth: .full)
            #expect(verification.isValid, "anchor rejected: \(verification.failures)")
        }
    }

    @Test("Two negations that do not collapse to the same source are both discovered")
    func independentNegationsInsideACompoundConditionAreBothFound() throws {
        let source = """
        func value(_ a: Bool, _ b: Bool) -> Bool {
            !(a && !b)
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        #expect(points.count == 2, "the outer `!(...)` and the inner `!b` are independent, non-collapsing sites")
        #expect(Set(points.map(\.id)).count == 2)
        #expect(CoreOperatorExpansionTestSupport.replacementPairs(points) == [
            "!(a && !b) -> (a && !b)",
            "!b -> b"
        ])
    }

    @Test("Mutation ID is stable when an unrelated declaration is inserted")
    func idIsStableAcrossUnrelatedDeclarations() throws {
        let original = try CoreOperatorExpansionTestSupport.discover(
            "func isBlocked(enabled: Bool) -> Bool { !enabled }",
            operatorID: operatorID
        )
        let shifted = try CoreOperatorExpansionTestSupport.discover(
            """
            func unrelated() -> Int { 42 }

            func isBlocked(enabled: Bool) -> Bool { !enabled }
            """,
            operatorID: operatorID
        )

        #expect(original.count == 1)
        #expect(shifted.count == 1)
        #expect(original[0].id == shifted[0].id)
    }

    @Test("Each negated expression produces one distinct mutation")
    func emitsNoDuplicates() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func first(_ value: Bool) -> Bool { !value }
            func second(_ value: Bool) -> Bool { !value }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 2)
        #expect(Set(points.map(\.id)).count == 2)
        #expect(CoreOperatorExpansionTestSupport.replacementPairs(points) == [
            "!value -> value"
        ])
    }
}
