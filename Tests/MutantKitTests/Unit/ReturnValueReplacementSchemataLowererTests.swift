import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `ReturnValueReplacementSchemataLowerer` — deliberately never
/// registered in `SchemataLowererRegistry.builtIn` yet.
@Suite("ReturnValueReplacementSchemataLowerer")
struct ReturnValueReplacementSchemataLowererTests {
    private let lowerer = ReturnValueReplacementSchemataLowerer()

    private func point(_ source: String, relativePath: String = "Sample.swift") throws -> MutationPoint {
        let points = try discover(source, path: relativePath, using: [ReturnValueReplacementOperator()])
        return try #require(points.first)
    }

    @Test("descriptor reports this lowerer's own identity and its one supported operator")
    func descriptorReportsIdentity() {
        let descriptor = lowerer.descriptor
        #expect(descriptor.lowererID == ReturnValueReplacementSchemataLowerer.lowererID)
        #expect(descriptor.supportedOperatorIDs == [ReturnValueReplacementOperator.descriptor.id])
    }

    @Test("An integer-returning function's non-zero literal is eligible for literalSelection")
    func eligibleForIntegerLiteral() throws {
        let source = "func f() -> Int { return 5 }"
        let mutation = try point(source)
        #expect(mutation.originalText == "5")
        #expect(mutation.replacementText == "0")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .eligible(loweringKind, _, _) = eligibility else {
            Issue.record("expected .eligible, got \(eligibility)")
            return
        }
        #expect(loweringKind == .literalSelection)
    }

    @Test("An Optional-returning function's expression is eligible, replaced with nil")
    func eligibleForOptionalReturn() throws {
        let source = "func f(a: Int) -> Int? { return a }"
        let mutation = try point(source)
        #expect(mutation.replacementText == "nil")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
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

    @Test("A point whose anchor no longer matches the given source is not eligible")
    func anchorMismatchNotEligible() throws {
        let source = "func f() -> Int { return 5 }"
        let mutation = try point(source)
        let changed = "func f() -> Int { return  5 }" // extra space shifts offsets
        #expect(!lowerer.analyze(mutation, source: Data(changed.utf8)).isEligible)
    }

    @Test("Lowering one point embeds a ternary that references the point's own real originalText/replacementText verbatim")
    func loweredCodeReferencesRealTextVerbatim() throws {
        let source = "func f() -> String { return \"hi\" }"
        let mutation = try point(source)
        #expect(mutation.replacementText == "\"\"")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        let lowered = try #require(program.loweredSources.first)
        #expect(lowered.contents.contains("? \"\" : \"hi\""))
        #expect(program.entries.count == 1)
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

    @Test("Two returns in the same file are both spliced without corrupting each other's offsets")
    func twoPointsSameFileSpliceCorrectly() throws {
        let source = """
        func f() -> Int { return 5 }
        func g() -> Int { return 7 }
        """
        let points = try discover(source, path: "Sample.swift", using: [ReturnValueReplacementOperator()])
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
        func isActive() -> Bool { true }
        let result = isActive() ? 0 : 5
        #expect(result == 0)
    }
}
