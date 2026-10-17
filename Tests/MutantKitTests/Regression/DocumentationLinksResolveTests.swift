import Foundation
import Testing

/// Every relative link in the documentation a user reads must point at a file
/// that exists. A document that is renamed, merged or removed leaves the links
/// to it broken, and nothing else in `swift test` would notice.
///
/// Only relative links are checked. A URL (`https://…`, `mailto:`) is somebody
/// else's resource and an in-page anchor (`#section`) needs no file. For
/// `path#anchor` the file must exist; the anchor itself is not checked. Fenced
/// code blocks and inline code are skipped, because a link written inside code
/// is an example, not a link.
///
/// `#filePath`-anchored, like `DocumentedVersionPinConsistencyTests`: it
/// resolves identically in a development checkout and in a projected public
/// snapshot.
@Suite("Regression: relative links in the documentation resolve to files")
struct DocumentationLinksResolveTests {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/MutantKitTests/Regression/<this file>
            .deletingLastPathComponent() // Regression
            .deletingLastPathComponent() // MutantKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    /// The top-level documents plus everything under `docs/` and `skills/`,
    /// globbed so a new document is covered the day it is added.
    private static var documents: [URL] {
        let root = repositoryRoot
        var files = ["README.md", "README.ja.md", "CONTRIBUTING.md", "SECURITY.md"].map { root.appendingPathComponent($0) }
        for directory in ["docs", "skills"] {
            let base = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "md" {
                files.append(url)
            }
        }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    struct Link: Equatable {
        let line: Int
        let target: String
    }

    private static let linkPattern = makeRegex(#"\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)
    private static let inlineCodePattern = makeRegex(#"`[^`]*`"#)

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            fatalError("invalid regular expression \(pattern): \(error)")
        }
    }

    /// The relative link targets in `text`, with the 1-based line each is on.
    static func relativeLinks(in text: String) -> [Link] {
        var links: [Link] = []
        var inFence = false
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            let line = inlineCodePattern.stringByReplacingMatches(
                in: rawLine, range: NSRange(rawLine.startIndex..., in: rawLine), withTemplate: ""
            )
            let range = NSRange(line.startIndex..., in: line)
            for match in linkPattern.matches(in: line, range: range) {
                guard let targetRange = Range(match.range(at: 1), in: line) else { continue }
                var target = String(line[targetRange])
                if target.hasPrefix("#") || target.contains("://") || target.hasPrefix("mailto:") { continue }
                if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
                if let query = target.firstIndex(of: "?") { target = String(target[..<query]) }
                if target.isEmpty { continue }
                links.append(Link(line: index + 1, target: target))
            }
        }
        return links
    }

    @Test("Every relative link in README, CONTRIBUTING, SECURITY, docs/ and skills/ points at an existing file")
    func relativeLinksResolve() throws {
        var broken: [String] = []
        var checked = 0
        for document in Self.documents {
            let text = try String(contentsOf: document, encoding: .utf8)
            let directory = document.deletingLastPathComponent()
            let relative = document.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
            for link in Self.relativeLinks(in: text) {
                checked += 1
                let target = (link.target.removingPercentEncoding ?? link.target)
                let resolved = directory.appendingPathComponent(target).standardizedFileURL
                if !FileManager.default.fileExists(atPath: resolved.path) {
                    broken.append("\(relative):\(link.line) -> \(link.target)")
                }
            }
        }
        #expect(checked > 0, "no relative links were found; the document set or the link pattern is wrong")
        #expect(broken.isEmpty, "broken relative links:\n\(broken.joined(separator: "\n"))")
    }

    @Test("The link scanner reads inline links, skips URLs, anchors, code spans and fenced blocks")
    func scannerRecognisesLinkShapes() {
        let text = """
        See [a](docs/a.md) and [b](../b.md#section "title") and [c](<spaced.md>).
        An [external](https://example.com/x.md), an [anchor](#top), and `[code](docs/code.md)`.
        ```
        [fenced](docs/fenced.md)
        ```
        Last: ![img](assets/logo.png)
        """
        let targets = Self.relativeLinks(in: text).map(\.target)
        #expect(targets == ["docs/a.md", "../b.md", "spaced.md", "assets/logo.png"])
    }
}
