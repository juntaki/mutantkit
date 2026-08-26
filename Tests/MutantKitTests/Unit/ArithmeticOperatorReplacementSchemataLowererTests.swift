import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `ArithmeticOperatorReplacementSchemataLowerer` — deliberately never
/// registered in `SchemataLowererRegistry.builtIn` in this build (see that
/// type's own doc comment, and `Research/adr-0008-validation/protocol.md`'s
/// "Protocol v2" addendum): every test here constructs and calls the lowerer
/// directly, the same seam a future validation-only registration commit will
/// simply add to the registry, changing no lowering logic.
@Suite("ArithmeticOperatorReplacementSchemataLowerer")
struct ArithmeticOperatorReplacementSchemataLowererTests {
    let lowerer = ArithmeticOperatorReplacementSchemataLowerer()

    /// `replacement` selects which of the isolated operator's own candidates
    /// at this site to return — never a separately hand-written replacement,
    /// always whichever the real, unmodified `ArithmeticOperatorReplacementOperator`
    /// actually discovered.
    func point(_ source: String, relativePath: String = "Sample.swift", replacement: String) throws -> MutationPoint {
        let points = try discover(source, path: relativePath, using: Operators.arithmetic)
        return try #require(points.first { $0.replacementText == replacement }, "no candidate with replacementText \(replacement)")
    }

    // MARK: - descriptor

    @Test("descriptor reports this lowerer's own identity and its one supported operator")
    func descriptorReportsIdentity() {
        let descriptor = lowerer.descriptor
        #expect(descriptor.lowererID == ArithmeticOperatorReplacementSchemataLowerer.lowererID)
        #expect(descriptor.lowererVersion == ArithmeticOperatorReplacementSchemataLowerer.lowererVersion)
        #expect(descriptor.runtimeABIVersion == ArithmeticOperatorReplacementSchemataLowerer.runtimeABIVersion)
        #expect(descriptor.supportedOperatorIDs == [ArithmeticOperatorReplacementOperator.descriptor.id])
    }

    // MARK: - analyze: eligible cases

    @Test("A + between two plain Int identifiers is eligible for expressionTernary")
    func eligiblePlusIdentifiers() throws {
        let source = "func f(a: Int, b: Int) -> Int { a + b }"
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .eligible(loweringKind, _, _) = eligibility else {
            Issue.record("expected .eligible, got \(eligibility)")
            return
        }
        #expect(loweringKind == .expressionTernary)
    }

    @Test("A - between two plain Int identifiers is eligible")
    func eligibleMinusIdentifiers() throws {
        let source = "func f(a: Int, b: Int) -> Int { a - b }"
        let mutation = try point(source, replacement: "+")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A * between two plain Int identifiers in a non-generic context is eligible")
    func eligibleTimesConcreteType() throws {
        let source = "func f(a: Int, b: Int) -> Int { a * b }"
        let mutation = try point(source, replacement: "/")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A / between two plain Double identifiers in a non-generic context is eligible")
    func eligibleDivideConcreteType() throws {
        let source = "func f(a: Double, b: Double) -> Double { a / b }"
        let mutation = try point(source, replacement: "*")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("An arithmetic expression against an integer literal is eligible (the literal is anchored by a's proven-safe Int)")
    func literalOperandEligible() throws {
        let source = "func f(a: Int) -> Int { a + 5 }"
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A simple member access (self.x) is eligible")
    func eligibleForSelfMemberAccess() throws {
        let source = """
        struct S {
            let x: Int
            let y: Int
            func f() -> Int { self.x + self.y }
        }
        """
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A parenthesized safe expression is eligible")
    func eligibleForParenthesizedOperand() throws {
        let source = "func f(a: Int, b: Int) -> Int { (a) + (b) }"
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    // MARK: - analyze: ineligible cases (general)

    @Test("A point from another operator is not eligible")
    func foreignOperatorNotEligible() throws {
        let source = "func f() -> Bool { true }"
        let points = try discover(source, path: "Sample.swift", using: Operators.boolLiteral)
        let mutation = try #require(points.first)
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        guard case .operatorNotYetLowered = reason else {
            Issue.record("expected .operatorNotYetLowered, got \(reason)")
            return
        }
    }

    @Test("A point whose anchor no longer matches the given source is not eligible")
    func anchorMismatchNotEligible() throws {
        let source = "func f(a: Int, b: Int) -> Int { a + b }"
        let mutation = try point(source, replacement: "-")
        let changed = "func f(a: Int, b: Int) -> Int { a  + b }" // extra space shifts offsets
        #expect(!lowerer.analyze(mutation, source: Data(changed.utf8)).isEligible)
    }

    @Test("An arithmetic expression inside a @ViewBuilder-style result-builder body is not eligible")
    func resultBuilderBodyNotEligible() throws {
        let source = """
        @ViewBuilder
        func f(a: Int, b: Int) -> Bool {
            if a + b > 0 {
                true
            }
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.originalText == "+" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .resultBuilderBody)
    }

    @Test("A function-call operand falls back to isolated")
    func functionCallOperandFallsBack() throws {
        let source = "func lhs() -> Int { 1 }\nfunc f(b: Int) -> Int { lhs() + b }"
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        guard case .unsupportedOperand = reason else {
            Issue.record("expected .unsupportedOperand, got \(reason)")
            return
        }
    }

    @Test("A subscript operand falls back to isolated")
    func subscriptOperandFallsBack() throws {
        let source = "func f(a: [Int], b: Int) -> Int { a[0] + b }"
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        guard case .unsupportedOperand = reason else {
            Issue.record("expected .unsupportedOperand, got \(reason)")
            return
        }
    }

    @Test("A try operand falls back to isolated")
    func tryOperandFallsBack() throws {
        let wrappedSource = "func f(a: Int, b: Int) throws -> Int { try (a + b) }"
        let wrappedMutation = try point(wrappedSource, replacement: "-")
        guard case let .isolatedOnly(wrappedReason) = lowerer.analyze(wrappedMutation, source: Data(wrappedSource.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(wrappedReason == .asyncOrThrowingExpression)
    }

    @Test("An await operand falls back to isolated")
    func awaitOperandFallsBack() throws {
        let wrappedSource = "func f(a: Int, b: Int) async -> Int { await (a + b) }"
        let wrappedMutation = try point(wrappedSource, replacement: "-")
        guard case let .isolatedOnly(reason) = lowerer.analyze(wrappedMutation, source: Data(wrappedSource.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .asyncOrThrowingExpression)
    }
}

// MARK: - analyze: type-variance risk (declared-type allowlist)

//
// Split into its own extension purely to keep `type_body_length` reviewable
// per declaration — still the same single suite, no behavioral split.
extension ArithmeticOperatorReplacementSchemataLowererTests {
    // Eligibility proves a *positive* allowlist (`safeArithmeticTypeNames`)
    // rather than excluding known-bad shapes one at a time — replacing an
    // earlier, looser design after a real isolated-vs-schemata differential
    // run against `apple/swift-algorithms` found a third asymmetric-+/-
    // shape (`UnsafeMutablePointer` supports `-` but not `pointer + pointer`)
    // that shape-exclusion missed entirely (see this file's own regression
    // test below and the type's doc comment).

    @Test("A + against a String literal operand falls back to isolated (unrecognized operand shape)")
    func plusOnStringLiteralFallsBack() throws {
        let source = #"func f(a: String) -> String { a + "suffix" }"#
        let mutation = try point(source, replacement: "-")
        #expect(!lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A + between two String-typed identifiers is not eligible (String is not on the safe-type allowlist)")
    func plusOnStringTypedIdentifiersNotEligible() throws {
        let source = "func f(a: String, b: String) -> String { a + b }"
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("""
    A - between two UnsafeMutablePointer-typed parameters is not eligible — \
    pointer - pointer compiles but pointer + pointer does not
    """)
    func minusOnUnsafeMutablePointerParametersNotEligible() throws {
        // Regression test for a real chunk-build failure this lowerer's
        // isolated-vs-schemata differential run found against
        // apple/swift-algorithms (Partition.swift:376,
        // `let lhsCount = lhs - bufferStart`): both `lhs`/`bufferStart` are
        // `UnsafeMutablePointer<Element>`, which supports `-` (a distance)
        // but not `+` between two pointers — the exact asymmetric-operator
        // shape a naive "AdditiveArithmetic always pairs +/-" assumption
        // misses, since UnsafeMutablePointer's +/- are ad hoc overloads, not
        // an AdditiveArithmetic conformance.
        let source = """
        func f<Element>(lhs: UnsafeMutablePointer<Element>, bufferStart: UnsafeMutablePointer<Element>) -> Int {
            lhs - bufferStart
        }
        """
        let mutation = try point(source, replacement: "+")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("An identifier with a genuinely unresolvable declared type (e.g. a function-call-initialized local) is not eligible")
    func unresolvableDeclaredTypeNotEligible() throws {
        // Unlike `let b = a` (now resolvable — `isProvablyInt` recursively
        // proves `a` itself is `Int`), a function-call initializer is
        // outside what `isProvablyInt`'s bounded, sound rule set (literals,
        // `.count`, +-*/ over already-Int operands, or another
        // Int-provable identifier) ever attempts — no return-type
        // information is available anywhere in this codebase.
        let source = """
        func f(a: Int) -> Int {
            let b = g()
            return a + b
        }
        func g() -> Int { 0 }
        """
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("A local variable with an explicit safe-type annotation is eligible")
    func explicitlyTypedLocalEligible() throws {
        let source = """
        func f(a: Int) -> Int {
            let b: Int = a
            return a + b
        }
        """
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A local variable with no type annotation but a provably-Int initializer is eligible")
    func provablyIntLocalEligible() throws {
        // Regression test for the real-corpus finding that led to restoring
        // local resolution: a real production app's own binary-search-query
        // source file's binary search
        // (`let mid = (low + high) / 2`, `low`/`high` themselves declared
        // `var low = 0` / `var high = terms.count - 1`) has no explicit type
        // annotation anywhere in this chain, yet every leaf is a literal,
        // `.count`, or another Int-provable identifier — `isProvablyInt`
        // proves it transitively.
        let source = """
        func f(terms: Int) -> Int {
            var low = 0
            var high = terms - 1
            let mid = (low + high) / 2
            return mid + 1
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.line == 5 && $0.originalText == "+" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        #expect(eligibility.isEligible)
    }

    @Test("A .count member access is provably Int, and stays eligible through an arithmetic chain")
    func countMemberAccessIsProvablyInt() throws {
        let source = """
        func f(values: [Int]) -> Int {
            let doubled = values.count * 2
            return doubled + 1
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.line == 3 && $0.originalText == "+" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        #expect(eligibility.isEligible)
    }

    @Test(".count on a custom, non-collection-typed base is not provably Int")
    func countOnNonCollectionTypeNotProvablyInt() throws {
        // Regression test for a High finding from an independent Codex
        // implementation review, round 4: `.count` was trusted as Int on
        // *any* base, but a user type is free to declare its own,
        // differently-typed `count` property — nothing about the bare
        // member-access syntax rules that out. `.count` is now trusted only
        // when the base's own declared type is a recognized standard-
        // library collection shape.
        let source = """
        struct S { var count: String }
        func f(_ s: S) -> String {
            let x = s.count + s.count
            return x + x
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.line == 4 && $0.originalText == "+" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        #expect(!eligibility.isEligible, "s.count is String-typed here, not Int — must not be assumed Int just because it's spelled .count")
    }

    @Test("A local declared after the reference must not resolve an earlier use of the same name")
    func laterDeclarationDoesNotResolveEarlierReference() throws {
        // Regression test for a High finding from an independent Codex
        // implementation review, round 4: local-item scanning considered
        // every item in the block regardless of position, so a `let a: Int`
        // declared *after* an earlier `a + a` (referring to the outer
        // String parameter) could incorrectly "resolve" that earlier
        // reference to Int.
        let source = """
        func f(a: String) -> String {
            let result = a + a
            let a: Int = 0
            _ = a
            return result
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.line == 2 && $0.originalText == "+" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        #expect(!eligibility.isEligible, "a later let a: Int must not resolve an earlier a + a referring to the outer String parameter")
    }

    @Test("A local declared before the reference correctly resolves it")
    func earlierDeclarationResolvesLaterReference() throws {
        let source = """
        func f() -> Int {
            let a: Int = 1
            return a + a
        }
        """
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A later declaration between an inner sub-reference and an outer use does not leak past its own scope")
    func laterDeclarationDoesNotLeakIntoRecursiveProof() throws {
        // Low finding from round-5 Codex re-verification: pin the
        // recursive-position case specifically, not just a single direct
        // reference. `mid`'s own initializer resolves `low` from `low`'s own
        // position (correctly finding the earlier `var low = 0`); a later,
        // unrelated `let low: String = "shadow"` declared *after* `mid` must
        // not affect that resolution, and must not leak into the later
        // `mid + 1` reference either (since `mid` itself, not `low`, is
        // referenced there).
        let source = """
        func f() -> Int {
            var low = 0
            let mid = low + 1
            let low: String = "shadow"
            _ = low
            return mid + 1
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.line == 6 && $0.originalText == "+" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        #expect(eligibility.isEligible, "mid was correctly proven Int from the earlier var low, unaffected by the later, unrelated shadow")
    }

    @Test("Multiple bindings in one let declaration are each resolved independently, sharing their declaration's position")
    func multipleBindingsInOneDeclarationResolveIndependently() throws {
        // Low finding from round-5 Codex re-verification: `let a = 1, b = 2`
        // is a single CodeBlockItemSyntax carrying two bindings — both must
        // still resolve correctly for a reference after the declaration.
        let source = """
        func f() -> Int {
            let a = 1, b = 2
            return a + b
        }
        """
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A for (index, _) in x.enumerated() loop's index is provably Int")
    func enumeratedForLoopIndexIsProvablyInt() throws {
        // Regression test for the real-corpus finding that led to this
        // special case: a real production app's own binary-header-parsing
        // source file (`value |= T(byte) << (8 *
        // index)` for `(index, byte) in bytes.enumerated()`) uses the
        // enumerated index directly in arithmetic — `EnumeratedSequence
        // .Iterator.Element == (offset: Int, element: Base.Element)` is a
        // fixed stdlib guarantee, not an inference.
        let source = """
        func f(bytes: [UInt8]) -> Int {
            var total = 0
            for (index, byte) in bytes.enumerated() {
                total += (8 * index) + Int(byte)
            }
            return total
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.originalText == "*" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        #expect(eligibility.isEligible)
    }

    @Test("A non-enumerated for-loop's tuple-pattern first element is still conservatively shadowed, not assumed Int")
    func nonEnumeratedForLoopTupleNotAssumedInt() throws {
        let source = """
        func f(a: Int, pairs: [(Int, Int)]) -> Int {
            for (a, b) in pairs {
                _ = a + b
            }
            return a
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.originalText == "+" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        let message = "a non-.enumerated() for-loop's tuple elements must not be assumed Int"
        #expect(!eligibility.isEligible, Comment(rawValue: message))
    }
}
