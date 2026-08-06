import MutationModel
import Testing

@Suite("RED: nil-coalescing fallback operator")
struct NilCoalescingFallbackOperatorREDTests {
    private let operatorID = "swift.core.nil-coalescing-fallback"

    @Test("Replaces a nil-coalescing expression with its fallback")
    func replacesWithFallback() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func displayName(_ userName: String?) -> String {
                userName ?? "guest"
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
        #expect(points[0].operatorID == operatorID)
        #expect(points[0].originalText == "userName ?? \"guest\"")
        #expect(points[0].replacementText == "\"guest\"")
        #expect(points[0].confidence == .medium)
    }

    @Test("Preserves an arbitrary fallback expression")
    func preservesFallbackExpression() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func value(cached: Int?, load: () -> Int) -> Int {
                cached ?? load()
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
        #expect(points[0].replacementText == "load()")
    }

    @Test("Emits only the type-safe fallback variant, not an unsafe lhs-only variant")
    func emitsOneVariantPerSite() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func value(primary: Int?, fallback: Int) -> Int {
                primary ?? fallback
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
        #expect(CoreOperatorExpansionTestSupport.replacementPairs(points) == [
            "primary ?? fallback -> fallback"
        ])
    }

    @Test("Does not treat force unwrap, optional chaining, or ternary expressions as coalescing")
    func ignoresOtherOptionalAndConditionalSyntax() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func unwrap(_ value: Int?) -> Int { value! }
            func count(_ value: [Int]?) -> Int? { value?.count }
            func choose(_ flag: Bool) -> Int { flag ? 1 : 0 }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }
}
