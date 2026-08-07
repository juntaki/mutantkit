import Foundation
import MutationModel
import SwiftFrontend
import Testing

@Suite("RED: range boundary replacement operator")
struct RangeBoundaryReplacementOperatorREDTests {
    private let operatorID = "swift.core.range-boundary-replacement"

    @Test("Replaces half-open with closed")
    func replacesHalfOpenWithClosed() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func indices(_ count: Int) -> Range<Int> {
                0..<count
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
        #expect(points[0].operatorID == operatorID)
        #expect(points[0].confidence == .experimental)
        #expect(points[0].originalText == "..<")
        #expect(points[0].replacementText == "...")
    }

    @Test("Replaces closed with half-open")
    func replacesClosedWithHalfOpen() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func indices(_ count: Int) -> ClosedRange<Int> {
                0...count
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
        #expect(points[0].originalText == "...")
        #expect(points[0].replacementText == "..<")
    }

    @Test("Discovers separate range sites independently")
    func discoversIndependentSites() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func a(_ n: Int) -> Range<Int> { 0..<n }
            func b(_ n: Int) -> ClosedRange<Int> { 1...n }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 2)
        #expect(CoreOperatorExpansionTestSupport.replacementPairs(points) == [
            "..< -> ...",
            "... -> ..<"
        ])
        #expect(Set(points.map(\.id)).count == points.count)
    }

    @Test("Does not treat one-sided ranges as candidates")
    func ignoresOneSidedRanges() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func tail(_ array: [Int], from index: Int) -> ArraySlice<Int> {
                array[index...]
            }
            func head(_ array: [Int], to index: Int) -> ArraySlice<Int> {
                array[..<index]
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("Does not treat other operators as range boundaries")
    func ignoresOtherOperators() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func sum(_ a: Int, _ b: Int) -> Bool {
                a < b && a <= b
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
            func indices(_ count: Int) -> Range<Int> {
                0..<count
            }
            """,
            operatorID: operatorID
        )
        let shifted = try CoreOperatorExpansionTestSupport.discover(
            """
            func unrelated() -> Int { 42 }

            func indices(_ count: Int) -> Range<Int> {
                0..<count
            }
            """,
            operatorID: operatorID
        )

        #expect(original.count == 1)
        #expect(shifted.count == 1)
        #expect(original[0].id == shifted[0].id)
    }

    @Test("Applies cleanly and survives full anchor re-verification")
    func appliesAndVerifies() throws {
        let source = """
        func window(_ start: Int, _ end: Int) -> [Int] {
            Array(start..<end)
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(points.first)

        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        #expect(String(decoding: applied.mutatedSource, as: UTF8.self) == """
        func window(_ start: Int, _ end: Int) -> [Int] {
            Array(start...end)
        }
        """)
        #expect(applied.evidence.provesSourceApplication)

        let verification = SourceAnchorVerifier.verify(point, against: Data(source.utf8), depth: .full)
        #expect(verification.isValid, "anchor rejected: \(verification.failures)")
    }

    @Test("A range inside a switch case pattern is still discovered")
    func rangeInSwitchCasePatternIsStillDiscovered() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func bucket(_ score: Int) -> String {
                switch score {
                case 0..<50:
                    return "low"
                default:
                    return "high"
                }
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
        #expect(points[0].originalText == "..<")
    }
}
