import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `TernaryBranchSwapSchemataLowerer` — deliberately never registered
/// in `SchemataLowererRegistry.builtIn` yet.
@Suite("TernaryBranchSwapSchemataLowerer")
struct TernaryBranchSwapSchemataLowererTests {
    private let lowerer = TernaryBranchSwapSchemataLowerer()

    private func point(_ source: String, relativePath: String = "Sample.swift") throws -> MutationPoint {
        let points = try discover(source, path: relativePath, using: [TernaryBranchSwapOperator()])
        return try #require(points.first)
    }

    @Test("descriptor reports this lowerer's own identity and its one supported operator")
    func descriptorReportsIdentity() {
        let descriptor = lowerer.descriptor
        #expect(descriptor.lowererID == TernaryBranchSwapSchemataLowerer.lowererID)
        #expect(descriptor.supportedOperatorIDs == [TernaryBranchSwapOperator.descriptor.id])
    }

    @Test("A ternary of plain identifiers is eligible for expressionTernary")
    func eligibleForIdentifierBranches() throws {
        let source = "func f(cond: Bool, a: Int, b: Int) -> Int { cond ? a : b }"
        let mutation = try point(source)
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .eligible(loweringKind, _, _) = eligibility else {
            Issue.record("expected .eligible, got \(eligibility)")
            return
        }
        #expect(loweringKind == .expressionTernary)
    }

    @Test("A point from another operator is not eligible")
    func foreignOperatorNotEligible() throws {
        let source = "func f() -> Bool { true }"
        let points = try discover(source, path: "Sample.swift", using: Operators.boolLiteral)
        let mutation = try #require(points.first)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        guard case .operatorNotYetLowered = reason else {
            Issue.record("expected .operatorNotYetLowered, got \(reason)")
            return
        }
    }

    @Test("A function-call condition falls back to isolated")
    func functionCallConditionFallsBack() throws {
        let source = "func isReady() -> Bool { true }\nfunc f(a: Int, b: Int) -> Int { isReady() ? a : b }"
        let mutation = try point(source)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        guard case .unsupportedOperand = reason else {
            Issue.record("expected .unsupportedOperand, got \(reason)")
            return
        }
    }

    @Test("A function-call then-branch falls back to isolated")
    func functionCallThenBranchFallsBack() throws {
        let source = "func computeA() -> Int { 1 }\nfunc f(cond: Bool, b: Int) -> Int { cond ? computeA() : b }"
        let mutation = try point(source)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        guard case .unsupportedOperand = reason else {
            Issue.record("expected .unsupportedOperand, got \(reason)")
            return
        }
    }

    @Test("A negation inside a @ViewBuilder-style result-builder body is not eligible")
    func resultBuilderBodyNotEligible() throws {
        let source = """
        @ViewBuilder
        func f(cond: Bool, a: Int, b: Int) -> Int {
            if true {
                cond ? a : b
            }
        }
        """
        let mutation = try point(source)
        guard case let .isolatedOnly(reason) = lowerer.analyze(mutation, source: Data(source.utf8)) else {
            Issue.record("expected .isolatedOnly")
            return
        }
        #expect(reason == .resultBuilderBody)
    }

    @Test("Lowering one point embeds a ternary that references the point's own real originalText/replacementText verbatim")
    func loweredCodeReferencesRealTextVerbatim() throws {
        let source = "func f(cond: Bool, a: Int, b: Int) -> Int { cond ? a : b }"
        let mutation = try point(source)
        #expect(mutation.originalText == "cond ? a : b")
        #expect(mutation.replacementText == "cond ? b : a")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        let lowered = try #require(program.loweredSources.first)
        #expect(lowered.contents.contains("(cond ? b : a)"))
        #expect(lowered.contents.contains("(cond ? a : b)"))
        #expect(program.entries.count == 1)
    }

    @Test("An empty chunk makes lower(_:sources:) throw")
    func emptyChunkThrows() throws {
        let chunk = SchemataChunk(chunkID: "chunk-1", points: [], projectIdentity: "P", target: "T", module: "M", product: "Prod")
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [])
        }
    }

    @Test("Two ternaries in the same file are both spliced without corrupting each other's offsets")
    func twoPointsSameFileSpliceCorrectly() throws {
        let source = """
        func f(cond: Bool, a: Int, b: Int, c: Int, d: Int) -> Int {
            let x = cond ? a : b
            let y = cond ? c : d
            return x + y
        }
        """
        let points = try discover(source, path: "Sample.swift", using: [TernaryBranchSwapOperator()])
        #expect(points.count == 2)
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: points, projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        #expect(program.entries.count == 2)
        #expect(parsesWithoutError(Data(program.loweredSources[0].contents.utf8)))
    }

    @Test("A ternary conditional evaluates only its selected branch, never both")
    func ternarySelectsOnlyOneBranchAtRuntime() {
        var conditionEvaluations = 0
        var aEvaluations = 0
        var bEvaluations = 0
        func cond() -> Bool { conditionEvaluations += 1; return true }
        func a() -> Int { aEvaluations += 1; return 1 }
        func b() -> Int { bEvaluations += 1; return 2 }

        func isActive() -> Bool { true }
        _ = isActive() ? (cond() ? b() : a()) : (cond() ? a() : b())

        #expect(conditionEvaluations == 1)
        #expect(aEvaluations + bEvaluations == 1, "only the branch the (single) condition evaluation selects may run")
    }
}
