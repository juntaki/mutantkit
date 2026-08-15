import MutationPlanner
import Testing

@Suite("Inline mutation suppression scanner")
struct InlineMutationSuppressionScannerTests {
    @Test("disable-next-line with no operator list suppresses every operator on the following line")
    func disableNextLineWithNoOperatorList() {
        let source = """
        func f() {
            // mutantkit:disable-next-line
            if index < count { }
        }
        """
        let rules = InlineMutationSuppressionScanner.scan(source: source, file: "F.swift")
        #expect(rules == [.fileLine(file: "F.swift", line: 3)])
    }

    @Test("disable-next-line with one operator ID scopes suppression to that operator only")
    func disableNextLineWithOneOperator() {
        let source = """
        func f() {
            // mutantkit:disable-next-line swift.core.relational-operator-replacement
            if index < count { }
        }
        """
        let rules = InlineMutationSuppressionScanner.scan(source: source, file: "F.swift")
        #expect(rules == [
            .fileLineOperator(file: "F.swift", line: 3, operatorID: "swift.core.relational-operator-replacement")
        ])
    }

    @Test("a comma-separated operator list expands into one rule per operator")
    func commaSeparatedOperatorList() {
        let source = "// mutantkit:disable-next-line swift.core.relational-operator-replacement, "
            + "swift.core.unary-not-removal\nif !(index < count) { }"
        let rules = InlineMutationSuppressionScanner.scan(source: source, file: "F.swift")
        #expect(rules == [
            .fileLineOperator(file: "F.swift", line: 2, operatorID: "swift.core.relational-operator-replacement"),
            .fileLineOperator(file: "F.swift", line: 2, operatorID: "swift.core.unary-not-removal")
        ])
    }

    @Test("disable-line targets the same line as the comment, for trailing-comment usage")
    func disableLineTargetsSameLine() {
        let source = "if index < count { } // mutantkit:disable-line swift.core.relational-operator-replacement"
        let rules = InlineMutationSuppressionScanner.scan(source: source, file: "F.swift")
        #expect(rules == [
            .fileLineOperator(file: "F.swift", line: 1, operatorID: "swift.core.relational-operator-replacement")
        ])
    }

    @Test("a disable-next-line on the final source line produces no rule: there is no next line to target")
    func disableNextLineOnFinalLineProducesNothing() {
        let source = "let x = 1\n// mutantkit:disable-next-line"
        let rules = InlineMutationSuppressionScanner.scan(source: source, file: "F.swift")
        #expect(rules.isEmpty)
    }

    @Test("an unrelated comment produces no rule")
    func unrelatedCommentProducesNoRule() {
        let source = """
        // this line mentions mutantkit but is not a directive
        // mutantkit: some other note
        let x = 1
        """
        let rules = InlineMutationSuppressionScanner.scan(source: source, file: "F.swift")
        #expect(rules.isEmpty)
    }

    @Test("multiple directives in one file each produce their own rule")
    func multipleDirectivesInOneFile() {
        let source = """
        // mutantkit:disable-next-line
        let a = 1 < 2
        // mutantkit:disable-next-line swift.core.unary-not-removal
        let b = !true
        """
        let rules = InlineMutationSuppressionScanner.scan(source: source, file: "F.swift")
        #expect(rules == [
            .fileLine(file: "F.swift", line: 2),
            .fileLineOperator(file: "F.swift", line: 4, operatorID: "swift.core.unary-not-removal")
        ])
    }
}
