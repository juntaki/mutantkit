import MutationModel
import SwiftSyntax

/// Derives the declaration path enclosing a syntax node.
///
/// Syntax-only by design: no type checker, no index, no build. A USR would be
/// more precise, but it would make discovery depend on a working build — and
/// discovery has to run cheaply, offline, and before we know the project even
/// compiles.
///
/// The path only has to be stable enough to keep Mutation IDs steady when
/// *other* declarations in the file change. Renaming the enclosing function does
/// change the ID, and that is correct: it is a different mutation now.
public enum DeclarationIdentityResolver {
    /// Walks ancestors from `node` to the file root, collecting declaration names.
    public static func identity(for node: some SyntaxProtocol) -> DeclarationIdentity {
        var components: [String] = []
        var cursor: Syntax? = Syntax(node)

        while let current = cursor {
            if let component = self.component(for: current) {
                components.append(component)
            }
            cursor = current.parent
        }

        guard !components.isEmpty else { return .topLevel }
        // Collected innermost-first; the path reads outermost-first.
        return DeclarationIdentity(path: components.reversed())
    }

    private static func component(for node: Syntax) -> String? {
        if let decl = node.as(StructDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ClassDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(EnumDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ProtocolDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ActorDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(MacroDeclSyntax.self) { return decl.name.text }

        if let decl = node.as(ExtensionDeclSyntax.self) {
            return "extension \(decl.extendedType.trimmedDescription)"
        }

        if let decl = node.as(FunctionDeclSyntax.self) {
            return decl.name.text + argumentLabels(of: decl.signature.parameterClause)
        }

        if let decl = node.as(InitializerDeclSyntax.self) {
            return "init" + argumentLabels(of: decl.signature.parameterClause)
        }

        if node.is(DeinitializerDeclSyntax.self) { return "deinit" }

        if let decl = node.as(SubscriptDeclSyntax.self) {
            return "subscript" + argumentLabels(of: decl.parameterClause)
        }

        if let decl = node.as(VariableDeclSyntax.self) {
            // Multi-binding declarations (`let a = 1, b = 2`) are rare; joining
            // keeps the component deterministic rather than picking arbitrarily.
            let names = decl.bindings.map { $0.pattern.trimmedDescription }
            return names.isEmpty ? nil : names.joined(separator: ",")
        }

        if let decl = node.as(EnumCaseDeclSyntax.self) {
            let names = decl.elements.map(\.name.text)
            return names.isEmpty ? nil : names.joined(separator: ",")
        }

        if let accessor = node.as(AccessorDeclSyntax.self) {
            return accessor.accessorSpecifier.text
        }

        // Closures get an anonymous marker rather than being skipped: without it,
        // two identical literals in two closures inside one function would
        // collide on everything but occurrence index, making IDs shift whenever
        // the closures are reordered.
        if node.is(ClosureExprSyntax.self) { return "#closure" }

        return nil
    }

    /// Renders `(for:in:)`-style labels so overloads stay distinguishable.
    private static func argumentLabels(of clause: FunctionParameterClauseSyntax) -> String {
        let labels = clause.parameters.map { parameter in
            let label = parameter.firstName.text
            return label == "_" ? "_:" : "\(label):"
        }
        return "(" + labels.joined() + ")"
    }
}
