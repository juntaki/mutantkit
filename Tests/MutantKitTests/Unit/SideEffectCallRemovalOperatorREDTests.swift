import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Scenario numbers in test names/comments match
/// `Research/operator-catalog/side-effect-call-removal-design.md`'s own
/// "RED test scenarios" section exactly, so a failure here can be traced
/// back to the exact design paragraph it tests.
@Suite("RED: side-effect call removal operator")
struct SideEffectCallRemovalOperatorREDTests {
    private let operatorID = "swift.core.side-effect-call-removal"

    // MARK: - Positive scenarios (candidate found, removal compiles)

    @Test("Scenario 1: a plain Void-returning call as the only statement of an otherwise multi-statement function body")
    func scenario1PlainCallAloneInMultiStatementFunction() throws {
        let source = """
        func run() {
            prepare()
            sideEffect()
            finish()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "sideEffect()" && $0.replacementText.isEmpty })
    }

    @Test("Scenario 2: a Void-returning call as one of several statements, not last, not first")
    func scenario2CallInMiddleOfMultiStatementBody() throws {
        let source = """
        func run() {
            first()
            middle()
            last()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "middle()" })
        #expect(points.contains { $0.originalText == "first()" })
        #expect(points.contains { $0.originalText == "last()" })
    }

    @Test("Scenario 3: a @discardableResult-marked non-Void call used as a bare statement")
    func scenario3DiscardableResultBareStatement() throws {
        let source = """
        @discardableResult
        func compute() -> Int { 1 }

        func run() {
            compute()
            after()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "compute()" })
    }

    @Test("Scenario 4: a call inside a defer block is included, not excluded")
    func scenario4DeferBodyIncluded() throws {
        let source = """
        func run() {
            defer {
                cleanup()
            }
            work()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "cleanup()" })
    }

    @Test("Scenario 5: a try call as a bare statement removes the whole try expression")
    func scenario5TryCallRemovesWholeTryExpression() throws {
        let source = """
        func run() throws {
            try sideEffect()
            after()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(points.first { $0.originalText.contains("sideEffect") })
        #expect(point.originalText == "try sideEffect()")
        #expect(point.replacementText.isEmpty)
    }

    @Test("Scenario 6: an await call as a bare statement removes the whole await expression")
    func scenario6AwaitCallRemovesWholeAwaitExpression() throws {
        let source = """
        func run() async {
            await sideEffect()
            after()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(points.first { $0.originalText.contains("sideEffect") })
        #expect(point.originalText == "await sideEffect()")
    }

    @Test("Scenario 7: a try await call as a bare statement removes both wrappers together")
    func scenario7TryAwaitCallRemovesBothWrappers() throws {
        let source = """
        func run() async throws {
            try await sideEffect()
            after()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(points.first { $0.originalText.contains("sideEffect") })
        #expect(point.originalText == "try await sideEffect()")
    }

    /// The design's own point 2 is explicit that a single-statement closure
    /// with *no* annotation cannot be proven `Void` from syntax alone
    /// (that needs the enclosing call's own parameter type, i.e. symbol
    /// resolution) and is conservatively excluded — see scenario 17 below
    /// for that excluded shape. Scenario 8 is the sub-case point 2 calls
    /// out as safe regardless: an *explicit* `-> Void` on the closure
    /// itself, provable from syntax alone with no resolution needed.
    @Test("Scenario 8: a call as the only statement of an explicitly Void-annotated closure passed as a completion handler")
    func scenario8SoleStatementOfExplicitlyVoidClosureArgument() throws {
        let source = """
        func run() {
            perform(completion: { () -> Void in
                notify()
            })
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "notify()" })
    }

    @Test("Scenario 9: a call inside an if block body confirms CodeBlockSyntax count is per-block")
    func scenario9CallInsideIfBlockBody() throws {
        let source = """
        func run(condition: Bool) {
            if condition {
                sideEffect()
            }
            after()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "sideEffect()" })
    }

    @Test("Scenario 10: a bare call as the last of several statements in an unannotated closure is a candidate")
    func scenario10LastOfSeveralStatementsInUnannotatedClosureIsCandidate() throws {
        let source = """
        func run() {
            let g: () -> Void = {
                logCall()
                notify()
            }
            g()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "logCall()" })
        #expect(points.contains { $0.originalText == "notify()" })
    }

    // MARK: - Negative scenarios (must not be a candidate)

    @Test("Scenario 11a: the sole statement of a single-expression function with an explicit non-Void return type")
    func scenario11aSoleStatementOfNonVoidFunction() throws {
        let source = """
        func makeInt() -> Int {
            compute()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("Scenario 11b: the sole statement of a computed property whose typeAnnotation is non-Void (implicit getter)")
    func scenario11bSoleStatementOfNonVoidComputedProperty() throws {
        let source = """
        struct S {
            var value: Int {
                compute()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("Scenario 11c: the sole statement of an explicit get accessor whose property type is non-Void")
    func scenario11cSoleStatementOfExplicitGetAccessorNonVoid() throws {
        let source = """
        struct S {
            var value: Int {
                get {
                    compute()
                }
                set {
                    store(newValue)
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "compute()" })
        // The setter's own body is always Void-returning -- its sole
        // statement is an ordinary candidate, unaffected by rule 11c.
        #expect(points.contains { $0.originalText == "store(newValue)" })
    }

    @Test("Scenario 12a: a call used as the right-hand side of an assignment is not a candidate")
    func scenario12aAssignmentRHSExcluded() throws {
        let source = """
        func run() {
            let x = compute()
            use(x)
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "compute()" })
    }

    @Test("Scenario 12b: a call used as an argument to another call is not a candidate")
    func scenario12bArgumentToAnotherCallExcluded() throws {
        let source = """
        func run() {
            use(compute())
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "compute()" })
    }

    @Test("A returned call is not a candidate")
    func returnedCallExcluded() throws {
        let source = """
        func run() -> Int {
            if true {
                return compute()
            }
            return 0
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "compute()" })
    }

    @Test("Scenario 13: the sole statement of a guard's else block, regardless of name, is not a candidate")
    func scenario13SoleStatementOfGuardElseExcludedRegardlessOfName() throws {
        let source = """
        func run(condition: Bool) {
            guard condition else {
                customNonReturningExit()
            }
            after()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "customNonReturningExit()" })
    }

    @Test("The last (not sole) statement of a guard's else block is excluded; an earlier statement in the same block is not")
    func lastStatementOfMultiStatementGuardElseExcludedEarlierIsNot() throws {
        let source = """
        func run(condition: Bool) {
            guard condition else {
                logFailure()
                fatalError()
            }
            after()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "logFailure()" })
        // fatalError is excluded here for two independent reasons: it is
        // the guard-else's last statement AND it is denylisted by name
        // (see scenario 14) -- either alone would already exclude it.
        #expect(!points.contains { $0.originalText == "fatalError()" })
    }
}

// MARK: - Rule 2/8/9 extensions, the never-returning denylist, result builders, switch cases, config exclusion, comments/trivia, metadata

/// Split from the main suite above purely to keep that struct's body under
/// SwiftLint's `type_body_length`; same suite in spirit.
extension SideEffectCallRemovalOperatorREDTests {
    @Test("Rule 2 extension (codex finding): a trailing call to a custom, non-stdlib Never-returning function in a multi-statement non-Void body is not a candidate")
    func trailingCustomNeverReturningCallInMultiStatementBodyExcluded() throws {
        let source = """
        func customNeverHelper() -> Never {
            fatalError()
        }

        func value() -> Int {
            audit()
            customNeverHelper()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "audit()" })
        #expect(!points.contains { $0.originalText == "customNeverHelper()" })
    }

    @Test("Rule 2 extension does not affect a non-last statement of a multi-statement non-Void body")
    func nonLastStatementOfMultiStatementNonVoidBodyUnaffected() throws {
        let source = """
        func value() -> Int {
            sideEffect()
            return 1
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "sideEffect()" })
    }

    @Test("Rule 2 extension does not affect a Void-returning function's trailing statement")
    func trailingStatementOfVoidFunctionUnaffected() throws {
        let source = """
        func run() {
            prepare()
            finish()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "finish()" })
    }

    @Test("Rule 2 extension covers a subscript's implicit-getter shorthand")
    func subscriptImplicitGetterShorthandExcluded() throws {
        let source = """
        struct Table {
            subscript(index: Int) -> Int {
                load(index)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "load(index)" })
    }

    @Test("Rule 2 extension covers a subscript's explicit get accessor, but not its set accessor")
    func subscriptExplicitGetSetAccessorsHandledCorrectly() throws {
        let source = """
        struct Table {
            subscript(index: Int) -> Int {
                get {
                    load(index)
                }
                set {
                    store(index, newValue)
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "load(index)" })
        #expect(points.contains { $0.originalText == "store(index, newValue)" })
    }

    @Test("Rule 9 (codex finding): self.init(...) delegation is never a candidate")
    func selfInitDelegationExcluded() throws {
        let source = """
        struct S {
            init(value: Int) {}

            init() {
                self.init(value: 0)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("self.init") })
    }

    @Test("An ordinary self.foo() call remains a normal candidate, unlike self.init")
    func ordinarySelfMethodCallRemainsCandidate() throws {
        let source = """
        struct S {
            func run() {
                self.sideEffect()
                after()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "self.sideEffect()" })
    }

    @Test("Rule 8 (real-corpus finding): super.init(...) is never a candidate -- a near-certain unviable mutant")
    func superInitCallExcluded() throws {
        let source = """
        class Base {
            init(value: Int) {}
        }

        class Sub: Base {
            override init(value: Int) {
                super.init(value: value)
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("super.init") })
    }

    @Test("Rule 8: every super.*() call is excluded, not only super.init -- LifecycleSuperCallRemovalOperator's own domain")
    func everySuperCallExcludedRegardlessOfName() throws {
        let source = """
        class Base {
            func viewDidLoad() {}
        }

        class Sub: Base {
            override func viewDidLoad() {
                super.viewDidLoad()
                after()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.contains("super.viewDidLoad") })
        #expect(points.contains { $0.originalText == "after()" })
    }

    @Test("Scenario 14: fatalError/preconditionFailure/exit/abort are never candidates, anywhere, regardless of position")
    func scenario14NeverReturningDenylistExcludedUnconditionally() throws {
        let source = """
        func run() {
            fatalError("boom")
            preconditionFailure("boom")
            exit(1)
            abort()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("assertionFailure is NOT denylisted: an ordinary mid-function call to it is a normal candidate")
    func assertionFailureIsOrdinaryCandidateOutsideExitPosition() throws {
        let source = """
        func run(condition: Bool) {
            if !condition {
                assertionFailure("should not happen")
            }
            after()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "assertionFailure(\"should not happen\")" })
    }

    @Test("Scenario 15a: a bare call inside a var body: some View under a View conformance (implicit @ViewBuilder) is excluded")
    func scenario15aImplicitViewBuilderBodyExcluded() throws {
        let source = """
        struct MyView: View {
            var body: some View {
                sideEffect()
                Text("hi")
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "sideEffect()" })
    }

    @Test("Scenario 15b: a bare call nested inside a ForEach trailing closure inside var body: some View is excluded")
    func scenario15bNestedForEachInsideViewBodyExcluded() throws {
        let source = """
        struct MyView: View {
            var body: some View {
                ForEach(items) { item in
                    sideEffect(item)
                }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText.hasPrefix("sideEffect") })
    }

    @Test("Scenario 15c: an explicit @ViewBuilder-attributed function body excludes a nested bare call")
    func scenario15cExplicitViewBuilderAttributeExcluded() throws {
        let source = """
        @ViewBuilder
        func rows() -> some View {
            sideEffect()
            Text("hi")
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "sideEffect()" })
    }

    @Test("Scenario 16: a Void print-style call inside a result-builder body is excluded even though it is unrelated to view construction")
    func scenario16UnrelatedPrintInsideBuilderBodyExcluded() throws {
        let source = """
        struct MyView: View {
            var body: some View {
                print("debug")
                Text("hi")
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "print(\"debug\")" })
    }

    @Test("Scenario 17: the sole statement of a closure literal with no explicit return type, in a non-Void-inferred context, is not a candidate")
    func scenario17SoleStatementOfUnannotatedClosureInNonVoidContextExcluded() throws {
        let source = """
        func run() {
            let f: () -> Int = {
                makeInt()
            }
            use(f)
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "makeInt()" })
    }

    @Test("Scenario 18: the sole statement of a switch case is not a candidate, regardless of what the call is named")
    func scenario18SoleStatementOfSwitchCaseExcludedRegardlessOfName() throws {
        let source = """
        func run(state: State) {
            switch state {
            case .ready:
                notify()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(!points.contains { $0.originalText == "notify()" })
    }

    @Test("A switch case with two statements is unaffected: only the sole-statement case is excluded")
    func switchCaseWithTwoStatementsUnaffected() throws {
        let source = """
        func run(state: State) {
            switch state {
            case .ready:
                logReady()
                notify()
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.contains { $0.originalText == "logReady()" })
        #expect(points.contains { $0.originalText == "notify()" })
    }

    @Test("A call named in excludedCallNames is not a candidate, matched by base name")
    func configExcludedCallNameIsNotACandidate() throws {
        let source = """
        func run() {
            myLogger.record()
            sideEffect()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: operatorID, excludedCallNames: ["record"]
        )
        #expect(!points.contains { $0.originalText.contains("record") })
        #expect(points.contains { $0.originalText == "sideEffect()" })
    }

    /// Operator-exclusion-soundness audit
    /// (`Research/operator-catalog/operator-exclusion-policy.md`): the
    /// coarseness `Sources/MutationModel/Configuration.swift`'s own doc
    /// comment already admits for `excludeCalls` ("Doesn't support
    /// overloading currently — all function calls with a matching name will
    /// be skipped") had no test proving it was real, only prose claiming it.
    /// Pinned directly here: excluding `"record"` excludes *every* receiver's
    /// `record()`, not just the one the user had in mind — a real risk a user
    /// configuring `excludeCalls` should be able to see demonstrated, not
    /// only read about.
    @Test("excludeCalls matches by base name alone: excluding one name also excludes an unrelated receiver's same-named method")
    func configExcludedCallNameAlsoExcludesAnUnrelatedReceiversSameNamedMethod() throws {
        let source = """
        func run() {
            myLogger.record()
            unrelatedAnalytics.record()
            myLogger.flush()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: operatorID, excludedCallNames: ["record"]
        )
        #expect(!points.contains { $0.originalText == "myLogger.record()" })
        #expect(!points.contains { $0.originalText == "unrelatedAnalytics.record()" }, """
        this is the documented limitation itself: excludeCalls has no receiver/overload resolution, so a name \
        collision with a completely unrelated type is excluded too
        """)
        #expect(points.contains { $0.originalText == "myLogger.flush()" }, "a different name on the same receiver is unaffected")
    }

    @Test("Leading and trailing trivia (comments, blank lines) around the candidate are preserved, not part of the mutation")
    func commentsAndTriviaAreNotPartOfTheCandidate() throws {
        let source = """
        func run() {
            // a leading comment
            sideEffect() // a trailing comment
            after()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(points.first { $0.originalText == "sideEffect()" })
        #expect(point.replacementText.isEmpty)

        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        #expect(applied.evidence.provesSourceApplication)
        let mutatedSource = String(decoding: applied.mutatedSource, as: UTF8.self)
        #expect(mutatedSource.contains("// a leading comment"))
        #expect(mutatedSource.contains("// a trailing comment"))

        let verification = SourceAnchorVerifier.verify(point, against: Data(source.utf8), depth: .full)
        #expect(verification.isValid, "anchor rejected: \(verification.failures)")
    }

    @Test("Every candidate carries the operator's own ID, version and experimental confidence")
    func candidateMetadataIsCorrect() throws {
        let source = """
        func run() {
            sideEffect()
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(points.first)
        #expect(point.operatorID == operatorID)
        #expect(point.confidence == .experimental)
    }
}
