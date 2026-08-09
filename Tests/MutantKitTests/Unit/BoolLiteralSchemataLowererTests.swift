import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `BoolLiteralSchemataLowerer`, the first concrete `SchemataLowerer`:
/// eligibility for its own operator only (and only in a syntax context a
/// selector-wrapped rewrite is actually safe for), deterministic namespace-
/// qualified selector tokens, descending-offset splicing so multiple points
/// in one file don't invalidate each other's byte ranges, content-addressed
/// per-chunk `sourceEmbeddingID`s that stay stable across unrelated chunks, and the
/// fail-closed invariant checks `lower(_:sources:)` runs as the last line of
/// defense against a chunk-planner bug.
@Suite("BoolLiteralSchemataLowerer")
struct BoolLiteralSchemataLowererTests {
    private let lowerer = BoolLiteralSchemataLowerer()

    private func point(_ source: String, relativePath: String = "Sample.swift") throws -> MutationPoint {
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: relativePath
        )
        return try #require(points.first)
    }

    // MARK: - descriptor

    @Test("descriptor reports this lowerer's own identity and its one supported operator")
    func descriptorReportsIdentity() {
        let descriptor = lowerer.descriptor
        #expect(descriptor.lowererID == BoolLiteralSchemataLowerer.lowererID)
        #expect(descriptor.lowererVersion == BoolLiteralSchemataLowerer.lowererVersion)
        #expect(descriptor.runtimeABIVersion == BoolLiteralSchemataLowerer.runtimeABIVersion)
        #expect(descriptor.supportedOperatorIDs == [BoolLiteralInversionOperator.descriptor.id])
    }

    // MARK: - analyze

    @Test("A bool-literal-inversion point in an ordinary context is eligible for literalSelection")
    func eligibleForOwnOperator() throws {
        // A function body, not a bare top-level `let` — the latter is a
        // module-scope binding, memoized once, and correctly ineligible
        // (see `ineligibleInStartupOnlyGlobalInitializer` below).
        let source = "func flag() -> Bool { true }\n"
        let mutationPoint = try point(source)
        let eligibility = lowerer.analyze(mutationPoint, source: Data(source.utf8))
        guard case let .eligible(loweringKind, rewriteEnvelope, conflictKeys) = eligibility else {
            Issue.record("expected .eligible, got \(eligibility)")
            return
        }
        #expect(loweringKind == .literalSelection)
        #expect(rewriteEnvelope == mutationPoint.utf8Range)
        #expect(conflictKeys.isEmpty)
    }

    @Test("A point from another operator is not eligible")
    func ineligibleForOtherOperator() throws {
        let source = "func add(_ a: Int, _ b: Int) -> Int { a + b }\n"
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: "swift.core.arithmetic-operator-replacement"
        )
        let foreignPoint = try #require(points.first)
        let eligibility = lowerer.analyze(foreignPoint, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .operatorNotYetLowered(operatorID: "swift.core.arithmetic-operator-replacement"))
    }

    @Test("A point whose anchor no longer matches the given source is not eligible")
    func ineligibleOnStaleAnchor() throws {
        let originalSource = "let flag = true\n"
        let mutationPoint = try point(originalSource)
        let staleSource = "let flag = true // changed\n"
        let eligibility = lowerer.analyze(mutationPoint, source: Data(staleSource.utf8))
        #expect(!eligibility.isEligible)
    }

    @Test("A boolean literal inside a @ViewBuilder-style result-builder body is not eligible")
    func ineligibleInsideResultBuilderBody() throws {
        let source = """
        @ViewBuilder
        func rows() -> Int {
            if true {
                1
            }
        }
        """
        let mutationPoint = try point(source)
        let eligibility = lowerer.analyze(mutationPoint, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .resultBuilderBody)
    }

    @Test("A boolean literal in a module-scope static/global let initializer is still eligible")
    func eligibleInModuleScopeInitializer() throws {
        // S6 originally excluded this (see git history) on the assumption
        // that a memoized-once value would let one test's activation
        // silently leak into another's result. That assumption depended on
        // a many-mutants-per-process execution model this codebase never
        // adopted — every mutant gets its own fresh process, with its one
        // requested token fixed for that process's entire lifetime before
        // it even launches, so a memoized value here is computed exactly
        // once *with that token already active*. See ADR-0003's
        // correction addendum.
        let source = "let featureEnabled = true\n"
        let mutationPoint = try point(source)
        let eligibility = lowerer.analyze(mutationPoint, source: Data(source.utf8))
        #expect(eligibility.isEligible)
    }

    // MARK: - lower: single point

    @Test("Lowering one point wraps it in a namespaced runtime selector and records one entry")
    func lowersSinglePoint() throws {
        let source = "let flag = true\n"
        let mutationPoint = try point(source)
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutationPoint], projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])

        #expect(program.chunkID == "chunk-1")
        #expect(!program.sourceEmbeddingID.isEmpty)
        #expect(program.entries.count == 1)
        let entry = try #require(program.entries.first)
        #expect(entry.mutationID == mutationPoint.id)
        #expect(entry.chunkID == "chunk-1")
        #expect(entry.selectorToken == SchemataSelectorToken(namespace: chunk.namespace, localIndex: 1))
        #expect(entry.sourceEmbeddingID == program.sourceEmbeddingID)
        #expect(entry.lowererID == BoolLiteralSchemataLowerer.lowererID)
        #expect(entry.lowererVersion == BoolLiteralSchemataLowerer.lowererVersion)
        #expect(entry.fallbackReason == nil)
        #expect(entry.target == "App")
        #expect(entry.module == "App")
        #expect(entry.product == "App.app")

        let lowered = try #require(program.loweredSources.first { $0.relativePath == "Sample.swift" })
        // The literal source-embedding/compilation-unit hex values are
        // derived, not something this test can predict independently
        // without reimplementing the lowerer -- checked structurally
        // instead: the shared declarations, exactly one descriptor
        // registration, and the call site referencing that same
        // descriptor by name.
        #expect(lowered.contents.contains(BoolLiteralSchemataLowerer.sharedDeclarationPreamble))
        #expect(lowered.contents.contains("@usableFromInline"))
        #expect(lowered.contents.contains("let __mutantkitUnitDescriptor_"))
        #expect(lowered.contents.contains("__mutantkitRegisterUnitV3(source, unit)"))
        let expectedCallSitePattern = #/__mutantkitIsActiveV3\(__mutantkitUnitDescriptor_[0-9a-f]{12}, \d+, 1\) \? false : true/#
        #expect(lowered.contents.contains(expectedCallSitePattern))
        #expect(program.loweredSources.count == 1, "the declaration is prepended in place, no new file is created")

        // `prependedLineCount` must match the declaration's own real line
        // count, not a hardcoded guess — computed here the same way a real
        // consumer would: count the lines the built file has beyond the
        // original, and confirm the two agree.
        let originalLineCount = source.filter { $0 == "\n" }.count
        let loweredLineCount = lowered.contents.filter { $0 == "\n" }.count
        #expect(lowered.prependedLineCount == loweredLineCount - originalLineCount)
        #expect(lowered.prependedLineCount > 0, "the declaration is at least one real line")
    }

    @Test("Two chunks built from the identical mutation set have distinct namespaces and artifact IDs")
    func distinctChunksHaveDistinctNamespacesAndArtifactIDs() throws {
        let source = "let flag = true\n"
        let mutationPoint = try point(source)
        let sources = [SchemataSourceFile(relativePath: "Sample.swift", contents: source)]

        let chunkA = SchemataChunk(
            chunkID: "chunk-a", points: [mutationPoint], projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )
        let chunkB = SchemataChunk(
            chunkID: "chunk-b", points: [mutationPoint], projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )

        #expect(chunkA.namespace != chunkB.namespace)

        let programA = try lowerer.lower(chunkA, sources: sources)
        let programB = try lowerer.lower(chunkB, sources: sources)
        #expect(programA.sourceEmbeddingID != programB.sourceEmbeddingID)
    }

    // MARK: - lower: multiple points in one file

    @Test("Two points in the same file are both spliced without corrupting each other's offsets")
    func lowersTwoPointsInSameFile() throws {
        let source = """
        let a = true
        let b = false
        """
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: BoolLiteralInversionOperator.descriptor.id
        )
        #expect(points.count == 2)
        let chunk = SchemataChunk(
            chunkID: "chunk-2", points: points, projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])

        #expect(program.entries.count == 2)
        let localIndices = Set(program.entries.compactMap { $0.selectorToken?.localIndex })
        #expect(localIndices == [1, 2])
        #expect(Set(program.entries.compactMap(\.selectorToken)).count == 2, "tokens must be unique within the chunk")

        let lowered = try #require(program.loweredSources.first { $0.relativePath == "Sample.swift" })
        // Both points are in the same file, so they share one descriptor
        // registration (one compilation unit) -- exactly one, not two.
        let descriptorCount = lowered.contents.components(separatedBy: "let __mutantkitUnitDescriptor_").count - 1
        #expect(descriptorCount == 1, "two points in the same file share one compilation-unit descriptor")
        #expect(lowered.contents.contains(#/__mutantkitIsActiveV3\(__mutantkitUnitDescriptor_[0-9a-f]{12}, \d+, 1\) \? false : true/#))
        #expect(lowered.contents.contains(#/__mutantkitIsActiveV3\(__mutantkitUnitDescriptor_[0-9a-f]{12}, \d+, 2\) \? true : false/#))
    }

    // MARK: - lower: untouched files pass through

    @Test("A source file with no points in the chunk is returned unchanged")
    func untouchedFilePassesThroughVerbatim() throws {
        let source = "let flag = true\n"
        let mutationPoint = try point(source, relativePath: "A.swift")
        let untouched = SchemataSourceFile(relativePath: "B.swift", contents: "let x = 1\n")
        let chunk = SchemataChunk(
            chunkID: "chunk-3", points: [mutationPoint], projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )
        let program = try lowerer.lower(
            chunk,
            sources: [SchemataSourceFile(relativePath: "A.swift", contents: source), untouched]
        )

        let passthrough = try #require(program.loweredSources.first { $0.relativePath == "B.swift" })
        #expect(passthrough.contents == "let x = 1\n")
        #expect(passthrough.prependedLineCount == 0, "B.swift never received the declaration, so its lines are unshifted")

        let declarationFile = try #require(program.loweredSources.first { $0.relativePath == "A.swift" })
        #expect(declarationFile.prependedLineCount > 0, "A.swift sorts first, so it carries the declaration")
    }

    // MARK: - lower: failure modes

    @Test("A point from another operator makes lower(_:sources:) throw")
    func lowerThrowsOnUnsupportedOperator() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            "func add(_ a: Int, _ b: Int) -> Int { a + b }\n",
            operatorID: "swift.core.arithmetic-operator-replacement"
        )
        let foreignPoint = try #require(points.first)
        let chunk = SchemataChunk(
            chunkID: "chunk-4", points: [foreignPoint], projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )

        do {
            _ = try lowerer.lower(chunk, sources: [])
            Issue.record("expected lower(_:sources:) to throw")
        } catch let error as SchemataLoweringError {
            #expect(error == .unsupportedOperator(operatorID: foreignPoint.operatorID))
        }
    }

    @Test("A point whose file is missing from sources makes lower(_:sources:) throw")
    func lowerThrowsOnMissingSource() throws {
        let mutationPoint = try point("let flag = true\n", relativePath: "Missing.swift")
        let chunk = SchemataChunk(
            chunkID: "chunk-5", points: [mutationPoint], projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )

        do {
            _ = try lowerer.lower(chunk, sources: [])
            Issue.record("expected lower(_:sources:) to throw")
        } catch let error as SchemataLoweringError {
            #expect(error == .missingSource(file: "Missing.swift"))
        }
    }

    @Test("A point whose anchor no longer matches the source makes lower(_:sources:) throw")
    func lowerThrowsOnStaleAnchor() throws {
        let originalSource = "let flag = true\n"
        let mutationPoint = try point(originalSource)
        let staleSource = "let flag = true // changed\n"
        let chunk = SchemataChunk(
            chunkID: "chunk-6", points: [mutationPoint], projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )

        do {
            _ = try lowerer.lower(
                chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: staleSource)]
            )
            Issue.record("expected lower(_:sources:) to throw")
        } catch is SchemataLoweringError {
            // Expected — the exact failures list is `SourceAnchorVerifier`'s own concern.
        }
    }

    @Test("An empty chunk makes lower(_:sources:) throw")
    func lowerThrowsOnEmptyChunk() throws {
        let chunk = SchemataChunk(
            chunkID: "chunk-7", points: [], projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )

        do {
            _ = try lowerer.lower(chunk, sources: [])
            Issue.record("expected lower(_:sources:) to throw")
        } catch let error as SchemataLoweringError {
            #expect(error == .emptyChunk)
        }
    }

    @Test("A duplicate MutationID in the same chunk makes lower(_:sources:) throw")
    func lowerThrowsOnDuplicateMutationID() throws {
        let source = "let flag = true\n"
        let mutationPoint = try point(source)
        let chunk = SchemataChunk(
            chunkID: "chunk-8", points: [mutationPoint, mutationPoint],
            projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )

        do {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
            Issue.record("expected lower(_:sources:) to throw")
        } catch let error as SchemataLoweringError {
            #expect(error == .duplicateMutationID(mutationPoint.id))
        }
    }

    @Test("A duplicate source path makes lower(_:sources:) throw")
    func lowerThrowsOnDuplicateSourcePath() throws {
        let source = "let flag = true\n"
        let mutationPoint = try point(source)
        let chunk = SchemataChunk(
            chunkID: "chunk-9", points: [mutationPoint], projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )
        let duplicated = [
            SchemataSourceFile(relativePath: "Sample.swift", contents: source),
            SchemataSourceFile(relativePath: "Sample.swift", contents: source)
        ]

        do {
            _ = try lowerer.lower(chunk, sources: duplicated)
            Issue.record("expected lower(_:sources:) to throw")
        } catch let error as SchemataLoweringError {
            #expect(error == .duplicateSourcePath("Sample.swift"))
        }
    }

    @Test("Two points with overlapping byte ranges in the same file make lower(_:sources:) throw")
    func lowerThrowsOnOverlappingRewriteEnvelopes() throws {
        let source = "let flag = true\n"
        let mutationPoint = try point(source)
        // A second, distinct MutationPoint whose range fully overlaps the
        // first's — not something real discovery would ever produce for the
        // identical operator/site, but exactly the shape a chunk-planner bug
        // (assigning the same site to a chunk twice under different
        // synthetic IDs) could.
        let overlapping = MutationPoint(
            id: MutationID(rawValue: "mut_overlap0000overlap"),
            file: mutationPoint.file,
            enclosingDeclaration: mutationPoint.enclosingDeclaration,
            operatorID: mutationPoint.operatorID,
            operatorVersion: mutationPoint.operatorVersion,
            occurrenceIndex: mutationPoint.occurrenceIndex,
            utf8Range: mutationPoint.utf8Range,
            originalText: mutationPoint.originalText,
            replacementText: mutationPoint.replacementText,
            prefixTokenFingerprint: mutationPoint.prefixTokenFingerprint,
            suffixTokenFingerprint: mutationPoint.suffixTokenFingerprint,
            sourceFileHash: mutationPoint.sourceFileHash,
            expectedSyntaxKind: mutationPoint.expectedSyntaxKind,
            confidence: mutationPoint.confidence,
            executionMode: mutationPoint.executionMode,
            line: mutationPoint.line,
            column: mutationPoint.column
        )
        let chunk = SchemataChunk(
            chunkID: "chunk-10", points: [mutationPoint, overlapping],
            projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )

        do {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
            Issue.record("expected lower(_:sources:) to throw")
        } catch let error as SchemataLoweringError {
            guard case .overlappingRewriteEnvelopes = error else {
                Issue.record("expected .overlappingRewriteEnvelopes, got \(error)")
                return
            }
        }
    }
}
