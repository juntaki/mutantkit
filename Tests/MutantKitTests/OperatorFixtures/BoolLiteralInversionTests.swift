import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

@Suite("Bool literal inversion operator")
struct BoolLiteralInversionTests {
    private func mutations(_ source: String) throws -> [MutationPoint] {
        try discover(source, using: Operators.boolLiteral)
    }

    // MARK: - Positives

    @Test("A boolean literal binding is inverted")
    func literalBinding() throws {
        let points = try mutations("let enabled = true")

        #expect(points.count == 1)
        #expect(points[0].originalText == "true")
        #expect(points[0].replacementText == "false")
        #expect(points[0].expectedSyntaxKind == "booleanLiteralExpr")
        #expect(points[0].confidence == .high)
    }

    @Test("Both literals are inverted in both directions")
    func bothDirections() throws {
        let points = try mutations("""
        let on = true
        let off = false
        """)

        #expect(points.map(\.originalText) == ["true", "false"])
        #expect(points.map(\.replacementText) == ["false", "true"])
    }

    @Test("A literal in a condition is mutated")
    func literalInCondition() throws {
        let points = try mutations("""
        func check(_ value: Bool) -> Int {
            if value == true {
                return 1
            }
            return 0
        }
        """)

        #expect(points.count == 1)
        #expect(points[0].replacementText == "false")
        #expect(points[0].enclosingDeclaration.description == "check(_:)")
    }

    @Test("A literal default argument is mutated")
    func literalDefaultArgument() throws {
        let points = try mutations("""
        func configure(animated: Bool = true) {}
        """)

        #expect(points.count == 1)
        #expect(points[0].originalText == "true")
        #expect(points[0].replacementText == "false")
    }

    @Test("A literal return value is mutated")
    func literalReturnValue() throws {
        let points = try mutations("""
        struct Cart {
            func isEmpty() -> Bool { return true }
        }
        """)

        #expect(points.count == 1)
        #expect(points[0].enclosingDeclaration.description == "Cart.isEmpty()")
        #expect(points[0].replacementText == "false")
    }

    @Test("Literals in every ordinary position are found")
    func everyOrdinaryPosition() throws {
        let points = try mutations("""
        struct Flags {
            var stored = true
            var computed: Bool { false }

            func check(_ value: Bool = true) -> Bool {
                if value == true {
                    return false
                }
                let local = true
                return local ? true : false
            }
        }
        """)

        // stored, computed, default arg, `== true`, `return false`, local,
        // and both branches of the ternary.
        #expect(points.count == 8)
        for point in points {
            #expect(point.originalText == "true" || point.originalText == "false")
            #expect(point.replacementText == (point.originalText == "true" ? "false" : "true"))
        }
    }

    // MARK: - Negatives

    /// A closed allowlist of *compiler-builtin* attributes, not "every
    /// attribute": `@available`'s arguments really are compile-time-only,
    /// with no code path in the language that reads them at runtime.
    @Test("Literals inside a known compile-time-only attribute's arguments are not mutated")
    func compileTimeOnlyAttributeArgumentsAreExcluded() throws {
        let points = try mutations("""
        struct Config {
            @_specialize(exported: true, kind: full, where T == Int)
            func identity<T>(_ value: T) -> T { value }
        }
        """)

        #expect(points.isEmpty)
    }

    /// `@Wrapped` is not on the compile-time-only allowlist -- deliberately:
    /// a custom attribute is very often a `@propertyWrapper` (or an
    /// attached macro), whose arguments are ordinary initializer arguments
    /// evaluated at runtime like any other call, not compile-time metadata.
    ///
    /// Proven with a real, compiled, run fixture rather than assumed
    /// (`Research/mutation-testing-hardening-2026-08/PROGRESS.md`, P2
    /// exclusion audit): a `@propertyWrapper` whose `init` branches on an
    /// `enabled: Bool` argument produced a genuinely different program
    /// output (`5` vs `0`) when that literal was flipped. Blanket-excluding
    /// every attribute's arguments was silently erasing this entire class
    /// of real, useful mutants -- the same shape of bug as `irradiate`'s
    /// `len(x) > 0` -> `len(x) >= 0` equivalence mistake, just for a
    /// different operator's exclusion rule.
    @Test("A literal inside a non-compiler-builtin (property-wrapper-shaped) attribute is still mutated")
    func customAttributeArgumentsAreNotExcluded() throws {
        let points = try mutations("""
        struct Config {
            @Wrapped(cached: true)
            var value: Int = 0
        }
        """)

        #expect(points.count == 1)
        #expect(points[0].originalText == "true")
        #expect(points[0].replacementText == "false")
    }

    @Test("A literal in a compile-time-only attribute is skipped while a literal beside it is still found")
    func exclusionIsScopedToTheCompileTimeOnlyAttribute() throws {
        let points = try mutations("""
        struct Config {
            @_specialize(exported: true, kind: full, where T == Int)
            func identity<T>(_ value: T) -> T { value }
            var flag = false
        }
        """)

        // The attribute's `true` is excluded; the property's `false` is not.
        #expect(points.count == 1)
        #expect(points[0].originalText == "false")
    }

    /// An `#if` condition decides which code is compiled at all. Mutating one
    /// does not test the suite — it builds a different program.
    @Test("Literals inside #if conditions are not mutated")
    func ifConfigConditionsAreExcluded() throws {
        let points = try mutations("""
        #if true
        let a = 1
        #endif
        """)

        #expect(points.isEmpty)
    }

    /// Macro expansion output is not the developer's source; a mutation there
    /// shows a diff against code nobody wrote.
    @Test("Literals inside macro expansions are not mutated")
    func macroExpansionsAreExcluded() throws {
        let points = try mutations("""
        func test() {
            #expect(flag == true)
        }
        """)

        #expect(points.isEmpty)
    }

    @Test("Non-boolean literals are left alone")
    func onlyBooleanLiteralsAreTouched() throws {
        let points = try mutations("""
        let count = 42
        let name = "true"
        let ratio = 0.5
        let nothing: Bool? = nil
        """)

        #expect(points.isEmpty)
    }
}
