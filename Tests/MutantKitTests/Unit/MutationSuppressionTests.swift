import MutationPlanner
import Testing

@Suite("Mutation suppression")
struct MutationSuppressionTests {
    @Test("parses all supported .mutantkitignore rule kinds")
    func parsesSupportedRules() throws {
        let set = try MutationSuppressionSet.parse("""
        # comment
        id:mut_deadbeef
        operator:swift.core.logical-connector-replacement
        file:Sources/Generated/**
        line:Sources/Foo.swift:42
        """)

        #expect(set.rules.count == 4)
    }

    @Test("rejects unknown suppression syntax")
    func rejectsUnknownRule() {
        #expect(throws: MutationSuppressionError.self) {
            _ = try MutationSuppressionSet.parse("something:else")
        }
    }

    @Test("rejects invalid line numbers")
    func rejectsInvalidLineNumber() {
        #expect(throws: MutationSuppressionError.self) {
            _ = try MutationSuppressionSet.parse("line:Sources/Foo.swift:0")
        }
    }
}
