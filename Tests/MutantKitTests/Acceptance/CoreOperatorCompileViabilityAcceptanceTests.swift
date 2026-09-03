import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Empirical proof of the compile-viability gap
/// `ArithmeticOperatorReplacementOperator`/`AssignmentOperatorReplacementOperator`'s
/// doc comments describe: real Swift code where the original compiles but the
/// mutated form does not, confirmed by actually invoking the Swift compiler
/// (`swiftc -typecheck`) — not merely asserted in prose. This is exactly why
/// both operators ship `defaultEnabled: false`: neither operator has symbol
/// resolution, so neither can tell these cases apart from the ones where the
/// replacement genuinely does compile.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: core operator compile viability", .enabled(if: Acceptance.isEnabled))
struct CoreOperatorCompileViabilityAcceptanceTests {
    private func typeChecks(_ source: String) throws -> Bool {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("compile-viability-\(UUID().uuidString).swift")
        try Data(source.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-typecheck", file.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func mutatedSource(_ source: String, operatorID: String) throws -> String {
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(points.first, "expected at least one mutation candidate")
        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        return String(decoding: applied.mutatedSource, as: UTF8.self)
    }

    @Test("A generic Numeric-constrained * mutates to a / that does not compile")
    func genericNumericMultiplyMutantFailsToCompile() throws {
        let source = """
        func multiply<T: Numeric>(_ lhs: T, _ rhs: T) -> T {
            lhs * rhs
        }
        """
        let original = try typeChecks(source)
        #expect(original, "the original source itself must compile")

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.arithmetic-operator-replacement"))
        #expect(!mutated, "Numeric does not guarantee `/`, so this mutant should fail to type-check")
    }

    @Test("String's + mutates to a - that does not compile")
    func stringConcatenationMutantFailsToCompile() throws {
        let source = """
        func join(_ lhs: String, _ rhs: String) -> String {
            lhs + rhs
        }
        """
        let original = try typeChecks(source)
        #expect(original)

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.arithmetic-operator-replacement"))
        #expect(!mutated, "String has no `-`, so this mutant should fail to type-check")
    }

    @Test("Array's + mutates to a - that does not compile")
    func arrayConcatenationMutantFailsToCompile() throws {
        let source = """
        func combine(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
            lhs + rhs
        }
        """
        let original = try typeChecks(source)
        #expect(original)

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.arithmetic-operator-replacement"))
        #expect(!mutated, "Array has no `-`, so this mutant should fail to type-check")
    }

    @Test("String's += mutates to a -= that does not compile")
    func stringCompoundAssignmentMutantFailsToCompile() throws {
        let source = """
        func append(_ value: inout String) {
            value += "a"
        }
        """
        let original = try typeChecks(source)
        #expect(original)

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.assignment-operator-replacement"))
        #expect(!mutated, "String has no `-=`, so this mutant should fail to type-check")
    }

    @Test("A custom type overloading only one side of + / - mutates to a call that does not compile")
    func customTypeWithOnlyOneSidedOperatorMutantFailsToCompile() throws {
        // Deliberately only one `+` site in the whole fixture: the operator
        // body itself must not contain a second, unrelated `+` (say, over
        // its own `Int` fields) or discovery — which has no way to prefer
        // one candidate over another — could pick that one instead, and an
        // `Int` mutating to `-` compiles just fine, silently defeating the
        // point of this fixture.
        let source = """
        struct Vector {
            var x: Int

            static func + (lhs: Vector, rhs: Vector) -> Vector {
                Vector(x: lhs.x)
            }
        }

        func combine(_ a: Vector, _ b: Vector) -> Vector {
            a + b
        }
        """
        let original = try typeChecks(source)
        #expect(original)

        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: "swift.core.arithmetic-operator-replacement"
        )
        #expect(points.count == 1, "expected exactly the one `+` site in `combine`")

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.arithmetic-operator-replacement"))
        #expect(!mutated, "Vector overloads + but not -, so this mutant should fail to type-check")
    }

    // MARK: - return-value-replacement inside a result-builder-attributed function

    /// `return-value-replacement` only ever swaps a `return` statement's own
    /// literal *value* (e.g. `5` -> `0`) — it never adds, removes, or
    /// restructures a statement, unlike `ElseClauseDeletionOperator`/
    /// `SideEffectCallRemovalOperator`, whose own doc comments name result
    /// builders as a real hazard for exactly that reason. A result builder's
    /// transform is sensitive to a body's *statement shape* (which
    /// `buildBlock`/`buildEither` overload applies to each branch), not to
    /// the literal value an existing `return` happens to carry, so mutating
    /// that value in place should never change whether the enclosing
    /// builder-attributed function still compiles. This is the one
    /// Swift-specific context this operator's own
    /// `enclosingFunctionReturnType` walk does not obviously rule out on its
    /// own (unlike closures, accessors, and subscripts, which it explicitly
    /// stops at) — confirmed empirically here rather than left as reasoning
    /// alone. A minimal, self-contained result builder (no SwiftUI
    /// dependency) so this test is portable and has nothing else that could
    /// fail to compile for unrelated reasons.
    @Test("A literal return inside a @resultBuilder-attributed function still compiles after return-value-replacement")
    func resultBuilderAttributedFunctionReturnMutantStillCompiles() throws {
        let source = """
        protocol Component {}
        extension Int: Component {}

        @resultBuilder
        struct ComponentBuilder {
            static func buildBlock(_ components: Component...) -> Component { components[0] }
            static func buildEither(first: Component) -> Component { first }
            static func buildEither(second: Component) -> Component { second }
        }

        @ComponentBuilder
        func content(flag: Bool) -> Component {
            if flag {
                return 5
            }
            return 7
        }
        """
        let original = try typeChecks(source)
        #expect(original, "the original source itself must compile")

        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: "swift.core.return-value-replacement")
        #expect(points.count == 2, "expected both integer-literal return sites (5 and 7) to be discovered")

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.return-value-replacement"))
        #expect(mutated, "a literal-value-only mutation to an existing return statement must not affect result-builder transformation")
    }

    // MARK: - ternary-branch-swap inside a generic, result-builder-attributed function

    /// `ternary-branch-swap` swaps only the two already-mutually-unified
    /// branch expressions of an existing `a ? b : c` — Swift's own
    /// type-checker requires `b`/`c` to already unify to one type for the
    /// *original* to compile at all, and that requirement is symmetric in
    /// `b`/`c`, so a swap can never turn a compiling ternary into a
    /// non-compiling one, independent of whether the branches are generic,
    /// optional, or inside a result-builder-attributed function — the
    /// ternary is still a single expression statement either way, not a
    /// restructured one. Confirmed empirically against the combination most
    /// likely to surface a gap in that reasoning if one existed (generic
    /// branch values, inside a `@resultBuilder`-attributed function), not
    /// just asserted.
    @Test("A ternary with generic branches inside a @resultBuilder-attributed function still compiles after branch swap")
    func genericTernaryInsideResultBuilderMutantStillCompiles() throws {
        let source = """
        protocol Component {}
        extension Int: Component {}

        @resultBuilder
        struct ComponentBuilder {
            static func buildBlock(_ components: Component...) -> Component { components[0] }
        }

        func wrap<T: Component>(_ value: T) -> T { value }

        @ComponentBuilder
        func content(flag: Bool) -> Component {
            flag ? wrap(1) : wrap(2)
        }
        """
        let original = try typeChecks(source)
        #expect(original, "the original source itself must compile")

        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: "swift.core.ternary-branch-swap")
        #expect(points.count == 1)

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.ternary-branch-swap"))
        #expect(mutated, "swapping two already-unified generic branches must not affect result-builder transformation")
    }

    // MARK: - relational-operator-replacement's own documented, unmeasured compile-risk pattern

    /// `RelationalOperatorReplacementOperator`'s own doc comment names a real
    /// compile-risk pattern ("A hand-rolled operator that defines `<`
    /// without `<=` will not compile") but — unlike
    /// `ArithmeticOperatorReplacementOperator`/
    /// `AssignmentOperatorReplacementOperator`, which each cite a specific
    /// corpus's own measured 0-unviable rate — cites no measurement of how
    /// often this actually happens. This test confirms the pattern is real
    /// (a type overloading only `<` via a free-standing operator function,
    /// never conforming to `Comparable`, so no protocol default supplies the
    /// other three): `Comparable` conformance would make this a non-issue
    /// (the protocol's default extensions derive `<=`/`>`/`>=` from a single
    /// `<` implementation automatically), so this specific failure mode
    /// requires deliberately opting out of `Comparable` and hand-writing
    /// only one comparison operator — plausibly rare in practice, but real.
    /// Recorded here to weigh (not decided in this test): whether this
    /// remains an acceptable, honestly-`unviable`-reported risk for a `default`
    /// operator without its own corpus citation, the way it currently ships.
    @Test("A type overloading only < (never conforming to Comparable) mutates <= to a form that does not compile")
    func adHocLessThanOnlyOperatorMutantFailsToCompile() throws {
        // Deliberately only one comparison site in the whole fixture
        // (matching `customTypeWithOnlyOneSidedOperatorMutantFailsToCompile`'s
        // own caution above): the operator body itself must not contain a
        // second, unrelated relational/equality operator, or discovery
        // finds more candidates than this fixture claims to exercise.
        let source = """
        struct Version {
            let isOlderFlag: Bool

            static func < (lhs: Version, rhs: Version) -> Bool {
                lhs.isOlderFlag
            }
        }

        func isOlder(_ a: Version, _ b: Version) -> Bool {
            a < b
        }
        """
        let original = try typeChecks(source)
        #expect(original, "the original source itself must compile")

        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: "swift.core.relational-operator-replacement")
        #expect(points.count == 2, "expected both the boundary (<=) and negation (>=) candidates for the one < site")

        let boundaryPoint = try #require(points.first { $0.replacementText == "<=" })
        let boundaryMutated = try typeChecks(
            String(decoding: MutationApplication.apply(boundaryPoint, to: Data(source.utf8)).mutatedSource, as: UTF8.self)
        )
        #expect(!boundaryMutated, "Version overloads < but not <=, so the boundary mutant should fail to type-check")
    }
}
