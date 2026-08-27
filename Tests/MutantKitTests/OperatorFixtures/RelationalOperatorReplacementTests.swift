import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

@Suite("Relational operator replacement")
struct RelationalOperatorReplacementTests {
    private func replacements(for comparison: String) throws -> Set<String> {
        let source = "func compare(_ a: Int, _ b: Int) -> Bool { a \(comparison) b }"
        let points = try discover(source, using: Operators.relational)
        for point in points {
            #expect(point.originalText == comparison)
        }
        return Set(points.map(\.replacementText))
    }

    // MARK: - Positives

    /// Each comparison contributes a boundary form (catches off-by-one, the
    /// mutant that survives when a test never exercises the edge value) and a
    /// negation form (catches a comparison nothing asserts on). Equality has no
    /// meaningful boundary, so it contributes negation only.
    @Test("Each comparison produces exactly its documented replacements", arguments: [
        (comparison: "<", expected: Set(["<=", ">="])),
        (comparison: "<=", expected: Set(["<", ">"])),
        (comparison: ">", expected: Set([">=", "<="])),
        (comparison: ">=", expected: Set([">", "<"])),
        (comparison: "==", expected: Set(["!="])),
        (comparison: "!=", expected: Set(["=="]))
    ])
    func documentedReplacementSets(comparison: String, expected: Set<String>) throws {
        #expect(try replacements(for: comparison) == expected)
    }

    @Test("Ordered comparisons yield two mutants, equality yields one")
    func mutantCounts() throws {
        for comparison in ["<", "<=", ">", ">="] {
            #expect(try replacements(for: comparison).count == 2)
        }
        for comparison in ["==", "!="] {
            #expect(try replacements(for: comparison).count == 1)
        }
    }

    @Test("The anchor covers only the operator token")
    func anchorCoversTheOperatorOnly() throws {
        let source = "func compare(_ a: Int, _ b: Int) -> Bool { a < b }"
        let points = try discover(source, using: Operators.relational)

        for point in points {
            #expect(point.originalText == "<")
            #expect(point.utf8Range.length == 1)
            #expect(point.expectedSyntaxKind == "binaryOperatorExpr")
        }
    }

    @Test("Comparisons are found wherever they appear")
    func comparisonsInEveryPosition() throws {
        let source = """
        struct Cart {
            func check(_ count: Int, limit: Int) -> Bool {
                if count >= limit {
                    return false
                }
                let inRange = count > 0
                return inRange && count != limit
            }
        }
        """

        let points = try discover(source, using: Operators.relational)

        // `>=` and `>` contribute two each; `!=` contributes one.
        #expect(points.count == 5)
        #expect(Set(points.map(\.originalText)) == [">=", ">", "!="])
    }

    @Test("Each comparison in one declaration gets its own identity")
    func repeatedComparisonsAreDistinguished() throws {
        let source = """
        func between(_ x: Int, _ low: Int, _ high: Int) -> Bool {
            return x > low && x > high
        }
        """

        let points = try discover(source, using: Operators.relational)

        #expect(points.count == 4)
        #expect(Set(points.map(\.id)).count == 4)
    }

    // MARK: - Negatives

    @Test("Non-relational binary operators are left alone")
    func arithmeticIsNotTouched() throws {
        let source = """
        func math(_ a: Int, _ b: Int) -> Int {
            let sum = a + b
            let product = a * b
            let difference = a - b
            return sum + product - difference
        }
        """

        #expect(try discover(source, using: Operators.relational).isEmpty)
    }

    @Test("Logical operators are left alone")
    func logicalOperatorsAreNotTouched() throws {
        let source = "func check(_ a: Bool, _ b: Bool) -> Bool { a && b || !a }"

        #expect(try discover(source, using: Operators.relational).isEmpty)
    }

    @Test("Assignment is not mistaken for equality")
    func assignmentIsNotTouched() throws {
        let source = """
        func assign() {
            var x = 1
            x = 2
        }
        """

        #expect(try discover(source, using: Operators.relational).isEmpty)
    }

    /// `@Constrained` is not a known compiler-builtin attribute, so its
    /// arguments are not compile-time metadata by assumption -- a custom
    /// attribute is very often a `@propertyWrapper`/attached macro whose
    /// arguments are ordinary, runtime-evaluated expressions (see
    /// `OperatorExclusions.compileTimeOnlyAttributeNames`'s own doc comment,
    /// and the real compiled fixture in `Research/mutation-testing-
    /// hardening-2026-08/PROGRESS.md` that motivated narrowing this from a
    /// blanket exclusion).
    @Test("Comparisons inside a non-compiler-builtin attribute's arguments are still mutated")
    func customAttributeArgumentsAreNotExcluded() throws {
        let source = """
        struct Config {
            @Constrained(where: 1 < 2)
            var value: Int = 0
        }
        """

        let points = try discover(source, using: Operators.relational)
        #expect(points.count == 2)
        for point in points { #expect(point.originalText == "<") }
        #expect(Set(points.map(\.replacementText)) == Set(["<=", ">="]))
    }

    // A parallel "known compile-time-only attribute still excludes" case is
    // not included here: none of the restricted-grammar compiler builtins
    // on `compileTimeOnlyAttributeNames` (`available`, `_specialize`, ...)
    // accept an arbitrary comparison expression as an argument in the first
    // place, unlike a custom attribute's generic argument list — the
    // allowlist itself, plus `BoolLiteralInversionTests
    // .compileTimeOnlyAttributeArgumentsAreExcluded` (a real Bool argument
    // in `@_specialize`'s actual grammar), already cover that side.

    @Test("Comparisons inside macro expansions are not mutated")
    func macroExpansionsAreExcluded() throws {
        let source = """
        func test() {
            #expect(count > 0)
        }
        """

        #expect(try discover(source, using: Operators.relational).isEmpty)
    }
}
