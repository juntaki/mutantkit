import MutationModel
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

    @Test("a fileLineOperator rule (from an inline comment) suppresses only its named operator on that line")
    func fileLineOperatorSuppressesOnlyItsOperator() {
        let relational = point(file: "F.swift", line: 3, operatorID: "swift.core.relational-operator-replacement")
        let unaryNot = point(file: "F.swift", line: 3, operatorID: "swift.core.unary-not-removal")
        let plan = makePlan(mutations: [relational, unaryNot])

        let set = MutationSuppressionSet(rules: [
            .fileLineOperator(file: "F.swift", line: 3, operatorID: "swift.core.relational-operator-replacement")
        ])
        let result = set.applying(to: plan)

        #expect(result.mutations.map(\.id) == [unaryNot.id])
        #expect(result.skipped.map(\.id) == [relational.id])
    }

    private func point(file: String, line: Int, operatorID: String) -> MutationPoint {
        MutationPoint(
            id: MutationID(rawValue: "mut_\(file)_\(line)_\(operatorID)"),
            file: file,
            enclosingDeclaration: DeclarationIdentity(path: ["Test/test"]),
            operatorID: operatorID,
            operatorVersion: 1,
            occurrenceIndex: 0,
            utf8Range: ByteRange(0 ..< 1),
            originalText: "x",
            replacementText: "y",
            prefixTokenFingerprint: "pre",
            suffixTokenFingerprint: "post",
            sourceFileHash: "hash",
            expectedSyntaxKind: "kind",
            confidence: .high,
            executionMode: .isolated,
            line: line,
            column: 1
        )
    }
}
