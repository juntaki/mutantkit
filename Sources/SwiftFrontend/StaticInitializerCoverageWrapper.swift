import Foundation
import SwiftParser
import SwiftSyntax

/// Makes the initializer of a lazily initialized global visible to a coverage run.
///
/// `static let descriptor = Descriptor(flag: false)` runs once, inside a `swift_once` thunk that the
/// compiler does not instrument, so the coverage export has no line records for it and no test can be
/// said to have evaluated it. Written as `static let descriptor = { Descriptor(flag: false) }()` the
/// same expression runs inside a closure, which is instrumented, on the same lines.
///
/// The rewrite is for the instrumented build of a coverage measurement only. The closure runs exactly
/// when the lazy initializer would, so behaviour is unchanged, and it adds characters but never a line
/// break, so every line number stays the one the mutation points use.
public enum StaticInitializerCoverageWrapper {
    /// `source` with every eligible initializer wrapped, or `nil` when there is none to wrap.
    /// `isMainFile` is true for `main.swift`, whose top-level variables are initialized eagerly.
    public static func rewrite(_ source: String, isMainFile: Bool = false) -> String? {
        let tree = Parser.parse(source: source)
        let collector = Collector(isMainFile: isMainFile)
        collector.walk(tree)
        guard !collector.ranges.isEmpty else { return nil }

        var utf8 = Array(source.utf8)
        for range in collector.ranges.sorted(by: { $0.start > $1.start }) {
            utf8.insert(contentsOf: Array(" }()".utf8), at: range.end)
            utf8.insert(contentsOf: Array("{ ".utf8), at: range.start)
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    private struct Span { var start: Int, end: Int }

    private final class Collector: SyntaxVisitor {
        let isMainFile: Bool
        var ranges: [Span] = []

        init(isMainFile: Bool) {
            self.isMainFile = isMainFile
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            if let span = eligibleInitializer(of: node) { ranges.append(span) }
            return .skipChildren
        }

        // A nested declaration is reached through the type or extension body, never through these.
        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

        private func eligibleInitializer(of node: VariableDeclSyntax) -> Span? {
            guard isLazilyInitialized(node), !hasUnsupportedAttribute(node),
                  node.bindings.count == 1, let binding = node.bindings.first,
                  binding.accessorBlock == nil, binding.pattern.is(IdentifierPatternSyntax.self),
                  let value = binding.initializer?.value
            else { return nil }
            if let type = binding.typeAnnotation?.type, type.description.contains("some ") { return nil }
            if !isSafeToWrap(value, hasAnnotation: binding.typeAnnotation != nil) { return nil }
            return Span(
                start: value.positionAfterSkippingLeadingTrivia.utf8Offset,
                end: value.endPositionBeforeTrailingTrivia.utf8Offset
            )
        }

        /// A `static`/`class` member of a type, or a global of a file that is not `main.swift`.
        private func isLazilyInitialized(_ node: VariableDeclSyntax) -> Bool {
            if node.modifiers.contains(where: { $0.name.text == "lazy" }) { return false }
            let isTypeLevel = node.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
            var cursor = node.parent
            while let parent = cursor {
                if parent.is(MemberBlockSyntax.self) { return isTypeLevel }
                if parent.is(SourceFileSyntax.self) { return !isTypeLevel && !isMainFile }
                cursor = parent.parent
            }
            return false
        }

        private func hasUnsupportedAttribute(_ node: VariableDeclSyntax) -> Bool {
            node.attributes.contains { element in
                guard case let .attribute(attribute) = element else { return true }
                return !["MainActor", "available", "nonisolated"].contains(attribute.attributeName.trimmedDescription)
            }
        }

        /// What the type checker would resolve differently once the value sits in a closure.
        private func isSafeToWrap(_ value: ExprSyntax, hasAnnotation: Bool) -> Bool {
            if value.is(TryExprSyntax.self) || value.is(AwaitExprSyntax.self) { return false }
            if let call = value.as(FunctionCallExprSyntax.self), call.calledExpression.is(ClosureExprSyntax.self) {
                return false
            }
            if !hasAnnotation {
                if value.is(NilLiteralExprSyntax.self) || value.is(MacroExpansionExprSyntax.self) { return false }
                if value.firstToken(viewMode: .sourceAccurate)?.tokenKind == .period { return false }
            }
            return true
        }
    }
}
