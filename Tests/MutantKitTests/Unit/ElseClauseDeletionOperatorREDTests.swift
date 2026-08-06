import Foundation
import MutationModel
import SwiftFrontend
import Testing

@Suite("RED: else clause deletion operator")
struct ElseClauseDeletionOperatorREDTests {
    private let operatorID = "swift.core.else-clause-deletion"

    @Test("Deletes a plain else clause, leaving the if branch as the whole statement")
    func deletesPlainElse() throws {
        let source = """
        func label(ready: Bool) -> String {
            var result = ""
            if ready {
                result = "ready"
            } else {
                result = "waiting"
            }
            return result
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        #expect(points.count == 1)
        #expect(points[0].operatorID == operatorID)
        #expect(points[0].confidence == .experimental)
        #expect(points[0].originalText == "if ready {\n        result = \"ready\"\n    } else {\n        result = \"waiting\"\n    }")
        #expect(points[0].replacementText == "if ready {\n        result = \"ready\"\n    }")

        let applied = try MutationApplication.apply(points[0], to: Data(source.utf8))
        #expect(applied.evidence.provesSourceApplication)

        let verification = SourceAnchorVerifier.verify(points[0], against: Data(source.utf8), depth: .full)
        #expect(verification.isValid, "anchor rejected: \(verification.failures)")
    }

    @Test("An else-if chain yields two independent candidates: the outer else-if-else and the inner else")
    func elseIfChainYieldsTwoIndependentCandidates() throws {
        // The chain is deliberately not the last statement of the function:
        // it is the sole statement of a non-`Void` function, deleting its
        // else clauses would leave a path that falls off the end without
        // returning ("missing return in function expected to return
        // 'String'", confirmed with a full `swiftc` compile, not just
        // `-typecheck`) — a real hazard a second codex review of this
        // operator's first version found. The `return result` after the
        // chain makes it a genuinely safe, ordinary mid-body statement.
        let source = """
        func classify(_ a: Bool, _ b: Bool) -> String {
            var result = ""
            if a {
                result = "a"
            } else if b {
                result = "b"
            } else {
                result = "neither"
            }
            return result
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        #expect(points.count == 2)
        #expect(Set(points.map(\.id)).count == 2, "outer and inner candidates must not share a MutationID")

        let outer = try #require(points.first { $0.originalText.hasPrefix("if a") })
        let inner = try #require(points.first { $0.originalText.hasPrefix("if b") })

        #expect(outer.replacementText == "if a {\n        result = \"a\"\n    }")
        #expect(inner.replacementText == "if b {\n        result = \"b\"\n    }")

        for point in [outer, inner] {
            let applied = try MutationApplication.apply(point, to: Data(source.utf8))
            #expect(applied.evidence.provesSourceApplication)
            let verification = SourceAnchorVerifier.verify(point, against: Data(source.utf8), depth: .full)
            #expect(verification.isValid, "anchor rejected for \(point.originalText): \(verification.failures)")
        }
    }

    @Test("An if with no else clause is not a candidate")
    func plainIfWithoutElseIsNotACandidate() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func label(ready: Bool) -> String {
                var result = "default"
                if ready {
                    result = "ready"
                }
                return result
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("An if/else used as a value-producing expression is not a candidate")
    func ifExpressionUsedAsValueIsNotACandidate() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func label(ready: Bool) -> String {
                let result = if ready { "ready" } else { "waiting" }
                return result
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("An if/else that is the sole statement of an implicit-return computed property is not a candidate")
    func implicitReturnComputedPropertyIsNotACandidate() throws {
        // The exact shape a codex review of this operator's first version
        // found: `var value: Int { if flag { 1 } else { 2 } }` compiles
        // (confirmed with `swiftc -typecheck`) because the if-expression IS
        // the property's implicit return value — deleting `else` would
        // leave a non-Void getter whose false path returns nothing.
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            struct S {
                var flag: Bool
                var value: Int {
                    if flag { 1 } else { 2 }
                }
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("An if/else as the last statement of a non-Void function is not a candidate, even with explicit returns")
    func lastStatementOfNonVoidFunctionIsNotACandidateEvenWithExplicitReturns() throws {
        // A second, independent hazard from the implicit-return case above:
        // each branch already has its own explicit `return`, but the
        // function still requires every path to return — deleting `else`
        // leaves the `false` path falling off the end with nothing.
        // Confirmed uncompilable with a full `swiftc` compile (not just
        // `-typecheck`, which does not catch "missing return" at all).
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func classify(_ a: Bool) -> String {
                if a {
                    return "a"
                } else {
                    return "notA"
                }
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("An if/else as the last statement of a Void function is still a candidate")
    func lastStatementOfVoidFunctionIsStillACandidate() throws {
        // The one enclosing shape where being last is provably safe: a
        // function with no `-> T` at all needs no return on any path, and
        // cannot be an implicit-return value position either.
        let source = """
        func announce(_ ready: Bool) {
            if ready {
                print("go")
            } else {
                print("wait")
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        #expect(points.count == 1)
        let point = try #require(points.first)
        #expect(point.replacementText == "if ready {\n        print(\"go\")\n    }")

        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        #expect(applied.evidence.provesSourceApplication)
        let verification = SourceAnchorVerifier.verify(point, against: Data(source.utf8), depth: .full)
        #expect(verification.isValid, "anchor rejected: \(verification.failures)")
    }

    @Test("An if/else inside a function explicitly attributed with a known result builder is not a candidate")
    func explicitlyAttributedResultBuilderBodyIsNotACandidate() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            @ViewBuilder
            func rows(_ ready: Bool) -> SomeView {
                if ready {
                    ReadyRow()
                } else {
                    WaitingRow()
                }
                Footer()
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("An if/else inside a var body: SomeView { ... } getter is not a candidate, even when not the last statement")
    func structurallyDetectedBodyPropertyIsNotACandidateEvenWhenNotLast() throws {
        // Non-last position alone would normally make this safe (see
        // `lastStatementOfVoidFunctionIsStillACandidate`'s positive
        // control) — the result-builder exclusion has to apply regardless
        // of position, since every statement in a builder body goes
        // through buildBlock/buildEither/buildOptional, not just the last.
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            struct RowList {
                var ready: Bool
                var body: SomeView {
                    if ready {
                        ReadyRow()
                    } else {
                        WaitingRow()
                    }
                    Footer()
                }
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("A labeled if statement (retry: if ... else ...) is still recognized as statement-position")
    func labeledIfStatementIsStillStatementPosition() throws {
        let source = """
        func attempt(_ ready: Bool) {
            retry: if ready {
                print("go")
            } else {
                print("wait")
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        #expect(points.count == 1)
        let point = try #require(points.first)
        #expect(point.replacementText == "if ready {\n        print(\"go\")\n    }")

        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        #expect(applied.evidence.provesSourceApplication)

        let verification = SourceAnchorVerifier.verify(point, against: Data(source.utf8), depth: .full)
        #expect(verification.isValid, "anchor rejected: \(verification.failures)")
    }

    @Test("Every level of an else-if chain used as a value expression is excluded, not just the outermost")
    func everyLevelOfValueChainIsExcluded() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func classify(_ a: Bool, _ b: Bool) -> String {
                let result = if a {
                    "a"
                } else if b {
                    "b"
                } else {
                    "neither"
                }
                return result
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("A nested if used as a statement inside an outer if's body is still a candidate")
    func nestedStatementIfInsideOuterBodyIsStillACandidate() throws {
        // Neither if/else is the last statement of its own enclosing block
        // (each is followed by an assignment) — both the outer chain's
        // non-Void-function hazard and the inner chain's "last statement of
        // the outer if's body" hazard are avoided the same way, by not
        // being last.
        let source = """
        func describe(_ a: Bool, _ b: Bool) -> String {
            var result = "neitherOuter"
            if a {
                if b {
                    result = "both"
                } else {
                    result = "onlyA"
                }
                result += "!"
            } else {
                result = "neitherOuter"
            }
            return result
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        #expect(points.count == 2, "the outer if/else and the nested if/else are independent sites")
        #expect(Set(points.map(\.id)).count == 2)
    }

    @Test("Comments inside the if branch and around the else clause are handled correctly")
    func preservesIfBranchCommentsAndDropsElseCleanly() throws {
        let source = """
        func label(ready: Bool) -> String {
            var result = ""
            if ready {
                // ready path
                result = "ready" /* trailing */
            } else {
                result = "waiting"
            }
            return result
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        #expect(points.count == 1)
        let point = try #require(points.first)

        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        let mutated = String(decoding: applied.mutatedSource, as: UTF8.self)

        #expect(mutated.contains("// ready path"), "the comment inside the surviving if branch must not be dropped")
        #expect(mutated.contains("/* trailing */"), "the trailing comment inside the surviving if branch must not be dropped")
        #expect(!mutated.contains("waiting"), "the else branch's contents must be gone")

        let verification = SourceAnchorVerifier.verify(point, against: Data(source.utf8), depth: .full)
        #expect(verification.isValid, "anchor rejected: \(verification.failures)")
    }

    @Test("Mutation ID is stable when an unrelated declaration is inserted")
    func IDIsStableAcrossUnrelatedDeclarations() throws {
        let original = try CoreOperatorExpansionTestSupport.discover(
            """
            func label(ready: Bool) -> String {
                var result = ""
                if ready { result = "ready" } else { result = "waiting" }
                return result
            }
            """,
            operatorID: operatorID
        )
        let shifted = try CoreOperatorExpansionTestSupport.discover(
            """
            func unrelated() -> Int { 42 }

            func label(ready: Bool) -> String {
                var result = ""
                if ready { result = "ready" } else { result = "waiting" }
                return result
            }
            """,
            operatorID: operatorID
        )

        #expect(original.count == 1)
        #expect(shifted.count == 1)
        #expect(original[0].id == shifted[0].id)
    }
}

/// A second suite for the compile-safety exclusion checks added to close
/// two gaps (an attributed-but-non-structurally-named result-builder
/// property, and an empty/no-op `else` clause) — split from the primary
/// suite above purely to stay under this project's `type_body_length`
/// SwiftLint limit, not because the tests belong to a different feature.
@Suite("RED: else clause deletion operator — compile-safety exclusions")
struct ElseClauseDeletionOperatorCompileSafetyExclusionREDTests {
    private let operatorID = "swift.core.else-clause-deletion"

    @Test("An if/else inside an explicitly @ViewBuilder-attributed computed property with a non-standard name is not a candidate")
    func explicitlyAttributedNonStandardNamedPropertyIsNotACandidate() throws {
        // `rows` is not in the structural name list (`body`, `commands`,
        // `previews`, `content`), so `isBuilderReturningPropertyDeclaration`
        // alone would miss it — this only works because `hasBuilderAttribute`
        // also inspects the enclosing `VariableDeclSyntax`'s own attributes,
        // not just `FunctionDeclSyntax`/`AccessorDeclSyntax`.
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            struct RowList {
                var ready: Bool
                @ViewBuilder
                var rows: some View {
                    if ready {
                        ReadyRow()
                    } else {
                        WaitingRow()
                    }
                    Footer()
                }
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("A module-qualified builder attribute spelling (@SwiftUI.ViewBuilder) is an accepted, known gap")
    func moduleQualifiedBuilderAttributeIsAcceptedGap() throws {
        // `attribute.attributeName` for `@SwiftUI.ViewBuilder` is a
        // `MemberTypeSyntax`, not an `IdentifierTypeSyntax` — the same
        // name-only, not-symbol-resolved matching this operator already
        // documents elsewhere means this spelling is invisible to
        // `hasBuilderAttribute`. This is a known, accepted gap (a missed,
        // safe candidate rather than a broken mutant is still the worse
        // outcome, not a compile failure), not a bug to fix here: this test
        // documents and pins the gap rather than asserting it is closed.
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            struct RowList {
                var ready: Bool
                @SwiftUI.ViewBuilder
                var rows: some View {
                    if ready {
                        ReadyRow()
                    } else {
                        WaitingRow()
                    }
                    Footer()
                }
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1, "documents the accepted gap: module-qualified attribute spellings are not recognized")
    }

    @Test("An if with a fully empty else clause is not a candidate")
    func fullyEmptyElseClauseIsNotACandidate() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func label(ready: Bool) {
                if ready {
                    work()
                } else {
                }
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("An if with a comment-only else clause is not a candidate")
    func commentOnlyElseClauseIsNotACandidate() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func label(ready: Bool) {
                if ready {
                    work()
                } else {
                    // nothing to do here
                }
            }
            """,
            operatorID: operatorID
        )

        #expect(points.isEmpty)
    }

    @Test("An if with real code in the else clause is still a candidate, confirming no over-exclusion")
    func realCodeElseClauseIsStillACandidate() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            """
            func label(ready: Bool) {
                if ready {
                    work()
                } else {
                    other()
                }
            }
            """,
            operatorID: operatorID
        )

        #expect(points.count == 1)
    }

    @Test("In an else-if chain, only the genuinely-empty innermost else is excluded, not the shallower levels")
    func onlyInnermostEmptyElseInChainIsExcluded() throws {
        let source = """
        func classify(_ a: Bool, _ b: Bool) {
            if a {
                work()
            } else if b {
                other()
            } else {
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)

        // The outer candidate (deleting `else if b { other() } else { }`
        // entirely) is not vacuous: it still changes behavior when `a` is
        // false and `b` is true. Only the inner candidate — whose own
        // `elseBody` is the empty `else { }` — is excluded.
        #expect(points.count == 1)
        let point = try #require(points.first)
        #expect(point.originalText.hasPrefix("if a"))
    }
}
