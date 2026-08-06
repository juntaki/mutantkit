import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

@Suite("Logical connector replacement operator")
struct LogicalConnectorReplacementOperatorTests {
    @Test("Replaces logical AND with logical OR")
    func replacesAndWithOr() throws {
        let points = try discover("""
        func canProceed(authenticated: Bool, active: Bool) -> Bool {
            authenticated && active
        }
        """)

        #expect(points.count == 1)
        #expect(points[0].operatorID == "swift.core.logical-connector-replacement")
        #expect(points[0].originalText == "&&")
        #expect(points[0].replacementText == "||")
        #expect(points[0].confidence == .high)
    }

    @Test("Replaces logical OR with logical AND")
    func replacesOrWithAnd() throws {
        let points = try discover("""
        func shouldRetry(timedOut: Bool, disconnected: Bool) -> Bool {
            timedOut || disconnected
        }
        """)

        #expect(points.count == 1)
        #expect(points[0].originalText == "||")
        #expect(points[0].replacementText == "&&")
    }

    @Test("Does not mutate unrelated binary operators")
    func ignoresOtherOperators() throws {
        let points = try discover("""
        func value(a: Int, b: Int) -> Int { a + b }
        func same(a: Int, b: Int) -> Bool { a == b }
        """)

        #expect(points.isEmpty)
    }

    @Test("Finds each connector in a compound expression independently")
    func discoversCompoundConnectors() throws {
        let points = try discover("""
        func predicate(a: Bool, b: Bool, c: Bool) -> Bool {
            a && b || c
        }
        """)

        #expect(points.count == 2)
        #expect(Set(points.map(\.originalText)) == Set(["&&", "||"]))
        #expect(Set(points.map(\.replacementText)) == Set(["||", "&&"]))
    }

    private func discover(_ source: String) throws -> [MutationPoint] {
        try MutationDiscovery(operators: [LogicalConnectorReplacementOperator()])
            .discover(source: Data(source.utf8), relativePath: "Sample.swift")
    }
}
