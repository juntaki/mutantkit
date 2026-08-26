import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `UnaryNotRemovalSchemataLowerer` — deliberately never registered in
/// `SchemataLowererRegistry.builtIn` yet (see that type's own doc comment):
/// every test here constructs and calls the lowerer directly, the same seam
/// the eventual promotion commit will simply add to the registry, changing
/// no lowering logic.
@Suite("UnaryNotRemovalSchemataLowerer")
struct UnaryNotRemovalSchemataLowererTests {
    private let lowerer = UnaryNotRemovalSchemataLowerer()

    private func point(_ source: String, relativePath: String = "Sample.swift") throws -> MutationPoint {
        let points = try discover(source, path: relativePath, using: [UnaryNotRemovalOperator()])
        return try #require(points.first)
    }

    // MARK: - descriptor

    @Test("descriptor reports this lowerer's own identity and its one supported operator")
    func descriptorReportsIdentity() {
        let descriptor = lowerer.descriptor
        #expect(descriptor.lowererID == UnaryNotRemovalSchemataLowerer.lowererID)
        #expect(descriptor.lowererVersion == UnaryNotRemovalSchemataLowerer.lowererVersion)
        #expect(descriptor.runtimeABIVersion == UnaryNotRemovalSchemataLowerer.runtimeABIVersion)
        #expect(descriptor.supportedOperatorIDs == [UnaryNotRemovalOperator.descriptor.id])
    }

    // MARK: - analyze: eligible cases

    @Test("A negated plain identifier is eligible for expressionTernary")
    func eligibleForIdentifierOperand() throws {
        let source = "func f(a: Bool) -> Bool { !a }"
        let mutation = try point(source)
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .eligible(loweringKind, _, _) = eligibility else {
            Issue.record("expected .eligible, got \(eligibility)")
            return
        }
        #expect(loweringKind == .expressionTernary)
    }

    @Test("A simple member access (self.x) is eligible")
    func eligibleForSelfMemberAccess() throws {
        let source = """
        struct S {
            let x: Bool
            func f() -> Bool { !self.x }
        }
        """
        let mutation = try point(source)
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A parenthesized safe expression is eligible")
    func eligibleForParenthesizedOperand() throws {
        let source = "func f(a: Bool) -> Bool { !(a) }"
        let mutation = try point(source)
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A genuine double negation written as two separate ! tokens is eligible, recursively")
    func eligibleForNestedNegation() throws {
        let source = "func f(a: Bool) -> Bool { !(!a) }"
        let points = try discover(source, path: "Sample.swift", using: [UnaryNotRemovalOperator()])
        #expect(points.count == 2, "the outer ! and the inner ! are each their own independent site")
        for mutation in points {
            #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible, "\(mutation.originalText) must be eligible")
        }
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
        let source = "func f(a: Bool) -> Bool { !a }"
        let mutation = try point(source)
        let changed = "func f(a: Bool) -> Bool { ! a }" // extra space shifts offsets
        #expect(!lowerer.analyze(mutation, source: Data(changed.utf8)).isEligible)
    }

    @Test("A negation inside a @ViewBuilder-style result-builder body is not eligible")
    func resultBuilderBodyNotEligible() throws {
        let source = """
        @ViewBuilder
        func f(a: Bool) -> Bool {
            if !a {
                true
            }
        }
        """
        let mutation = try point(source)
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .resultBuilderBody)
    }

    @Test("A function-call operand falls back to isolated — the common `!isValid()` shape")
    func functionCallOperandFallsBack() throws {
        let source = "func isValid() -> Bool { true }\nfunc f() -> Bool { !isValid() }"
        let mutation = try point(source)
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
        let wrappedSource = "func f(a: Bool) throws -> Bool { try (!a) }"
        let wrappedMutation = try point(wrappedSource)
        guard case let .isolatedOnly(reason) = lowerer.analyze(wrappedMutation, source: Data(wrappedSource.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .asyncOrThrowingExpression)
    }

    @Test("An await operand falls back to isolated")
    func awaitOperandFallsBack() throws {
        let wrappedSource = "func f(a: Bool) async -> Bool { await (!a) }"
        let wrappedMutation = try point(wrappedSource)
        guard case let .isolatedOnly(reason) = lowerer.analyze(wrappedMutation, source: Data(wrappedSource.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .asyncOrThrowingExpression)
    }

    // MARK: - lower(_:sources:): structural correctness

    @Test("Lowering one point embeds a ternary that references the point's own real originalText/replacementText verbatim")
    func loweredCodeReferencesRealOperatorTextVerbatim() throws {
        let source = "func f(a: Bool) -> Bool { !a }"
        let mutation = try point(source)
        #expect(mutation.originalText == "!a")
        #expect(mutation.replacementText == "a")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        let lowered = try #require(program.loweredSources.first)
        #expect(lowered.contents.contains("(a)"), "must reference the real, discovered replacementText")
        #expect(lowered.contents.contains("(!a)"), "must reference the real, discovered originalText")
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
        let source = "func f(a: Bool) -> Bool { !a }"
        let mutation = try point(source)
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation, mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        }
    }

    @Test("A point whose file is missing from sources makes lower(_:sources:) throw")
    func missingSourceThrows() throws {
        let source = "func f(a: Bool) -> Bool { !a }"
        let mutation = try point(source)
        let chunk = SchemataChunk(chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod")
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Other.swift", contents: source)])
        }
    }

    @Test("Two negations in the same file are both spliced without corrupting each other's offsets")
    func twoPointsSameFileSpliceCorrectly() throws {
        let source = """
        func f(a: Bool, b: Bool) -> Bool {
            let x = !a
            let y = !b
            return x && y
        }
        """
        let points = try discover(source, path: "Sample.swift", using: [UnaryNotRemovalOperator()])
        #expect(points.count == 2)
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: points, projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        #expect(program.entries.count == 2)
        #expect(parsesWithoutError(Data(program.loweredSources[0].contents.utf8)), "lowered output must remain syntactically valid Swift")
    }

    // MARK: - Evaluation count

    @Test("A ternary conditional evaluates only its selected branch, never both")
    func ternarySelectsOnlyOneBranchAtRuntime() {
        var evaluations = 0
        func a() -> Bool { evaluations += 1; return true }

        func isActive() -> Bool { true }
        _ = isActive() ? a() : !a()

        #expect(evaluations == 1, "the operand must be evaluated exactly once regardless of which branch's text is selected")
    }
}
