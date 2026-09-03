import SwiftFrontend
import SwiftSyntax

/// Sites every operator must leave alone.
///
/// These are not stylistic preferences — each one produces mutants that are
/// guaranteed to be worthless or broken, and a report full of those is a report
/// developers stop reading.
enum OperatorExclusions {
    /// Compiler-recognized attributes actually proven to take compile-time-
    /// only arguments — the language itself never generates a code path
    /// that reads them at runtime, unlike a custom attribute.
    ///
    /// This is a closed allowlist, not "every attribute," because a custom
    /// attribute is very often a `@propertyWrapper` (or an attached macro),
    /// and those take *ordinary* initializer arguments, evaluated and
    /// stored at runtime exactly like any other call. Proven wrong with a
    /// real, compiled, run fixture: a `@propertyWrapper`
    /// whose `init` reads an `enabled: Bool` argument and branches on it —
    /// flipping `enabled: true` to `enabled: false` in the attribute
    /// changed the compiled program's own printed output. That is the same
    /// class of silently-erased mutant `irradiate`'s `len(x) > 0` ->
    /// `len(x) >= 0` equivalence bug already showed once for a different
    /// operator, just for a blanket exclusion instead of a heuristic one.
    ///
    /// No symbol resolution is available during discovery to tell "this
    /// custom attribute is a property wrapper" from "this custom attribute
    /// is a compiler plugin that only reads its arguments at compile time"
    /// in general, so this only special-cases the closed, known set of
    /// *compiler builtins* actually documented to have no runtime reader.
    /// Every other attribute name — every property wrapper, every attached
    /// macro, every result builder used as an attribute — is left to
    /// mutate as ordinary code, the same knowingly-conservative-toward-
    /// generating-candidates footing `isControlFlowConstantCondition`'s own
    /// doc comment already takes for a different exclusion.
    private static let compileTimeOnlyAttributeNames: Set<String> = [
        // Platform/version/message tokens; no runtime reader anywhere in
        // the language.
        "available", "backDeployed",
        // Objective-C runtime *name* metadata (a selector/class name
        // string) — affects symbol lookup, not program logic a test
        // observes.
        "objc", "objcMembers", "nonobjc",
        // Generic-specialization hints consumed entirely by the compiler.
        "_specialize"
    ]

    /// True when the node sits somewhere no mutation can produce a meaningful
    /// runtime difference.
    static func isExcluded(_ node: some SyntaxProtocol) -> Bool {
        let start = node.positionAfterSkippingLeadingTrivia
        let end = node.endPositionBeforeTrailingTrivia
        var cursor: Syntax? = Syntax(node).parent

        while let current = cursor {
            if let attribute = current.as(AttributeSyntax.self),
               let name = attribute.attributeName.as(IdentifierTypeSyntax.self),
               compileTimeOnlyAttributeNames.contains(name.name.text) {
                return true
            }

            // Only the `#if` *condition* is off limits: mutating it does not test
            // the suite, it compiles a different program. The body is ordinary
            // code and must still be mutated — `#if DEBUG`, `#if os(iOS)` and
            // `#if canImport(UIKit)` guard real logic throughout Apple codebases,
            // and excluding the whole clause would silently drop all of it while
            // still reporting a confident score over what remained.
            if let clause = current.as(IfConfigClauseSyntax.self) {
                if let condition = clause.condition,
                   condition.position <= start, end <= condition.endPosition {
                    return true
                }
            }

            // Macro expansion output is not the developer's source. A mutation
            // there would show a diff against code nobody wrote, and Phase 4's
            // schemata rules exclude it too.
            if current.is(MacroExpansionExprSyntax.self) || current.is(MacroExpansionDeclSyntax.self) {
                return true
            }

            cursor = current.parent
        }

        return false
    }

    /// True inside a `@ViewBuilder`-style result-builder body: every
    /// statement there is rewritten through the builder's
    /// `buildBlock`/`buildEither`/`buildOptional` methods, a transform
    /// invisible to the parser (a result-builder body parses as an
    /// unremarkable `CodeBlockSyntax`/`CodeBlockItemListSyntax`). Shared
    /// between `ElseClauseDeletionOperator` (an `if`/`else` there compiles
    /// via `buildEither`, a different method than the `buildOptional` a
    /// resulting else-less `if` would need) and schemata lowering (wrapping
    /// *any* statement or literal in a runtime selector is exactly the kind
    /// of rewrite a result builder does not expect either). Climbs every
    /// enclosing scope, not just the nearest, since a nested closure (a
    /// `ForEach` trailing closure, say) carries no attribute of its own. A
    /// custom, unlisted `@resultBuilder` type used as a closure's
    /// *parameter* type (not detectable without symbol resolution) is an
    /// accepted gap.
    static func isInsideResultBuilderBody(_ node: Syntax) -> Bool {
        var current: Syntax? = node
        while let scope = current {
            if hasBuilderAttribute(scope) || isBuilderReturningPropertyDeclaration(scope) {
                return true
            }
            current = scope.parent
        }
        return false
    }

    private static let knownBuilderAttributeNames: Set<String> = [
        "ViewBuilder", "SceneBuilder", "ToolbarContentBuilder",
        "WidgetBundleBuilder", "RegexComponentBuilder", "CommandsBuilder",
        "AccessibilityRotorContentBuilder"
    ]

    private static let knownBuilderPropertyNames: Set<String> = [
        "body", "commands", "previews", "content"
    ]

    /// Checks the enclosing function/accessor's own attributes, and the
    /// enclosing `VariableDeclSyntax`'s own attributes too: `@ViewBuilder
    /// var rows: some View { if ... }` has its `@ViewBuilder` sitting on
    /// the `VariableDeclSyntax`, not on any `AccessorDeclSyntax`, since an
    /// implicit (keyword-less) getter has no `AccessorDeclSyntax` at all.
    private static func hasBuilderAttribute(_ node: Syntax) -> Bool {
        let attributes: AttributeListSyntax
        if let function = node.as(FunctionDeclSyntax.self) {
            attributes = function.attributes
        } else if let accessor = node.as(AccessorDeclSyntax.self) {
            attributes = accessor.attributes
        } else if let variable = node.as(VariableDeclSyntax.self) {
            attributes = variable.attributes
        } else {
            return false
        }
        return attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self),
                  let name = attribute.attributeName.as(IdentifierTypeSyntax.self)
            else { return false }
            return knownBuilderAttributeNames.contains(name.name.text)
        }
    }

    /// Matched on name alone, the same pragmatic, not-symbol-resolved
    /// approach `LifecycleSuperCallRemovalOperator` takes for its lifecycle-
    /// method list — a `body`/`commands`/`previews`/`content` property
    /// under an unrelated protocol is a false positive this accepts (a
    /// missed, safe candidate; not a broken mutant).
    private static func isBuilderReturningPropertyDeclaration(_ node: Syntax) -> Bool {
        guard let binding = node.as(PatternBindingSyntax.self),
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
              binding.typeAnnotation != nil
        else { return false }
        return knownBuilderPropertyNames.contains(identifier.identifier.text)
    }

    /// True when `node` is used inside a pattern-matching *pattern*
    /// position — a `switch` case pattern, or the pattern half of `if
    /// case`/`guard case`/`for case`. All four share exactly one grammar
    /// node for this, `ExpressionPatternSyntax` ("an expression used as a
    /// pattern") — confirmed by parsing all four shapes and inspecting the
    /// resulting tree, not assumed. That node exists in SwiftSyntax's
    /// grammar *only* for this purpose: it never appears in a `where`
    /// clause (an ordinary `SequenceExprSyntax`/similar, a sibling of the
    /// pattern within `SwitchCaseItemSyntax`, not a descendant of it), a
    /// case body (an ordinary `CodeBlockItemListSyntax`), or any other
    /// plain expression context — so finding it anywhere in the ancestor
    /// chain is a precise structural test, not a heuristic keyed on "is
    /// this node somewhere inside a switch" (which would also, wrongly,
    /// exclude the body and the `where` clause).
    ///
    /// Climbs every ancestor, not just the immediate parent: a tuple or
    /// enum-associated-value pattern (`case (true, false):`, `case
    /// .success(true):`) nests the literal several levels below the
    /// `ExpressionPatternSyntax` itself, inside `TupleExprSyntax`/
    /// `FunctionCallExprSyntax`-shaped pattern content (confirmed directly
    /// against `SwiftParser` output, not assumed from the grammar alone —
    /// for `case (true, false):`, each literal's own ancestor chain is
    /// `labeledExpr` → `labeledExprList` → `tupleExpr` →
    /// `expressionPattern`, depth 3, never the immediate parent).
    ///
    /// Why this matters for schemata lowering specifically (isolated mode's
    /// literal byte-splice is unaffected): a lowerer that rewrites a
    /// literal into a runtime-selectable expression changes the compiler-
    /// visible pattern shape here, which can invalidate the compiler's
    /// exhaustiveness analysis or otherwise make schemata lowering unsound
    /// for pattern matching — not a hypothetical, see ADR-0008 Addendum 4's
    /// real-corpus finding (`SchemataUnsupportedReason.patternPosition`'s
    /// own doc comment).
    static func isInPatternPosition(_ node: some SyntaxProtocol) -> Bool {
        var cursor: Syntax? = Syntax(node).parent
        while let current = cursor {
            if current.is(ExpressionPatternSyntax.self) { return true }
            cursor = current.parent
        }
        return false
    }

    /// True when `node` *is* the whole condition of a `while` or a
    /// `repeat`-`while` — the position where a literal is load-bearing for
    /// the compiler's **reachability** analysis, not merely for its type
    /// checking.
    ///
    /// `while true { … }` is a provably-infinite loop, so the compiler does
    /// not require the enclosing function to return afterwards. Schemata
    /// lowering rewrites the literal into a runtime selector call
    /// (`__mutantkitIsActiveV3(…) ? false : true`), which is not a
    /// compile-time constant — the loop stops being provably infinite, and
    /// every enclosing non-`Void` function with no trailing `return` then
    /// fails to compile ("missing return in instance method expected to
    /// return …"). Real-corpus evidence, `swift-async-algorithms` 2026-08:
    /// one such site in `AsyncThrottleSequence.swift` broke its whole
    /// 93-member shared chunk's build, forfeiting the other 92 members'
    /// schemata fast path with it (a chunk shares one build, ADR-0008
    /// Addendum 4) — and the identical signature had already been recorded
    /// on `swift-argument-parser` before that.
    ///
    /// Deliberately narrower than "anywhere inside a while condition": a
    /// literal nested in a larger condition (`while x == true`,
    /// `while flag && true`) is not what the compiler folds into a
    /// reachability fact — such a condition was already runtime-evaluated
    /// before any lowering, so rewriting the literal changes nothing about
    /// reachability, and excluding it would cost eligible candidates for no
    /// safety gain. Parentheses are transparent (`while (true)` is still the
    /// literal as the condition), so enclosing single-element
    /// `TupleExprSyntax` wrappers are skipped, matching how the compiler
    /// itself sees through them.
    ///
    /// Syntactic only, and knowingly over-conservative in one direction:
    /// the compile error only actually bites when the enclosing function
    /// must return a value and has no terminator after the loop (measured —
    /// a sibling chunk on the same corpus contained two `while true`
    /// candidates and built fine). Deciding that precisely means analyzing
    /// the enclosing declaration's return type and control flow, a real
    /// semantic analysis; a syntactic exclusion costs a handful of
    /// candidates their fast path (they still run, in isolated mode, with an
    /// ordinary byte-splice that has none of this hazard) and never costs a
    /// whole chunk its build.
    static func isControlFlowConstantCondition(_ node: some SyntaxProtocol) -> Bool {
        var current = Syntax(node)
        while let parent = current.parent {
            // `repeat { … } while <condition>` — the condition is a bare
            // expression, so the literal is (modulo parentheses) its direct
            // child.
            if let repeatStatement = parent.as(RepeatStmtSyntax.self) {
                return Syntax(repeatStatement.condition) == current
            }
            // `while <condition> { … }` — a `ConditionElementListSyntax`,
            // whose single `.expression` element is the shape a bare literal
            // condition takes. A multi-element list (`while a, b`) or a
            // `case`/optional-binding element is never a compile-time
            // constant to begin with.
            if let element = parent.as(ConditionElementSyntax.self) {
                guard case let .expression(expression) = element.condition, Syntax(expression) == current,
                      let list = element.parent?.as(ConditionElementListSyntax.self), list.count == 1,
                      list.parent?.is(WhileStmtSyntax.self) == true
                else { return false }
                return true
            }
            // Only parentheses are transparent on the way up; anything else
            // (an operator expression, a call argument, a closure body)
            // means the literal is not the condition itself. A parenthesized
            // expression parses as a single unlabeled `TupleExprSyntax`
            // element, so its two intervening list nodes are stepped through
            // as well — an unlabeled element only, since `(a: true)` is a
            // real one-element tuple value, not parentheses.
            if let labeled = parent.as(LabeledExprSyntax.self), labeled.label == nil {
                current = parent
                continue
            }
            if parent.is(LabeledExprListSyntax.self) {
                current = parent
                continue
            }
            guard let tuple = parent.as(TupleExprSyntax.self), tuple.elements.count == 1 else { return false }
            current = Syntax(tuple)
        }
        return false
    }

    /// True when `node` sits anywhere inside the direct expression tree of
    /// a `while` or `repeat`-`while` condition — the same
    /// **reachability**, not merely typing, hazard
    /// `isControlFlowConstantCondition` exists for, generalized to every
    /// schemata lowerer whose own mutation target is a *sub-expression* of
    /// a larger boolean expression (a relational/logical operator token, a
    /// ternary's branches, a prefix `!`) rather than a bare literal that
    /// might itself *be* the whole condition.
    ///
    /// A zero-base review of the 5 registered schemata lowerers other
    /// than `BoolLiteralSchemataLowerer` confirmed empirically (real
    /// `swiftc -typecheck`, not assumed) that Swift's reachability folding
    /// for a `while`/`repeat`-`while` condition is **not** limited to the
    /// bare `true`/`false` token `isControlFlowConstantCondition` alone
    /// covers — `while 5 < 10`, `while true && true`, `while true ? true :
    /// true`, and `while !false` all compile with no trailing `return`
    /// exactly like `while true` does, meaning any of
    /// `RelationalOperatorReplacementSchemataLowerer`,
    /// `LogicalConnectorReplacementSchemataLowerer`,
    /// `TernaryBranchSwapSchemataLowerer`, or
    /// `UnaryNotRemovalSchemataLowerer` rewriting a site inside such a
    /// condition into a runtime selector call risks the exact same
    /// whole-chunk-build failure `isControlFlowConstantCondition`'s own
    /// doc comment cites a real corpus incident for
    /// (`AsyncThrottleSequence.swift`, 2026-08).
    ///
    /// Deliberately does **not** try to replicate Swift's own constant-
    /// folding rules precisely (a syntactic tool has no principled way to
    /// know which compound expressions the compiler will and will not
    /// fold for reachability, only that the set is broader than the one
    /// obvious case). Instead: any mutation target reachable from a
    /// while/repeat condition slot by climbing only through other
    /// expression nodes (`ExprSyntaxProtocol`) — parens, binary/ternary/
    /// prefix operators, anything an ordinary compound boolean expression
    /// is built from — is excluded from schemata lowering unconditionally,
    /// whether or not the *original*, unmutated condition actually is
    /// compile-time-constant. A false positive here costs one site its
    /// schemata fast path, falling back to isolated mode where it runs
    /// identically either way — never a broken chunk build, the same
    /// asymmetric trade-off `isControlFlowConstantCondition`'s own doc
    /// comment already accepts for its own, narrower check. Climbing stops
    /// (and reports `false`) at the first non-expression ancestor — a
    /// closure body, a call argument list boundary via a non-expression
    /// wrapper, a statement, or a declaration — since a condition
    /// expression's own reachability folding does not reach into what a
    /// nested closure or called function does internally.
    static func isInsideLoopConditionExpressionTree(_ node: some SyntaxProtocol) -> Bool {
        var current = Syntax(node)
        while let parent = current.parent {
            if let repeatStatement = parent.as(RepeatStmtSyntax.self) {
                return Syntax(repeatStatement.condition) == current
            }
            if let element = parent.as(ConditionElementSyntax.self) {
                guard case let .expression(expression) = element.condition, Syntax(expression) == current,
                      let list = element.parent?.as(ConditionElementListSyntax.self), list.count == 1,
                      list.parent?.is(WhileStmtSyntax.self) == true
                else { return false }
                return true
            }
            guard parent.asProtocol(SyntaxProtocol.self) is ExprSyntaxProtocol else { return false }
            current = parent
        }
        return false
    }
}
