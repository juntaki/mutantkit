import SwiftFrontend
import SwiftSyntax

/// Sites every operator must leave alone.
///
/// These are not stylistic preferences — each one produces mutants that are
/// guaranteed to be worthless or broken, and a report full of those is a report
/// developers stop reading.
enum OperatorExclusions {
    /// True when the node sits somewhere no mutation can produce a meaningful
    /// runtime difference.
    static func isExcluded(_ node: some SyntaxProtocol) -> Bool {
        let start = node.positionAfterSkippingLeadingTrivia
        let end = node.endPositionBeforeTrailingTrivia
        var cursor: Syntax? = Syntax(node).parent

        while let current = cursor {
            // Attribute arguments are compile-time metadata. Flipping the `true`
            // in `@available(*, deprecated, message:)` changes no behaviour a
            // test could observe.
            if current.is(AttributeSyntax.self) { return true }

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
}
