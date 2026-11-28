import SwiftSyntax

/// `// mutantkit:disable-next-line [operator, ...]` and
/// `// mutantkit:disable-line [operator, ...]`, read from the real line-comment
/// trivia of the tree discovery already parsed.
///
/// Only a `//` comment token piece can carry a directive: the text of a string
/// literal (single-line, multiline or raw), a block comment or a doc comment is
/// never trivia of that kind, so none of them can suppress anything. Lines are
/// the syntax tree's own (`\n`, `\r\n` and a lone `\r` each end one line), so a
/// CRLF file needs no special casing and the comment text never carries a `\r`.
public struct InlineSuppressionScan: Sendable, Equatable {
    public struct Directive: Sendable, Equatable {
        /// 1-based line the suppression applies to: the comment's own line for
        /// `disable-line`, the following one for `disable-next-line`.
        public let targetLine: Int
        /// Empty means every operator on `targetLine`.
        public let operatorIDs: [String]
        /// 1-based line of the comment itself, for diagnostics.
        public let commentLine: Int

        public init(targetLine: Int, operatorIDs: [String], commentLine: Int) {
            self.targetLine = targetLine
            self.operatorIDs = operatorIDs
            self.commentLine = commentLine
        }
    }

    /// A comment that starts `mutantkit:disable` but is not a well-formed
    /// directive (unknown keyword, empty operator-list element). Reported, never
    /// silently turned into a rule that matches nothing.
    public struct Malformed: Sendable, Equatable {
        public let commentLine: Int
        public let text: String
    }

    public var directives: [Directive] = []
    public var malformed: [Malformed] = []

    public init() {}

    private static let nextLine = "mutantkit:disable-next-line"
    private static let sameLine = "mutantkit:disable-line"

    static func scan(_ tree: SourceFileSyntax, converter: SourceLocationConverter) -> InlineSuppressionScan {
        var result = InlineSuppressionScan()
        for token in tree.tokens(viewMode: .sourceAccurate) {
            var position = token.position
            for piece in token.leadingTrivia {
                result.consume(piece, at: position, converter: converter)
                position += piece.sourceLength
            }
            position = token.endPositionBeforeTrailingTrivia
            for piece in token.trailingTrivia {
                result.consume(piece, at: position, converter: converter)
                position += piece.sourceLength
            }
        }
        return result
    }

    private mutating func consume(_ piece: TriviaPiece, at position: AbsolutePosition, converter: SourceLocationConverter) {
        guard case let .lineComment(raw) = piece else { return }
        let body = raw.dropFirst(2).drop(while: { $0 == " " || $0 == "\t" })
        guard body.hasPrefix("mutantkit:disable") else { return }

        let line = converter.location(for: position).line
        let keyword = body.prefix(while: { $0 != " " && $0 != "\t" })
        let target: Int
        switch keyword {
        case Self.nextLine[...]: target = line + 1
        case Self.sameLine[...]: target = line
        default:
            malformed.append(Malformed(commentLine: line, text: String(raw)))
            return
        }

        let list = body.dropFirst(keyword.count).trimmingWhitespace()
        guard !list.isEmpty else {
            directives.append(Directive(targetLine: target, operatorIDs: [], commentLine: line))
            return
        }
        let ids = list.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingWhitespace() }
        guard !ids.contains(where: \.isEmpty), !ids.contains(where: { $0.contains(where: { $0 == " " || $0 == "\t" }) }) else {
            malformed.append(Malformed(commentLine: line, text: String(raw)))
            return
        }
        directives.append(Directive(targetLine: target, operatorIDs: ids.map(String.init), commentLine: line))
    }
}

private extension Substring {
    func trimmingWhitespace() -> Substring {
        var s = self
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
        return s
    }
}
