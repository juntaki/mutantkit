import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

// MARK: - Implicit-self, .enumerated(), .count-inference, and ordering tests

//
// Split into its own file purely to keep file_length reviewable — still the
// same single suite, no behavioral split.
extension ArithmeticOperatorReplacementSchemataLowererTests {
    @Test("A bare (implicit-self) stored property reference resolves the same as an explicit self.x would")
    func implicitSelfPropertyResolvesLikeExplicitSelf() throws {
        // Regression test for the real-corpus finding that led to restoring
        // implicit-self resolution: apple/swift-algorithms' Split.swift
        // (`splitCount += 1` / `sequenceLength += 1`, referenced without
        // `self.` inside SplitSequence.Iterator.next()) is the far more
        // common Swift style than spelling `self.` explicitly.
        let source = """
        struct S {
            var count = 0
            mutating func f() -> Int {
                count + 1
            }
        }
        """
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("An implicit-self property is still resolved when referenced from a separate extension of its type")
    func implicitSelfPropertyResolvesAcrossExtensionBoundary() throws {
        // Regression test for the exact real-corpus shape
        // `apple/swift-algorithms`' Split.swift uses: the primary type
        // declares the stored property, but the mutation site is referenced
        // from a *separate* `extension` block — the only place a stored
        // property can ever be declared is the primary struct/class/enum
        // (Swift does not allow stored properties in extensions at all), so
        // this is the one shape `declaredType(ofStoredPropertyNamed:)`'s
        // simple ancestor walk cannot see without searching the file's
        // other top-level declarations.
        let source = """
        struct S {
            var count = 0
        }

        extension S {
            mutating func f() -> Int {
                count + 1
            }
        }
        """
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A nested type's implicit-self property resolves across an extension of its fully-dotted path")
    func implicitSelfPropertyResolvesAcrossExtensionOfNestedType() throws {
        // Regression test for the real known-hang site itself: Split.swift
        // declares `struct Iterator { var splitCount = 0 }` nested inside
        // `struct SplitSequence`, then references `splitCount` from a
        // separate `extension SplitSequence.Iterator: IteratorProtocol`.
        let source = """
        struct Outer {
            struct Inner {
                var count = 0
            }
        }

        extension Outer.Inner {
            mutating func f() -> Int {
                count + 1
            }
        }
        """
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("An ambiguous same-simple-name type elsewhere in the file does not cause a wrong cross-extension match")
    func ambiguousSameNameTypeDoesNotCauseWrongCrossExtensionMatch() throws {
        let source = """
        struct Unrelated {
            struct Inner {
                var count: String = ""
            }
        }

        struct Outer {
            struct Inner {
                var count = 0
            }
        }

        extension Outer.Inner {
            mutating func f() -> Int {
                count + 1
            }
        }
        """
        // The dotted-path resolver must find Outer.Inner specifically, not
        // an unrelated same-simple-name Inner elsewhere in the file (which
        // has a differently-typed, String, `count`) — still eligible here
        // because the *correct* Outer.Inner.count is Int.
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A type nested inside an extension of its parent (not the parent's own primary declaration) still resolves")
    func typeNestedInsideExtensionOfParentResolves() throws {
        // Regression test for the exact real-corpus shape that first
        // surfaced this gap: apple/swift-algorithms' Split.swift declares
        // `struct Iterator { ... }` inside `extension SplitSequence:
        // Sequence { struct Iterator { ... } }` — a *sibling* of the
        // primary `struct SplitSequence<Base: Sequence> { ... }`
        // declaration, not nested inside it. A synthetic test using the
        // simpler `struct Outer { struct Inner { ... } }` shape (see
        // `implicitSelfPropertyResolvesAcrossExtensionOfNestedType`)
        // originally passed while this exact real shape still failed —
        // this pins the actual gap, not just a simplified stand-in for it.
        let source = """
        struct Container<Element> {}

        extension Container: Sequence {
            struct Iterator {
                var position = 0
            }
        }

        extension Container.Iterator: IteratorProtocol {
            mutating func next() -> Int? {
                position + 1
            }
        }
        """
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A bare identifier that shadows an implicit-self property is not resolved as that property")
    func localShadowingImplicitSelfPropertyIsNotResolvedAsProperty() throws {
        let source = """
        struct S {
            var count: Int = 0
            func f() -> String {
                let count = "shadow"
                return count + count
            }
        }
        """
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        #expect(!eligibility.isEligible, "the local String `count` must shadow the Int property, not fall through to it")
    }

    @Test("Two bare literals are not eligible")
    func twoBareLiteralsNotEligible() throws {
        let source = "func f() -> Int { 1 + 2 }"
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("A literal paired with a proven-safe typed operand is eligible (accepted residual risk, see typeVarianceRisk's doc comment)")
    func literalPairedWithSafeTypedOperandEligible() throws {
        // Restored after real-corpus site inspection found every one of
        // this validation's three known-hang sites mixes a literal with an
        // Int-typed sibling — the round-3-found heterogeneous-overload risk
        // is accepted as a narrow, differential-tested residual, not
        // eliminated by design. See `typeVarianceRisk`'s own doc comment for
        // the full reasoning.
        let source = "func f(a: Int) -> Int { 5 + a }"
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A for-loop's own binding shadows an outer, differently-typed parameter of the same name")
    func forLoopBindingShadowsOuterParameter() throws {
        // Regression test for a High finding from an independent Codex
        // implementation review, round 2: an earlier version recognized
        // only `let`/`var` and parameters as name-introducing declarations,
        // so a `for a in values` loop's own `String` binding was invisible
        // to `nearestDeclaredType`, which walked straight past it to the
        // outer `a: Int` parameter and incorrectly proposed `a - a` on a
        // String.
        let source = """
        func f(a: Int, values: [String]) {
            for a in values {
                _ = a + a
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
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("A guard-let binding shadows an outer, differently-typed parameter of the same name")
    func guardLetBindingShadowsOuterParameter() throws {
        let source = """
        func f(a: Int, maybe: String?) -> Int {
            guard let a = maybe else { return 0 }
            return a + a
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.originalText == "+" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        #expect(!eligibility.isEligible)
    }

    @Test("A switch-case binding shadows an outer, differently-typed parameter of the same name")
    func switchCaseBindingShadowsOuterParameter() throws {
        let source = """
        enum E { case value(String) }
        func f(a: Int, e: E) -> Int {
            switch e {
            case let .value(a):
                return a + a
            }
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.originalText == "+" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        #expect(!eligibility.isEligible)
    }

    @Test("A closure capture-list binding shadows an outer, differently-typed variable of the same name")
    func closureCaptureShadowsOuterVariable() throws {
        // `a` inside the closure is the captured `String` `s` (`String + String`
        // is valid Swift, so `a + a` is a legitimate original candidate),
        // never the outer `Int` parameter — if the capture were not
        // recognized as a shadow, the walk would incorrectly resolve `a` to
        // the outer `Int` and mark this eligible.
        let source = """
        func f(a: Int, s: String) -> Int {
            let c: () -> String = { [a = s] in a + a }
            return c().count
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.originalText == "+" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("self.x resolving to a computed property is not eligible — a declared type is not evidence of a stored type")
    func selfComputedPropertyNotEligible() throws {
        // Regression test for a Low finding from the same round-2 review:
        // `declaredType(ofStoredPropertyNamed:near:)` must exclude any
        // property with an accessor block, not just accept any
        // `VariableDeclSyntax` in the type's member list regardless of
        // whether it is actually stored.
        let source = """
        struct S {
            var x: Int { 0 }
            func f() -> Int { self.x + self.x }
        }
        """
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("A tuple-destructuring local's binding shadows an outer, differently-typed parameter of the same name")
    func tupleDestructuringLocalShadowsOuterParameter() throws {
        // Regression test for a High finding from an independent Codex
        // implementation review, round 3: local-binding recognition only
        // matched a top-level `IdentifierPatternSyntax`, so `let (a, b) =
        // strings` was invisible and the walk fell through to the outer
        // `a: Int, b: Int` parameters.
        let source = """
        func f(a: Int, b: Int, strings: (String, String)) -> String {
            let (a, b) = strings
            return a + b
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.originalText == "+" })
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    // A local function declaration shadowing an outer parameter
    // (`introducesUnresolvedShadow`'s `FunctionDeclSyntax` check in
    // `nearestDeclaredType`) and a bare `catch`'s implicit `error` binding
    // (the same function's `CatchClauseSyntax` case) are both defense in
    // depth this file's own private resolution logic recognizes, but
    // neither is constructible as an *isolated-operator-discovered*
    // `analyze()` test case: a local function value and `any Error` both
    // lack any `+`/`-`/`*`/`/` overload, so the isolated operator's own
    // `BinaryOperatorExprSyntax` visitor can never produce a real candidate
    // whose bare-identifier operand denotes either shape in valid,
    // already-compiling Swift — there is no discoverable mutation this
    // specific defense could ever actually gate. Kept for robustness
    // against a future change to what the isolated operator considers a
    // candidate, not because a live gap exists today.

    @Test("An unrelated sibling block's same-named, differently-typed locals do not false-positively match")
    func unrelatedNestedBlockShadowingDoesNotFalsePositivelyMatch() throws {
        // Regression test for a High finding from an independent Codex
        // implementation review: an earlier version of `nearestDeclaredType`
        // flattened an entire enclosing scope's descendants regardless of
        // which nested block they lived in, so this valid String `+` was
        // incorrectly marked eligible — it found the unrelated `Int` locals
        // inside the sibling `if` block and proposed `a - b`, which does not
        // compile (String has no `-`). The `if` block here is a *sibling* of
        // `return a + b`, never its lexical ancestor, so its locals must
        // never be visible to this resolution.
        let source = """
        func f(a: String, b: String) -> String {
            if true {
                let a: Int = 0
                let b: Int = 0
                _ = a + b
            }
            return a + b
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let outerPlus = try #require(
            points.first { $0.line == 7 && $0.originalText == "+" },
            "expected to find the outer `return a + b`'s + candidate on line 7"
        )
        let eligibility = lowerer.analyze(outerPlus, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly (String has no -), got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("self.x resolves to the property's own declared type, never a same-named parameter's")
    func selfPropertyShadowedByDifferentlyTypedParameterResolvesToPropertyType() throws {
        // Regression test for the same review finding: `self.` is Swift's
        // own unambiguous "this is the instance member" disambiguation, so
        // `self.x + self.x` inside `f(x: Int)` must resolve `x` as the
        // struct's own `String` property, never the differently-typed `x:
        // Int` parameter that merely happens to share its name.
        let source = """
        struct S {
            let x: String
            func f(x: Int) -> String { self.x + self.x }
        }
        """
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly (String property has no -, despite an Int parameter of the same name), got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("A + against an Array literal operand falls back to isolated (already rejected as an unrecognized operand shape)")
    func plusOnArrayLiteralFallsBack() throws {
        let source = "func f(a: [Int]) -> [Int] { a + [1, 2, 3] }"
        let mutation = try point(source, replacement: "-")
        #expect(!lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("A * inside a bare T: Numeric generic function is not eligible (Numeric has * but not /)")
    func timesInsideGenericNumericFunctionNotEligible() throws {
        let source = "func f<T: Numeric>(a: T, b: T) -> T { a * b }"
        let mutation = try point(source, replacement: "/")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("A * inside a generic type's own method is not eligible")
    func timesInsideGenericTypeMethodNotEligible() throws {
        let source = """
        struct Box<T: Numeric> {
            func scale(_ a: T, _ b: T) -> T { a * b }
        }
        """
        let mutation = try point(source, replacement: "/")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("A * inside an extension constrained by a generic where clause is not eligible")
    func timesInsideGenericWhereClauseExtensionNotEligible() throws {
        let source = """
        extension Array where Element: Numeric {
            func scaledSum(_ factor: Element) -> Element {
                reduce(Element.zero) { $0 + $1 * factor }
            }
        }
        """
        let mutation = try point(source, replacement: "/")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("A * inside a non-generic sibling function in the same file as a generic one is still eligible")
    func timesInsideUnrelatedNonGenericFunctionIsEligible() throws {
        let source = """
        func generic<T: Numeric>(a: T, b: T) -> T { a }
        func concrete(a: Int, b: Int) -> Int { a * b }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.originalText == "*" })
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    // MARK: - Variant table consistency

    @Test("Every replacement this lowerer embeds matches the real, unmodified isolated operator — never a separate table")
    func schemataNeverInventsItsOwnReplacementTable() throws {
        let source = "func f(a: Int, b: Int, c: Int, d: Int) -> Int { (a + b) - (c * d) / 2 }"
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        #expect(!points.isEmpty)
        let knownPairs: Set<[String]> = [["+", "-"], ["-", "+"], ["*", "/"], ["/", "*"]]
        for candidate in points {
            #expect(
                knownPairs.contains([candidate.originalText, candidate.replacementText]),
                "unexpected pair (\(candidate.originalText), \(candidate.replacementText)) not produced by the real isolated operator's own table"
            )
        }
    }
}

// MARK: - lower(_:sources:) and evaluation-count tests

//
// Split into its own extension purely to keep `type_body_length` reviewable
// per declaration — still the same single suite, no behavioral split.
extension ArithmeticOperatorReplacementSchemataLowererTests {
    @Test("Lowering one point embeds a closure that references the point's own real originalText/replacementText verbatim")
    func loweredCodeReferencesRealOperatorTextVerbatim() throws {
        let source = "func f(a: Int, b: Int) -> Int { a + b }"
        let mutation = try point(source, replacement: "-")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        let lowered = try #require(program.loweredSources.first)
        #expect(lowered.contents.contains("a - b"), "must reference the real, discovered replacementText")
        #expect(lowered.contents.contains("a + b"), "must reference the real, discovered originalText")
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
        let source = "func f(a: Int, b: Int) -> Int { a + b }"
        let mutation = try point(source, replacement: "-")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [mutation, mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        }
    }

    @Test("A point whose file is missing from sources makes lower(_:sources:) throw")
    func missingSourceThrows() throws {
        let source = "func f(a: Int, b: Int) -> Int { a + b }"
        let mutation = try point(source, replacement: "-")
        let chunk = SchemataChunk(chunkID: "chunk-1", points: [mutation], projectIdentity: "P", target: "T", module: "M", product: "Prod")
        #expect(throws: SchemataLoweringError.self) {
            _ = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Other.swift", contents: source)])
        }
    }

    @Test("Two arithmetic mutations in the same file are both spliced without corrupting each other's offsets")
    func twoPointsSameFileSpliceCorrectly() throws {
        // Two sibling (non-nested) infix expressions in different functions
        // — `(a + b) - (c * d)` would make `-`'s own infix envelope contain
        // `+`'s, a genuine structural overlap `firstOverlap` correctly
        // rejects, not a splice-offset bug to exercise here.
        let source = "func f(a: Int, b: Int) -> Int { a + b }\nfunc g(c: Int, d: Int) -> Int { c * d }"
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let first = try #require(points.first { $0.originalText == "+" && $0.replacementText == "-" })
        let second = try #require(points.first { $0.originalText == "*" && $0.replacementText == "/" })
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: [first, second], projectIdentity: "P", target: "T", module: "M", product: "Prod"
        )
        let program = try lowerer.lower(chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)])
        #expect(program.entries.count == 2)
        #expect(parsesWithoutError(program.loweredSources[0].contents), "lowered output must remain syntactically valid Swift")
    }

    // MARK: - Round-5 Codex review regressions

    @Test("Two distinct named safe types (Int paired with Double) are not eligible, even though each is individually safe")
    func distinctNamedSafeTypesNotEligible() throws {
        // Regression test for a High finding from an independent Codex
        // implementation review, round 5: an earlier version of
        // `typeVarianceRisk` required only that each operand *individually*
        // resolve to a type on `safeArithmeticTypeNames`, never that the two
        // resolved types actually match. `Int + Double` does not compile in
        // stock Swift for any of `+`/`-`/`*`/`/`, so an original expression
        // that *does* compile with two differently-named safe types must be
        // going through a project-defined custom overload — and nothing
        // proves that overload set is symmetric across all four operators.
        let source = "func f(a: Int, b: Double) -> Double { a + b }"
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("Two named operands of the identical safe type remain eligible (the same-type requirement does not over-reject)")
    func identicalNamedSafeTypesRemainEligible() throws {
        let source = "func f(a: Double, b: Double) -> Double { a + b }"
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("An if-let binding that shadows an enumerated for-loop's own index name is not resolved as that loop's Int index")
    func ifLetShadowingEnumeratedIndexIsNotResolvedAsLoopIndex() throws {
        // Regression test for a High finding from an independent Codex
        // implementation review, round 5:
        // `declaredTypeOfEnumeratedForLoopFirstElement` walked straight from
        // the reference up to the nearest enclosing `ForStmtSyntax`,
        // ignoring any intervening construct that itself rebinds the same
        // name. `for (index, _) in values.enumerated() { if let index =
        // maybeString { index + index } }` incorrectly resolved the inner,
        // `String`-typed `index` as the outer loop's `Int` index.
        let source = """
        func f(values: [Int], maybeString: String?) {
            for (index, _) in values.enumerated() {
                if let index = maybeString {
                    _ = index + index
                }
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
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("An enumerated for-loop's own index, referenced directly (no intervening shadow), still resolves to Int")
    func enumeratedIndexWithoutInterveningShadowStillResolvesToInt() throws {
        let source = """
        func f(values: [Int]) {
            for (index, _) in values.enumerated() {
                _ = index + index
            }
        }
        """
        let points = try discover(source, path: "Sample.swift", using: Operators.arithmetic)
        let mutation = try #require(points.first { $0.originalText == "+" })
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("""
    An in-scope typealias masking a safe type name is accepted \
    (documented, differential-tested residual risk — see typeVarianceRisk's doc comment)
    """)
    func typealiasMaskingSafeTypeNameIsAcceptedResidualRisk() throws {
        // Pins the one residual risk `declaredType(ofOperand:)`'s doc
        // comment already explicitly names and accepts (no symbol
        // resolution exists anywhere in this codebase to see through a
        // local `typealias`, so a name lookup trusts the spelling "Int" at
        // face value even when shadowed) — added because an independent
        // Codex implementation review, round 5, found this accepted risk had
        // no regression test pinning it, even though the doc comment already
        // described it. This test exists to make any future accidental
        // narrowing (or widening) of that acceptance visible as a diff here,
        // not to claim the risk is eliminated.
        let source = """
        typealias Int = String
        func f(a: Int, b: Int) -> Int { a + b }
        """
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("""
    A local nominal declaration masking a safe type name is accepted \
    (same underlying gap as the typealias case, see declaredSafeType's doc comment)
    """)
    func localNominalDeclarationMaskingSafeTypeNameIsAcceptedResidualRisk() throws {
        // Pins a Medium finding from an independent Codex implementation
        // review, round 8: a local `struct Int { ... }` (or a generic
        // parameter named `Int`) shadows `Swift.Int` exactly like a
        // `typealias` does, and this file's no-symbol-resolution design
        // cannot distinguish the two — same accepted disposition as
        // `typealiasMaskingSafeTypeNameIsAcceptedResidualRisk` above, not a
        // new gap. This test exists to make any future accidental
        // narrowing (or widening) of that acceptance visible as a diff.
        let source = """
        struct Int {
            static func + (lhs: Int, rhs: Int) -> Int { lhs }
        }
        func f(a: Int, b: Int) -> Int { a + b }
        """
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    @Test("""
    A generic parameter masking a safe type name is accepted \
    (same underlying gap as the typealias case, see declaredSafeType's doc comment)
    """)
    func genericParameterMaskingSafeTypeNameIsAcceptedResidualRisk() throws {
        // Round-9 Codex review Low: the round-8 doc comment and disposition
        // named both a local nominal declaration and a generic parameter as
        // the same accepted masking risk, but only the former had a pinning
        // test. This covers the latter.
        let source = "func f<Int: Numeric>(a: Int, b: Int) -> Int { a + b }"
        let mutation = try point(source, replacement: "-")
        #expect(lowerer.analyze(mutation, source: Data(source.utf8)).isEligible)
    }

    // MARK: - Round-6 Codex review regressions

    @Test("""
    An untyped, parenthesized closure parameter that shadows an outer, differently-typed parameter \
    of the same name is not resolved as that outer parameter
    """)
    func untypedParenthesizedClosureParameterShadowsOuterParameter() throws {
        // Regression test for a High finding from an independent Codex
        // implementation review, round 6: `declaredType(ofParameterNamed:
        // in:)` already resolved an *explicitly typed* closure parameter
        // correctly, but for an *untyped* one it returned `nil` ("not found
        // here"), which `nearestDeclaredType`'s ancestor walk read as
        // "keep walking outward" rather than "shadowed" — so `{ (a, b) in a
        // + b }` incorrectly resolved its own String-typed `a`/`b` to the
        // outer `a: Int, b: Int` parameters of the same name.
        let source = """
        func f(a: Int, b: Int) -> String {
            let g: (String, String) -> String = { (a, b) in a + b }
            return g("x", "y")
        }
        """
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("""
    A shorthand closure parameter (no parentheses) that shadows an outer, differently-typed parameter \
    of the same name is not resolved as that outer parameter
    """)
    func shorthandClosureParameterShadowsOuterParameter() throws {
        // Shorthand closure parameters (`{ a, b in ... }`) are a distinct
        // syntax node from the parenthesized form
        // (`ClosureShorthandParameterListSyntax`, not
        // `ClosureParameterClauseSyntax`) and are never typed by
        // construction — the grammar has no annotation slot for this form
        // — so this shape needed its own shadow check, separate from the
        // parenthesized-untyped fix above.
        let source = """
        func f(a: Int, b: Int) -> String {
            let g: (String, String) -> String = { a, b in a + b }
            return g("x", "y")
        }
        """
        let mutation = try point(source, replacement: "-")
        let eligibility = lowerer.analyze(mutation, source: Data(source.utf8))
        guard case let .isolatedOnly(reason) = eligibility else {
            Issue.record("expected .isolatedOnly, got \(eligibility)")
            return
        }
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("""
    A custom type's own enumerated() method, on a base that is not a recognized stdlib collection, \
    is not trusted as EnumeratedSequence
    """)
    func customEnumeratedOnNonCollectionBaseNotTrusted() throws {
        // Regression test for a High finding from an independent Codex
        // implementation review, round 6: `declaredTypeOfEnumeratedForLoop
        // FirstElement` trusted *any* zero-argument member named
        // `enumerated()` as the stdlib `Sequence.enumerated()`, regardless
        // of the receiver's own type — a project-defined type with its own
        // differently-typed `enumerated()` method (returning
        // `[(String, String)]` here) could qualify its first tuple element
        // as `Int` and lower to an invalid `String - String` branch. Fixed
        // by requiring the receiver to itself be a recognized stdlib-
        // collection shape (mirrors `isProvablyInt`'s own `.count` case).
        let source = """
        struct CustomSequence {
            func enumerated() -> [(String, String)] { [] }
        }
        func f(seq: CustomSequence) {
            for (index, _) in seq.enumerated() {
                _ = index + index
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
        #expect(reason == .typeVarianceUnproven)
    }

    // MARK: - Round-7 Codex review regressions

    @Test("didSet's implicit oldValue shadows a differently-typed stored property of the same name elsewhere on the type")
    func didSetImplicitOldValueShadowsSiblingStoredProperty() throws {
        // Regression test for a High finding from an independent Codex
        // implementation review, round 7: `introducesUnresolvedShadow` had
        // no case for accessor blocks at all, so `didSet { oldValue +
        // oldValue }`'s own implicit, un-typeable `oldValue` binding fell
        // through to `declaredType(ofStoredPropertyNamed:)`, which found an
        // unrelated, differently-typed stored property also named
        // `oldValue` elsewhere on the same type and incorrectly qualified
        // the accessor's own binding as that property's type.
        let source = """
        struct S {
            var oldValue: Int = 0
            var name: String = "" {
                didSet {
                    _ = oldValue + oldValue
                }
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
        #expect(reason == .typeVarianceUnproven)
    }

    @Test("A custom setter's explicitly named parameter shadows a differently-typed stored property of the same name")
    func customSetterExplicitParameterShadowsSiblingStoredProperty() throws {
        let source = """
        struct S {
            var newValue: Int = 0
            var name: String {
                get { "" }
                set(newValue) {
                    _ = newValue + newValue
                }
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
        #expect(reason == .typeVarianceUnproven)
    }

    // MARK: - Evaluation count

    /// Proves the specific runtime property the lowering shape depends on for
    /// correctness: `lhs`/`rhs` appear twice in the lowered source text (once
    /// per ternary branch), but Swift's `?:` only evaluates its *selected*
    /// branch — so at runtime each operand is still evaluated exactly once.
    /// Exercises the real language construct directly (not through
    /// `analyze`'s eligibility restriction, which never permits a
    /// side-effecting operand into production) to pin the underlying
    /// guarantee this lowerer's design relies on — same proof
    /// `RelationalOperatorReplacementSchemataLowererTests
    /// .ternarySelectsOnlyOneBranchAtRuntime` establishes for that lowerer's
    /// identical shape.
    @Test("A ternary conditional evaluates only its selected branch, never both")
    func ternarySelectsOnlyOneBranchAtRuntime() {
        var lhsEvaluations = 0
        var rhsEvaluations = 0
        func lhs() -> Int { lhsEvaluations += 1; return 6 }
        func rhs() -> Int { rhsEvaluations += 1; return 2 }

        func isActive() -> Bool { true }
        _ = isActive() ? (lhs() / rhs()) : (lhs() * rhs())

        #expect(lhsEvaluations == 1, "lhs must be evaluated exactly once regardless of which branch's operator text is selected")
        #expect(rhsEvaluations == 1, "rhs must be evaluated exactly once regardless of which branch's operator text is selected")
    }
}
