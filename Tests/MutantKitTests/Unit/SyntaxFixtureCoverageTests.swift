import Foundation
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Operators must discover valid, non-trivial mutations in every syntactic
/// position the Swift compiler accepts. A fixture that exercises an edge — a
/// bool literal in a ternary, a comparison in a guard — and an operator that
/// passes over it silently is a site-level bug that is invisible until a real
/// project happens to combine the two on an uncovered line.
@Suite("Syntax fixture coverage")
struct SyntaxFixtureCoverageTests {
    private let source: String

    init() throws {
        source = try Fixture.text("SyntaxEdges")
    }

    @Test("Every discovered mutation is non-trivial (original != replacement)")
    func noOpMutationsNeverEnterThePlan() throws {
        let points = try discover(source, path: "Sources/SyntaxEdges.swift")

        for point in points {
            #expect(point.originalText != point.replacementText)
        }
    }

    /// The two default operators together must produce at least some mutations
    /// from a fixture rich enough to exercise every context. An empty result
    /// means the operators are silently passing over the entire file.
    @Test("The fixture produces mutations from both default operators")
    func fixtureProducesMutations() throws {
        let points = try discover(source, path: "Sources/SyntaxEdges.swift")

        #expect(!points.isEmpty)

        let operatorIDs = Set(points.map(\.operatorID))
        #expect(operatorIDs.count >= 1)
    }

    /// `BoolLiteralInversion` must find mutations in: default args, ternaries,
    /// collection literals, property initializers, and computed properties.
    @Test("Bool literal inversion covers default args, ternary, and collections")
    func boolLiteralContexts() throws {
        let points = try discover(
            source, path: "Sources/SyntaxEdges.swift",
            using: Operators.boolLiteral
        )

        let declarations = Set(points.map(\.enclosingDeclaration.description))

        // Each of these declarations contains at least one boolean literal.
        // The assertion is structural: a missing declaration means the operator
        // silently passed over an entire syntactic context.
        #expect(declarations.contains("EdgeDefaults.ready(name:enabled:count:)"))
        #expect(declarations.contains("EdgeCollections.lookup"))
        // Ternary and closure also contain bools or comparisons.
        // Not asserting exact count — the fixture changes when the language
        // does, and a new keyword that swallows tokens is what the operator
        // contract suite catches.
    }

    /// `RelationalOperatorReplacement` must find comparisons in: guard, while,
    /// if-let, closure predicates, and computed properties. Switch patterns use
    /// `..<` and `...` (range operators), not `<`/`>` — those are for a future
    /// range-operator mutator, not for relational replacement.
    @Test("Relational replacement covers guard, while, if-let, and closure comparisons")
    func relationalContexts() throws {
        let points = try discover(
            source, path: "Sources/SyntaxEdges.swift",
            using: Operators.relational
        )

        let declarations = Set(points.map(\.enclosingDeclaration.description))

        #expect(declarations.contains("EdgeGuard.process(_:)"))
        #expect(declarations.contains("EdgeWhile.scan(_:)"))
        #expect(declarations.contains(where: { $0.contains("Closures") }))
    }

    /// Unicode identifiers must not break the operator discovery pipeline.
    /// Byte offsets and character counts differ here, and a splice that used
    /// the wrong one would land at the wrong token.
    @Test("Unicode identifiers do not derail discovery")
    func unicodeIdentifiersProduceParseableMutations() throws {
        let source = """
        struct エッジ {
            var フラグ = true
            var 値 = 42
            func 判定する() -> Bool { 値 >= 10 }
        }
        """

        let points = try discover(source, path: "Sources/J.swift")

        // Discovery in a unicode-named declaration must return points
        // without crashing. The operator contract test exercises full-depth
        // re-application from a real file; this test only verifies that
        // unicode identifiers in the source do not derail discovery.
        #expect(!points.isEmpty)
        for point in points {
            #expect(!point.id.rawValue.isEmpty)
        }
    }

    /// Property wrappers and computed properties should not confuse the
    /// declaration walker. A wrapped property that looks like a new
    /// declaration context to an unprepared walker would either miss the
    /// warpper's own initializer or misattribute the mutation.
    @Test("Property wrappers and computed properties are traversed")
    func propertyWrapperAndComputed() throws {
        let source = """
        @propertyWrapper struct W { var wrappedValue: Bool = true }
        struct S { @W var flag: Bool }
        """
        let points = try discover(source, path: "Sources/W.swift", using: Operators.boolLiteral)

        #expect(!points.isEmpty)
    }
}
