import MutationModel
import SwiftSyntax

/// Fingerprints of the tokens surrounding a mutation site.
///
/// These exist to make a *stale anchor* diagnosable. The file hash already tells
/// us the file changed; the fingerprints tell us whether the code around this
/// specific mutation is still the code the operator matched. That is the
/// difference between "your file changed, re-plan" and the failure this design
/// forbids — quietly applying an edit at a byte offset that now points at
/// something else.
public enum TokenFingerprint {
    /// Three tokens is enough to distinguish neighbouring occurrences of the
    /// same literal without making the fingerprint fragile to distant edits.
    public static let contextTokenCount = 3

    /// Fingerprint of the `contextTokenCount` tokens immediately before `node`.
    ///
    /// Token *text* only — trivia is excluded so that reformatting or a changed
    /// comment does not invalidate an otherwise-valid anchor.
    public static func prefix(of node: some SyntaxProtocol) -> String {
        guard let firstToken = node.firstToken(viewMode: .sourceAccurate) else {
            return digest(of: [])
        }

        var tokens: [String] = []
        var cursor = firstToken.previousToken(viewMode: .sourceAccurate)
        while let token = cursor, tokens.count < contextTokenCount {
            tokens.append(token.text)
            cursor = token.previousToken(viewMode: .sourceAccurate)
        }

        // Collected walking backwards; reverse so the fingerprint reads in
        // source order and stays comparable to how a human would describe it.
        return digest(of: tokens.reversed())
    }

    /// Fingerprint of the `contextTokenCount` tokens immediately after `node`.
    public static func suffix(of node: some SyntaxProtocol) -> String {
        guard let lastToken = node.lastToken(viewMode: .sourceAccurate) else {
            return digest(of: [])
        }

        var tokens: [String] = []
        var cursor = lastToken.nextToken(viewMode: .sourceAccurate)
        while let token = cursor, tokens.count < contextTokenCount {
            tokens.append(token.text)
            cursor = token.nextToken(viewMode: .sourceAccurate)
        }

        return digest(of: tokens)
    }

    /// Fingerprint of the replaced text itself. This is a Mutation ID input.
    public static func ofOriginalText(_ text: String) -> String {
        ContentHash.shortDigest(of: text)
    }

    private static func digest(of tokens: some Sequence<String>) -> String {
        // The unit separator cannot occur in Swift token text, so the joined
        // preimage is unambiguous.
        ContentHash.shortDigest(of: tokens.joined(separator: "\u{1F}"), length: 12)
    }
}
