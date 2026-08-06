import MutationModel
import Testing

@Suite("RED: arithmetic operator replacement")
struct ArithmeticOperatorReplacementREDTests {
    private let operatorID = "swift.core.arithmetic-operator-replacement"

    @Test("Replaces additive operators in both directions")
    func replacesAdditionAndSubtraction() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func add(_ lhs: Int, _ rhs: Int) -> Int { lhs + rhs }
            func subtract(_ lhs: Int, _ rhs: Int) -> Int { lhs - rhs }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 2)
        #expect(CoreOperatorExpansionTestSupport.replacementPairs(points) == [
            "+ -> -",
            "- -> +"
        ])
        #expect(points.allSatisfy { $0.operatorID == operatorID && $0.confidence == .medium })
    }

    @Test("Replaces multiplicative operators in both directions")
    func replacesMultiplicationAndDivision() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func multiply(_ lhs: Int, _ rhs: Int) -> Int { lhs * rhs }
            func divide(_ lhs: Int, _ rhs: Int) -> Int { lhs / rhs }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 2)
        #expect(CoreOperatorExpansionTestSupport.replacementPairs(points) == [
            "* -> /",
            "/ -> *"
        ])
    }

    @Test("Does not broaden the first version to remainder, overflow, bitwise, or comparison operators")
    func leavesUnvalidatedFamiliesAlone() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func remainder(_ lhs: Int, _ rhs: Int) -> Int { lhs % rhs }
            func overflow(_ lhs: Int, _ rhs: Int) -> Int { lhs &+ rhs }
            func bits(_ lhs: Int, _ rhs: Int) -> Int { lhs & rhs }
            func compare(_ lhs: Int, _ rhs: Int) -> Bool { lhs < rhs }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("Every arithmetic token is discovered independently without duplicates")
    func discoversEverySiteOnce() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func calculate(_ a: Int, _ b: Int, _ c: Int) -> Int {
                a + b * c - a / b
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 4)
        #expect(Set(points.map(\.id)).count == 4)
        #expect(CoreOperatorExpansionTestSupport.replacementPairs(points) == [
            "+ -> -",
            "- -> +",
            "* -> /",
            "/ -> *"
        ])
    }
}

@Suite("RED: assignment operator replacement")
struct AssignmentOperatorReplacementREDTests {
    private let operatorID = "swift.core.assignment-operator-replacement"

    @Test("Replaces additive and multiplicative compound assignments")
    func replacesCompoundAssignments() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func update(_ value: inout Int, delta: Int) {
                value += delta
                value -= delta
                value *= delta
                value /= delta
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 4)
        #expect(CoreOperatorExpansionTestSupport.replacementPairs(points) == [
            "+= -> -=",
            "-= -> +=",
            "*= -> /=",
            "/= -> *="
        ])
        #expect(points.allSatisfy { $0.operatorID == operatorID && $0.confidence == .medium })
    }

    @Test("Does not mutate simple assignment, remainder assignment, or bitwise assignment")
    func ignoresUnvalidatedAssignmentFamilies() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func update(_ value: inout Int, delta: Int) {
                value = delta
                value %= delta
                value &= delta
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }
}
