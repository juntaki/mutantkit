import Foundation
import MutationModel
import SwiftParser
import SwiftSyntax

/// Finds the function a default-argument expression belongs to.
///
/// A literal in a default argument (`flag: Bool = false`) has no coverage region of its own, so a
/// baseline coverage run cannot say which tests evaluated it. What it can say is which tests ran the
/// owning function's body, and that is enough to narrow the tests a mutant on the literal needs: the
/// default is only evaluated to be passed to the owner, so a test that never enters the owner cannot
/// observe the change.
public enum DefaultArgumentOwner {
    /// The 1-based line range of the function, initializer or subscript whose parameter list holds the
    /// default value that contains `range`, or `nil` when `range` is not inside a default argument.
    public static func lineRange(in source: Data, containing range: ByteRange) -> ClosedRange<Int>? {
        let text = String(decoding: source, as: UTF8.self)
        let tree = Parser.parse(source: text)
        guard let token = tree.token(at: AbsolutePosition(utf8Offset: range.start)) else { return nil }

        var insideDefault = false
        var cursor: Syntax? = Syntax(token)
        while let node = cursor {
            if let parameter = node.as(FunctionParameterSyntax.self) {
                guard let defaultValue = parameter.defaultValue,
                      defaultValue.positionAfterSkippingLeadingTrivia.utf8Offset <= range.start,
                      range.end <= defaultValue.endPositionBeforeTrailingTrivia.utf8Offset
                else { return nil }
                insideDefault = true
            } else if insideDefault, isOwner(node) {
                let converter = SourceLocationConverter(fileName: "", tree: tree)
                let first = node.startLocation(converter: converter).line
                let last = node.endLocation(converter: converter).line
                return first ... max(first, last)
            }
            cursor = node.parent
        }
        return nil
    }

    private static func isOwner(_ node: Syntax) -> Bool {
        node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self) || node.is(SubscriptDeclSyntax.self)
    }
}
