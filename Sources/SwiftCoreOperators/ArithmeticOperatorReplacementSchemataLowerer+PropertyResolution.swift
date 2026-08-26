import Foundation
import MutationModel
import SwiftFrontend
import SwiftSyntax

// MARK: - Stored-property and extension-boundary resolution

//
// Split into its own file purely to keep `file_length` reviewable — still
// the same single type, same behavior, no logic split.
extension ArithmeticOperatorReplacementSchemataLowerer {
    /// `self.x`-only resolution: walks up to the nearest enclosing
    /// struct/class/enum/extension and checks only its own direct property
    /// declarations that are *stored* — no accessor block at all (`{ get
    /// ... }`/`{ willSet ... }` etc. all disqualify; a plain `{ get }`
    /// requirement-only accessor block, which can only appear in a
    /// protocol, is likewise never treated as stored). A computed property
    /// slipping through would still only cost one extra evaluation of its
    /// getter (bounded, no correctness hazard on its own — the ternary
    /// still evaluates the selected branch exactly once), but this lowerer
    /// only ever claims "declared type," and a computed property's declared
    /// type is not evidence its *stored* backing (if any) shares that same
    /// type — never a function parameter or local of the same name, and
    /// never descending into a nested type's members.
    static func declaredType(ofStoredPropertyNamed name: String, near node: Syntax, depth: Int = 0) -> NameLookup {
        guard depth < maxResolutionDepth else { return .notFound }
        var cursor: Syntax? = node.parent
        while let current = cursor {
            if let members = Self.memberBlock(of: current) {
                if let result = Self.lookUpStoredProperty(named: name, in: members, depth: depth) {
                    return result
                }
                // Swift never allows a *stored* property to be declared in
                // an extension — only the primary struct/class/enum
                // declaration can. `splitCount`/`sequenceLength` in
                // `apple/swift-algorithms`' `Split.swift` are exactly this
                // shape: the primary `struct Iterator { ... }` declares
                // them, but the mutation site itself is referenced from a
                // *separate* `extension SplitSequence.Iterator:
                // IteratorProtocol { ... }` block — a real gap round-3 Codex
                // review flagged as a false negative, not a false positive,
                // and real known-hang site inspection then found it
                // structurally blocks this exact site. Only an extension
                // ever needs this fallback; a plain struct/class/enum
                // already IS the primary declaration, so finding nothing in
                // its own members means the property is genuinely not
                // there.
                if let extensionDecl = current.as(ExtensionDeclSyntax.self) {
                    return Self.lookUpStoredPropertyInPrimaryDeclaration(
                        named: name, extendedType: extensionDecl.extendedType, near: current, depth: depth
                    )
                }
                return .notFound
            }
            cursor = current.parent
        }
        return .notFound
    }

    private static func memberBlock(of node: Syntax) -> MemberBlockItemListSyntax? {
        if let structDecl = node.as(StructDeclSyntax.self) { return structDecl.memberBlock.members }
        if let classDecl = node.as(ClassDeclSyntax.self) { return classDecl.memberBlock.members }
        if let enumDecl = node.as(EnumDeclSyntax.self) { return enumDecl.memberBlock.members }
        if let extensionDecl = node.as(ExtensionDeclSyntax.self) { return extensionDecl.memberBlock.members }
        return nil
    }

    private static func lookUpStoredProperty(named name: String, in members: MemberBlockItemListSyntax, depth: Int) -> NameLookup? {
        for member in members {
            guard let variableDecl = member.decl.as(VariableDeclSyntax.self), bindingNames(variableDecl).contains(name) else { continue }
            let resolvedType = Self.declaredType(ofBindingNamed: name, in: variableDecl, depth: depth)
            guard Self.isStoredOnly(variableDecl), let type = resolvedType else {
                return .shadowed
            }
            return .type(type)
        }
        return nil
    }

    /// Resolves `extendedType`'s own dotted path (`SplitSequence.Iterator`)
    /// against the enclosing source file's top-level declarations, nesting
    /// level by nesting level — never a same-simple-name match anywhere in
    /// the file (which could silently find an unrelated type's differently-
    /// typed same-named property), only the exact nested declaration this
    /// specific dotted path names. `.notFound` (not `.shadowed`) whenever
    /// the path cannot be resolved this precisely — a miss here means
    /// "cannot prove," not "proven unsafe." A module-qualified extension
    /// (`extension MyModule.Outer.Inner`) is one such miss, by construction:
    /// the leading module-name component never matches any declaration at
    /// this file's own top level, so the whole lookup safely falls through
    /// to `.notFound` rather than resolving the wrong type — a known,
    /// accepted coverage gap (independent Codex implementation review, round
    /// 4), not a soundness one.
    private static func lookUpStoredPropertyInPrimaryDeclaration(
        named name: String, extendedType: TypeSyntax, near node: Syntax, depth: Int
    ) -> NameLookup {
        let pathComponents = extendedType.trimmedDescription.split(separator: ".").map(String.init)
        guard !pathComponents.isEmpty else { return .notFound }
        var cursor: Syntax? = node
        while let current = cursor, !current.is(SourceFileSyntax.self) {
            cursor = current.parent
        }
        guard let sourceFile = cursor?.as(SourceFileSyntax.self) else { return .notFound }
        let topLevelMembers = MemberBlockItemListSyntax(
            sourceFile.statements.compactMap { item -> MemberBlockItemSyntax? in
                guard let decl = item.item.as(DeclSyntax.self) else { return nil }
                return MemberBlockItemSyntax(decl: decl)
            }
        )
        guard let resolvedMembers = Self.resolveNestedTypeMembers(pathComponents: pathComponents[...], in: topLevelMembers) else {
            return .notFound
        }
        return Self.lookUpStoredProperty(named: name, in: resolvedMembers, depth: depth) ?? .notFound
    }

    /// A path component can be declared as a nested type inside the primary
    /// struct/class/enum, *or* inside a separate `extension` of the parent
    /// type declared elsewhere at the same scope — real Swift allows a
    /// nested type declaration inside an extension (unlike a stored
    /// property, which never can be). `apple/swift-algorithms`' Split.swift
    /// is exactly this shape: `struct Iterator` is declared inside
    /// `extension SplitSequence: Sequence { struct Iterator { ... } }`, a
    /// sibling of the primary `struct SplitSequence<Base: Sequence> { ... }`
    /// declaration, not inside it. Every container at this scope whose name
    /// (or, for an extension, whose `extendedType`) matches `first` is
    /// collected and its members merged before continuing — not just the
    /// first match — so a type split across a primary declaration and one
    /// or more extensions still resolves as a single combined scope.
    private static func resolveNestedTypeMembers(
        pathComponents: ArraySlice<String>, in members: MemberBlockItemListSyntax
    ) -> MemberBlockItemListSyntax? {
        guard let first = pathComponents.first else { return nil }
        let containers = Self.collectContainers(named: first, in: members)
        guard !containers.isEmpty else { return nil }
        let combined = MemberBlockItemListSyntax(containers.flatMap(Array.init))
        let remaining = pathComponents.dropFirst()
        return remaining.isEmpty ? combined : Self.resolveNestedTypeMembers(pathComponents: remaining, in: combined)
    }

    private static func collectContainers(named name: String, in members: MemberBlockItemListSyntax) -> [MemberBlockItemListSyntax] {
        var containers: [MemberBlockItemListSyntax] = []
        for member in members {
            if let structDecl = member.decl.as(StructDeclSyntax.self), structDecl.name.text == name {
                containers.append(structDecl.memberBlock.members)
            } else if let classDecl = member.decl.as(ClassDeclSyntax.self), classDecl.name.text == name {
                containers.append(classDecl.memberBlock.members)
            } else if let enumDecl = member.decl.as(EnumDeclSyntax.self), enumDecl.name.text == name {
                containers.append(enumDecl.memberBlock.members)
            } else if let extensionDecl = member.decl.as(ExtensionDeclSyntax.self), extensionDecl.extendedType.trimmedDescription == name {
                containers.append(extensionDecl.memberBlock.members)
            }
        }
        return containers
    }

    /// `true` only when every binding in this `VariableDeclSyntax` has no
    /// accessor block whatsoever — a computed property, an observed
    /// property (`didSet`/`willSet`), and a protocol's `{ get set }`
    /// requirement all carry an `accessorBlock` and are excluded.
    private static func isStoredOnly(_ variableDecl: VariableDeclSyntax) -> Bool {
        variableDecl.bindings.allSatisfy { $0.accessorBlock == nil }
    }

    static func isDirectlyWrappedInTryOrAwait(_ infix: InfixOperatorExprSyntax) -> Bool {
        var current = Syntax(infix)
        while let parent = current.parent {
            if parent.is(LabeledExprSyntax.self) || parent.is(LabeledExprListSyntax.self) {
                current = parent
                continue
            }
            if let tuple = parent.as(TupleExprSyntax.self), tuple.elements.count == 1, tuple.elements.first?.label == nil {
                current = parent
                continue
            }
            if parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) { return true }
            return false
        }
        return false
    }

    static func unwrapParentheses(_ expr: ExprSyntax) -> ExprSyntax {
        var current = expr
        while let tuple = current.as(TupleExprSyntax.self), tuple.elements.count == 1, tuple.elements.first?.label == nil {
            current = tuple.elements.first!.expression
        }
        return current
    }
}
