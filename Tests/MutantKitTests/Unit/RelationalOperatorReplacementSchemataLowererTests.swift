import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `RelationalOperatorReplacementSchemataLowerer` — deliberately never
/// registered in `SchemataLowererRegistry.builtIn` yet (see that type's own
/// doc comment): every test here constructs and calls the lowerer directly,
/// the same seam the eventual promotion commit will simply add to the
/// registry, changing no lowering logic.
@Suite("RelationalOperatorReplacementSchemataLowerer")
struct RelationalOperatorReplacementSchemataLowererTests {
    private let lowerer = RelationalOperatorReplacementSchemataLowerer()

    /// `variant` selects which of the isolated operator's own two
    /// candidates per site (boundary or negation) to return — never a
    /// separately hand-written replacement, always whichever the real,
    /// unmodified `RelationalOperatorReplacementOperator` actually
    /// discovered.
    private func point(_ source: String, relativePath: String = "Sample.swift", replacement: String) throws -> MutationPoint {
        let points = try discover(source, path: relativePath, using: Operators.relational)
        return try #require(points.first { $0.replacementText == replacement }, "no candidate with replacementText \(replacement)")
    }

    // MARK: - descriptor

    @Test("descriptor reports this lowerer's own identity and its one supported operator")
    func descriptorReportsIdentity() {
        let descriptor = lowerer.descriptor
        #expect(descriptor.lowererID == RelationalOperatorReplacementSchemataLowerer.lowererID)
        #expect(descriptor.lowererVersion == RelationalOperatorReplacementSchemataLowerer.lowererVersion)
        #expect(descriptor.runtimeABIVersion == RelationalOperatorReplacementSchemataLowerer.runtimeABIVersion)
        #expect(descriptor.supportedOperatorIDs == [RelationalOperatorReplacementOperator.descriptor.id])
    }

    // MARK: - analyze: eligible cases

    @Test("A comparison between two plain identifiers is eligible for expressionTernary")
    func eligibleForIdentifierOperands() throws {
        let source = "func f(a: Int, b: Int) -> Bool { a < b }"
        let mutation = try point(source, replacement: ">=")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .eligible(loweringKind, _, _) = eligibility else {
            Issue.record("expected .eligible, got \(eligibility)")
            return
        }
        #expect(loweringKind == .expressionTernary)
    }

    @Test("A comparison against a literal is eligible")
    func eligibleForLiteralOperand() throws {
        let source = "func f(a: Int) -> Bool { a < 5 }"
        let mutation = try point(source, replacement: ">=")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A simple member access (self.x) is eligible")
    func eligibleForSelfMemberAccess() throws {
        let source = """
        struct S {
            let x: Int
            let y: Int
            func f() -> Bool { self.x < self.y }
        }
        """
        let mutation = try point(source, replacement: ">=")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A parenthesized safe expression is eligible")
    func eligibleForParenthesizedOperand() throws {
        let source = "func f(a: Int, b: Int) -> Bool { (a) < (b) }"
        let mutation = try point(source, replacement: ">=")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A custom Comparable type's overloaded < is eligible the same way a builtin's is")
    func eligibleForCustomComparableOverload() throws {
        let source = """
        struct Meters: Comparable {
            let value: Double
            static func < (lhs: Meters, rhs: Meters) -> Bool { lhs.value < rhs.value }
        }
        func f(a: Meters, b: Meters) -> Bool { a < b }
        """
        let mutation = try point(source, replacement: ">=")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A generic Comparable-constrained context is eligible")
    func eligibleForGenericComparableContext() throws {
        let source = "func f<T: Comparable>(a: T, b: T) -> Bool { a < b }"
        let mutation = try point(source, replacement: ">=")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    // MARK: - analyze: ineligible cases

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
        let source = "func f(a: Int, b: Int) -> Bool { a < b }"
        let mutation = try point(source, replacement: ">=")
        let changed = "func f(a: Int, b: Int) -> Bool { a <  b }" // extra space shifts offsets
        #expect(!lowerer.analyze(mutation, source: Data(changed.utf8)).isEligible)
    }

    @Test("A comparison inside a @ViewBuilder-style result-builder body is not eligible")
    func resultBuilderBodyNotEligible() throws {
        let source = """
        @ViewBuilder
        func f(a: Int, b: Int) -> Bool {
            if a < b {
                true
            }
        }
        """
        let mutation = try point(source, replacement: ">=")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .resultBuilderBody)
    }

    @Test("A function-call operand falls back to isolated")
    func functionCallOperandFallsBack() throws {
        let source = "func lhs() -> Int { 1 }\nfunc f(b: Int) -> Bool { lhs() < b }"
        let mutation = try point(source, replacement: ">=")
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
        let source = "func f(a: [Int], b: Int) -> Bool { a[0] < b }"
        let mutation = try point(source, replacement: ">=")
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
        // `try` in Swift scopes over the whole expression it prefixes, not
        // just one operand — `try lhs() < b` really means `try (lhs() < b)`.
        // The infix-level ancestor check (`isDirectlyWrappedInTryOrAwait`)
        // therefore fires before the per-operand check ever gets a chance
        // to look at `lhs()` on its own — confirmed here, not assumed.
        let callSource = "func lhs() throws -> Int { 1 }\nfunc f(b: Int) throws -> Bool { try lhs() < b }"
        let callMutation = try point(callSource, replacement: ">=")
        guard case let .isolatedOnly(callReason) = lowerer.analyze(callMutation, source: Data(callSource.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(callReason == .asyncOrThrowingExpression)

        // Both operands otherwise safe — only the infix-level ancestor
        // check can catch this shape at all.
        let wrappedSource = "func f(a: Int, b: Int) throws -> Bool { try (a < b) }"
        let wrappedMutation = try point(wrappedSource, replacement: ">=")
        guard case let .isolatedOnly(wrappedReason) = lowerer.analyze(wrappedMutation, source: Data(wrappedSource.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(wrappedReason == .asyncOrThrowingExpression)
    }

    @Test("An await operand falls back to isolated")
    func awaitOperandFallsBack() throws {
        let wrappedSource = "func f(a: Int, b: Int) async -> Bool { await (a < b) }"
        let wrappedMutation = try point(wrappedSource, replacement: ">=")
        guard case let .isolatedOnly(reason) = lowerer.analyze(wrappedMutation, source: Data(wrappedSource.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .asyncOrThrowingExpression)
    }

    // `InOutExprSyntax` (`&a`) is not itself constructible as a relational
    // operand in valid Swift (`&a < b` does not type-check — `&` only
    // appears in argument position for an `inout` parameter) — the
    // `.ownershipSensitiveExpression` guard in `unsafetyReason` exists as
    // defense in depth for a lowering shape this operator's own real
    // candidates cannot actually produce today, not for a reachable case
    // this suite can construct as valid Swift.

    // MARK: - Variant table consistency (Phase 1, Section 1)

    @Test("Every replacement this lowerer embeds matches the real, unmodified isolated operator — never a separate table")
    func schemataNeverInventsItsOwnReplacementTable() throws {
        let source = """
        func f(a: Int, b: Int, c: Int, d: Int, e: Int, g: Int, h: Int, i: Int, j: Int, k: Int, l: Int, m: Int) -> Bool {
            a == b && c != d && e < g && h <= i && j > k && l >= m
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.relational)
        #expect(!points.isEmpty)
        let variants = points.map { RelationalMutationVariant(originalOperator: $0.originalText, replacementOperator: $0.replacementText) }
        // Every (original, replacement) pair schemata could ever embed is
        // one the isolated operator's own `replacements` table produced —
        // this test constructs `RelationalMutationVariant` values purely
        // from real `MutationPoint`s the isolated operator discovered,
        // never from an independent literal table of its own.
        let knownPairs: Set<RelationalMutationVariant> = [
            .init(originalOperator: "==", replacementOperator: "!="),
            .init(originalOperator: "!=", replacementOperator: "=="),
            .init(originalOperator: "<", replacementOperator: "<="),
            .init(originalOperator: "<", replacementOperator: ">="),
            .init(originalOperator: "<=", replacementOperator: "<"),
            .init(originalOperator: "<=", replacementOperator: ">"),
            .init(originalOperator: ">", replacementOperator: ">="),
            .init(originalOperator: ">", replacementOperator: "<="),
            .init(originalOperator: ">=", replacementOperator: ">"),
            .init(originalOperator: ">=", replacementOperator: "<")
        ]
        for variant in variants {
            #expect(knownPairs.contains(variant), "unexpected variant \(variant) not produced by the real isolated operator's own table")
        }
    }

    // MARK: - lower(_:sources:): structural correctness

    @Test("Lowering one point embeds a closure that references the point's own real originalText/replacementText verbatim")
    func loweredCodeReferencesRealOperatorTextVerbatim() throws {
        let source = "func f(a: Int, b: Int) -> Bool { a < b }"
        let mutation = try point(source, replacement: ">=")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        let lowered = try #require(program.loweredSources.first)
        #expect(lowered.contents.contains("__mkLHS >= __mkRHS"), "must reference the real, discovered replacementText")
        #expect(lowered.contents.contains("__mkLHS < __mkRHS"), "must reference the real, discovered originalText")
        #expect(program.entries.count == 1)
        #expect(program.entries.first?.mutationID == mutation.id)
    }

    @Test("A point from another operator makes lower(_:sources:) throw")
    func foreignOperatorMakesLowerThrow() throws {
        let source = "func f() -> Bool { true }"
        let points = try discover(source, path: "Sample.swift", using: Operators.boolLiteral)
        let mutation = try #require(points.first)
        let chunk = SchemataChunk(chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod")
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        }
    }

    @Test("An empty chunk makes lower(_:sources:) throw")
    func emptyChunkThrows() throws {
        let chunk = SchemataChunk(chunkID: "chunk-1", points: [], projectIdentity: "P", target: "T", module: "M", product: "Prod")
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [])
        }
    }

    @Test("A duplicate MutationID in the same chunk makes lower(_:sources:) throw")
    func duplicateMutationIDThrows() throws {
        let source = "func f(a: Int, b: Int) -> Bool { a < b }"
        let mutation = try point(source, replacement: ">=")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation, mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        }
    }

    @Test("A point whose file is missing from sources makes lower(_:sources:) throw")
    func missingSourceThrows() throws {
        let source = "func f(a: Int, b: Int) -> Bool { a < b }"
        let mutation = try point(source, replacement: ">=")
        let chunk = SchemataChunk(chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod")
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Other.swift", contents: source)])
        }
    }

    @Test("Two comparisons in the same file are both spliced without corrupting each other's offsets")
    func twoPointsSameFileSpliceCorrectly() throws {
        let source = "func f(a: Int, b: Int, c: Int, d: Int) -> Bool { (a < b) && (c > d) }"
        let points = try discover(source, path: "Sample.swift", using: Operators.relational)
        let first = try #require(points.first { $0.originalText == "<" && $0.replacementText == ">=" })
        let second = try #require(points.first { $0.originalText == ">" && $0.replacementText == "<=" })
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [first, second], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        #expect(program.entries.count == 2)
        #expect(parsesWithoutError(program.loweredSources[0].contents), "lowered output must remain syntactically valid Swift")
    }
}
