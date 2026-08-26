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

    // MARK: - ADR-0008 Addendum 4: pattern-position eligibility

    /// Real-corpus finding: a shared schemata chunk embedding a
    /// `switch (Bool, Bool) { case (true, false): ... }` failed to compile
    /// ("switch must be exhaustive") because this operator's literal
    /// selection changed the compiler-visible shape of a case pattern into
    /// a runtime expression, invalidating the compiler's exhaustiveness
    /// analysis. Every literal that is part of the *pattern* itself must be
    /// ineligible.
    @Test("Test A: every boolean literal in a switch case pattern is ineligible with reason .patternPosition")
    func caseA_ineligibleInSwitchCasePattern() throws {
        let source = """
        func f(_ a: Bool, _ b: Bool) -> Int {
            switch (a, b) {
            case (true, false):
                return 1
            default:
                return 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
            .sorted { $0.utf8Range.start < $1.utf8Range.start }
        #expect(points.count == 2, "the pattern's own `true` and `false`")
        for mutationPoint in points {
            let eligibility = lowerer.analyze(mutationPoint, source: Data(source.utf8))
            guard case let .isolatedOnly(reason) = eligibility else {
                Issue.record("expected .isolatedOnly, got \(eligibility) for \(mutationPoint.originalText)")
                continue
            }
            #expect(reason == .patternPosition)
        }
    }

    @Test("Test B: an ordinary boolean-literal expression remains schemata-eligible")
    func caseB_eligibleAsOrdinaryExpression() throws {
        let source = "let x = true\n"
        let mutationPoint = try point(source)
        #expect(lowerer.analyze(mutationPoint, source: Data(source.utf8)).isEligible)
    }

    @Test("Test C: a boolean literal in a switch case's body remains schemata-eligible")
    func caseC_eligibleInCaseBody() throws {
        let source = """
        func f(_ x: Int) -> Bool {
            switch x {
            case 1:
                return true
            default:
                return false
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
        #expect(points.count == 2, "the two `return` literals — the switch subject/case labels are Int, not Bool")
        for mutationPoint in points {
            #expect(lowerer.analyze(mutationPoint, source: Data(source.utf8)).isEligible, "\(mutationPoint.originalText) is in a case body, not a pattern")
        }
    }

    @Test("Test D: a boolean literal in a case's `where` expression remains schemata-eligible")
    func caseD_eligibleInWhereClause() throws {
        let source = """
        func f(_ x: Int, _ w: Bool) -> Int {
            switch x {
            case let y where w == true:
                return y
            default:
                return 0
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
        let mutationPoint = try #require(points.first, "the `true` in `w == true`")
        #expect(points.count == 1)
        #expect(
            lowerer.analyze(mutationPoint, source: Data(source.utf8)).isEligible,
            "a where-clause expression is not a pattern, merely because it sits under the same SwitchCase node as one"
        )
    }

    @Test("Test E: pattern exclusion is ancestor-structural, not only direct-parent — an enum-associated-value pattern nests the literal several levels below its ExpressionPatternSyntax ancestor")
    func caseE_patternExclusionIsAncestorStructuralNotJustDirectParent() throws {
        let source = """
        func f(_ x: Bool?) -> Int {
            if case .some(true) = x {
                return 1
            }
            return 0
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
        let mutationPoint = try #require(points.first, "the `true` inside `.some(true)`'s pattern")
        #expect(points.count == 1)
        let eligibility = lowerer.analyze(mutationPoint, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .patternPosition, "the literal's direct parent is a function-call/labeled-expr chain, not ExpressionPatternSyntax itself — only an ancestor walk finds it")
    }

    @Test("Test F: the existing result-builder exclusion is unaffected by the new pattern-position check")
    func caseF_resultBuilderExclusionUnchanged() throws {
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
        #expect(reason == .resultBuilderBody, "must still report the original reason, not .patternPosition")
    }

    // MARK: - ADR-0008 Addendum 4: the same structural predicate naturally covers if/guard/for case, with no special-casing

    @Test("`guard case` shares the identical ExpressionPatternSyntax grammar — its pattern literal is ineligible with no special-case code")
    func guardCasePatternLiteralIsIneligible() throws {
        let source = """
        func f(_ x: Bool) -> Int {
            guard case true = x else { return 0 }
            return 1
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
        let mutationPoint = try #require(points.first, "the `true` in `guard case true = x`")
        #expect(points.count == 1)
        let eligibility = lowerer.analyze(mutationPoint, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .patternPosition)
    }

    @Test("`for case` shares the identical ExpressionPatternSyntax grammar — its pattern literal is ineligible with no special-case code")
    func forCasePatternLiteralIsIneligible() throws {
        let source = """
        func f(_ values: [Bool]) {
            for case true in values {
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
        let mutationPoint = try #require(points.first, "the `true` in `for case true in values`")
        #expect(points.count == 1)
        let eligibility = lowerer.analyze(mutationPoint, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .patternPosition)
    }

    // MARK: - Control-flow-constant conditions (`while` / `repeat`-`while`)

    /// Real-corpus finding, `swift-async-algorithms` 2026-08: lowering the
    /// `true` in `} while true` inside a `-> Reduced?` method produced
    /// `error: missing return in instance method expected to return
    /// 'Reduced?'`. `while true` is provably infinite *only* while the
    /// condition is a compile-time constant; a runtime selector is not one,
    /// so the compiler starts demanding a `return` after the loop. That one
    /// site's failure cost its entire 93-member shared chunk its build, and
    /// with it the other 92 members' schemata fast path.
    @Test("Negative fixture: a boolean literal that is a `while` condition is ineligible with reason .controlFlowConstant")
    func whileConditionLiteralIsIneligible() throws {
        let source = """
        func f() -> Int {
            while true {
                return 1
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
        let mutationPoint = try #require(points.first, "the `true` in `while true`")
        #expect(points.count == 1)
        let eligibility = lowerer.analyze(mutationPoint, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .controlFlowConstant)
    }

    @Test("Negative fixture: a `repeat`-`while`'s own trailing condition literal is ineligible for the identical reason")
    func repeatWhileConditionLiteralIsIneligible() throws {
        let source = """
        func f() -> Int {
            repeat {
                return 1
            } while true
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
        let mutationPoint = try #require(points.first, "the `true` in `} while true`")
        #expect(points.count == 1)
        let eligibility = lowerer.analyze(mutationPoint, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .controlFlowConstant)
    }

    @Test("Negative fixture: parentheses are transparent — `while (true)` is still the literal as the condition")
    func parenthesizedWhileConditionLiteralIsIneligible() throws {
        let source = """
        func f() -> Int {
            while (true) {
                return 1
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
        let mutationPoint = try #require(points.first, "the `true` in `while (true)`")
        let eligibility = lowerer.analyze(mutationPoint, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .controlFlowConstant)
    }

    @Test("Positive fixture: a boolean literal in an ordinary expression inside a `while` *body* is still eligible")
    func literalInWhileBodyRemainsEligible() throws {
        let source = """
        func f(_ limit: Int) -> Bool {
            var flag = false
            var index = 0
            while index < limit {
                flag = true
                index += 1
            }
            return flag
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
        #expect(points.count == 2, "`var flag = false` and `flag = true` — neither is a loop condition")
        for mutationPoint in points {
            #expect(
                lowerer.analyze(mutationPoint, source: Data(source.utf8)).isEligible,
                "\(mutationPoint.originalText) sits in the loop's body, not in its condition"
            )
        }
    }

    @Test("""
    Positive fixture: a literal merely *nested* in a larger `while` condition stays eligible — \
    that condition was never a compile-time constant
    """)
    func literalNestedInsideALargerWhileConditionRemainsEligible() throws {
        let source = """
        func f(_ flag: Bool) -> Int {
            var count = 0
            while flag == true {
                count += 1
            }
            return count
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
        let mutationPoint = try #require(points.first, "the `true` in `flag == true`")
        #expect(points.count == 1)
        #expect(
            lowerer.analyze(mutationPoint, source: Data(source.utf8)).isEligible,
            """
            `while flag == true` is already runtime-evaluated, so the compiler never treated this loop as infinite — \
            lowering the literal changes no reachability fact, and excluding it would cost an eligible candidate for nothing
            """
        )
    }

    @Test("Positive fixture: an `if` condition literal is unaffected — only loops carry the provably-infinite reachability rule")
    func ifConditionLiteralRemainsEligible() throws {
        let source = """
        func f() -> Int {
            if true {
                return 1
            }
            return 0
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: BoolLiteralInversionOperator.descriptor.id)
        let mutationPoint = try #require(points.first, "the `true` in `if true`")
        #expect(lowerer.analyze(mutationPoint, source: Data(source.utf8)).isEligible)
    }

    @Test("The existing pattern-position and result-builder exclusions are unaffected by the new control-flow check")
    func existingExclusionsUnchangedByControlFlowCheck() throws {
        let patternSource = """
        func f(_ x: Bool) -> Int {
            switch x {
            case true:
                return 1
            default:
                return 0
            }
        }
        """
        let patternPoints = try CoreOperatorExpansionTestSupport.discover(
            patternSource, operatorID: BoolLiteralInversionOperator.descriptor.id
        )
        let patternPoint = try #require(patternPoints.first)
        guard case let .isolatedOnly(patternReason) = lowerer.analyze(patternPoint, source: Data(patternSource.utf8)) else {
            Issue.record("expected .isolatedOnly for the case pattern")
            return
        }
        #expect(patternReason == .patternPosition, "must still report its own reason, not .controlFlowConstant")
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
