import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// A runtime identifier is an opaque key. Apple's shapes are not a version
/// scheme — `…SimRuntime.iOS-27-2-iPhone19-4` is OS 27.2 — so reading a version
/// or platform out of one broke every simulator job on `xcode-27-arm64`.
/// `SimulatorRuntimeCatalog` takes both from the runtime's `version` and
/// `platform` fields; this scan keeps the parsing from coming back, in
/// production `Sources/` and in the test support code that also touches `simctl`.
///
/// The scan works on SwiftSyntax tokens, not lines or a comment-stripping regex:
/// each file is parsed, trivia (whitespace, line/block/doc comments) is dropped,
/// and the remaining tokens are re-joined compactly — so a string literal such as
/// `"Sources/**"` can never start a comment, and a call chain split over several
/// lines reads as one. It flags *parsing*: searching or splitting a string for a
/// platform/`SimRuntime` token, splitting on `-` into integers, or
/// string-processing a runtime identifier. A bare mention of `SimRuntime` is fine
/// (recorded fixtures contain real identifiers). It cannot follow an identifier
/// passed through a differently-named variable, but it catches the spellings a
/// contributor would actually write.
@Suite("Simulator runtime identifiers stay opaque")
struct SimulatorRuntimeIdentifierGuardTests {
    private static let platformToken = #"(?:SimRuntime|(?:iOS|tvOS|watchOS|xrOS|visionOS)-(?:\d|"))"#
    private static let searchCall = #"\.(?:range|contains|localizedCaseInsensitiveContains|hasPrefix|hasSuffix)\((?:of:)?""#

    /// Patterns over the compact token text (no whitespace outside string literals).
    private static let patterns: [(String, String)] = [
        ("searching a string for a runtime/platform token", searchCall + #"[^"]*"# + platformToken),
        ("splitting on `-` into integer version components",
         #"(?:split\(separator:|components\(separatedBy:)"-"[^;]{0,120}?\bInt(?:\(|\.init)"#),
        ("splitting a runtime identifier on `-`", #"[rR]untime\w*\.(?:split\(separator:|components\(separatedBy:)"-""#),
        ("string-parsing a runtime identifier",
         #"[rR]untime(?:Identifier|Key)\b[^;]{0,60}?\.(?:range|split|components|hasPrefix|hasSuffix)\b"#),
        ("searching a runtime identifier", #"[rR]untimeIdentifier\.(?:localizedCaseInsensitiveContains|contains)\("#)
    ]

    /// Compact form of the one allowed use: the free-text `lease(matching:)` hint filter.
    private static let allowedCompact = ["device.runtimeIdentifier.localizedCaseInsensitiveContains(runtimeHint)"]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    /// `source`'s tokens without trivia, joined with a space only where two word
    /// characters would otherwise fuse, plus the source line of each character.
    static func compactTokens(of source: String) -> (text: String, lines: [Int]) {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "", tree: tree)
        var text = ""
        var lines: [Int] = []
        var depth = 0
        for token in tree.tokens(viewMode: .sourceAccurate) where token.tokenKind != .endOfFile {
            let piece = token.text
            guard let first = piece.first else { continue }
            if Self.isWordCharacter(text.last), Self.isWordCharacter(first) {
                text.append(" ")
                lines.append(0)
            }
            // A newline between tokens is a statement boundary for the `[^;]` bounds —
            // but only at top level: inside any `()`/`[]`/`{}` (a call spread over
            // lines, a closure with a `part in` signature or several statements) the
            // tokens stay joined — and never before a `.`/`?` that continues a chain.
            let continuesChain = piece == "." || piece == "?"
            if depth == 0, !continuesChain, text.last != ";", !text.isEmpty,
               token.leadingTrivia.pieces.contains(where: { $0.isNewline }) {
                text.append(";")
                lines.append(0)
            }
            switch token.tokenKind {
            case .leftParen, .leftSquare, .leftBrace: depth += 1
            case .rightParen, .rightSquare, .rightBrace: depth = max(depth - 1, 0)
            default: break
            }
            let line = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
            text.append(piece)
            lines.append(contentsOf: Array(repeating: line, count: piece.count))
        }
        return (text, lines)
    }

    static func violations(in source: String, path: String) -> [String] {
        var (text, lines) = compactTokens(of: source)
        for allowed in allowedCompact {
            while let range = text.range(of: allowed) {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let length = allowed.count
                text.replaceSubrange(range, with: String(repeating: "\u{0}", count: length))
                lines.replaceSubrange(start ..< start + length, with: Array(repeating: 0, count: length))
            }
        }
        var found: [String] = []
        for (description, pattern) in patterns {
            var searchRange = text.startIndex ..< text.endIndex
            while let range = text.range(of: pattern, options: .regularExpression, range: searchRange) {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                found.append("\(path):\(lines[start]): \(description): \(text[range].prefix(110))")
                searchRange = range.upperBound ..< text.endIndex
            }
        }
        return found
    }

    @Test("Sources/ and the test support code never parse a runtime identifier for a version or platform")
    func noIdentifierParsing() throws {
        var offences: [String] = []
        var scanned = 0
        for root in ["Sources", "Tests/MutantKitTests"] {
            let base = Self.repoRoot.appendingPathComponent(root)
            let files = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                if url.lastPathComponent == "SimulatorRuntimeIdentifierGuardTests.swift" { continue }
                scanned += 1
                offences += Self.violations(
                    in: try String(contentsOf: url, encoding: .utf8), path: String(url.path.dropFirst(Self.repoRoot.path.count + 1))
                )
            }
        }
        #expect(scanned > 300, "scan reached only \(scanned) files — wrong root?")
        #expect(offences.isEmpty, "Runtime identifiers must stay opaque; use SimulatorRuntimeCatalog:\n\(offences.joined(separator: "\n"))")
    }

    @Test("The scan flags the old parsing spellings (main's resolver, detector, pool and acceptance helper)")
    func scanCatchesTheOldSpellings() {
        let old = [
            #"guard let range = key.range(of: "SimRuntime.iOS-") else { return nil }"#,
            #"let components = versionPart.split(separator: "-").compactMap { Int($0) }"#,
            #"return runtimeIdentifier[range.upperBound...].split(separator: "-").compactMap { Int($0) }"#,
            #"let iOSDevices = devices.filter { $0.runtimeIdentifier.localizedCaseInsensitiveContains("SimRuntime.iOS") }"#,
            #"guard let range = runtimeIdentifier.range(of: "\(token)-") else { continue }"#,
            #"let parts = platformRuntimeIdentifier.split(separator: "-", maxSplits: 1).map(String.init)"#,
            #"let v = id.components(separatedBy: "-").compactMap(Int.init)"#,
            #"let v = id.split(separator: "-").compactMap(Int.init)"#,
            #"let parts = runtimeIdentifier.components(separatedBy: "-")"#,
            #"matches.first(where: { $0.runtimeIdentifier.localizedCaseInsensitiveContains(normalizedOS) })"#
        ]
        for line in old { #expect(!Self.violations(in: line, path: "X.swift").isEmpty, "\(line)") }
    }

    @Test("A runtimeIdentifier split spread over several lines is still seen")
    func multiLineChainIsSeen() {
        let chain = """
        let version = device
            .runtimeIdentifier
            .split(separator: "-")
            .compactMap { Int($0) }
        """
        #expect(!Self.violations(in: chain, path: "X.swift").isEmpty)
        let reported = Self.violations(in: "\n\n" + chain, path: "X.swift")
        #expect(reported.contains { $0.hasPrefix("X.swift:4:") }, "the chain starts on line 4 (runtimeIdentifier): \(reported)")
    }

    @Test("Multi-line closures, multi-line call arguments and `?.` chains are still seen")
    func spreadOutSpellingsAreSeen() {
        let closure = """
        let version = versionPart.split(separator: "-").compactMap {
            Int($0)
        }
        """
        let arguments = """
        let version = id.split(
            separator: "-"
        ).compactMap(Int.init)
        """
        let optional = """
        let version = runtimeIdentifier
            ?.split(separator: "-")
        """
        let signature = """
        let version = versionPart.split(separator: "-").compactMap { part in
            Int(part)
        }
        """
        let multiStatement = """
        func f() {
            let parts = id.split(separator: "-")
            let version = parts.compactMap { part in
                let value = Int(part)
                return value
            }
        }
        """
        for source in [closure, arguments, optional, signature, multiStatement] {
            #expect(!Self.violations(in: source, path: "X.swift").isEmpty, "\(source)")
        }
    }

    @Test("A newline is a statement boundary: unrelated neighbouring statements do not combine into a match")
    func statementsAreNotJoined() {
        let source = """
        let parts = path.split(separator: "-")
        let count = Int(total)
        """
        #expect(Self.violations(in: source, path: "X.swift").isEmpty)
    }

    @Test("A string literal that looks like a block comment cannot hide code after it")
    func commentLookingLiteralDoesNotBlankCode() {
        let source = """
        let globs = ["Sources/**", "Tests/**"]
        func parse(_ runtimeIdentifier: String) -> [Int] {
            runtimeIdentifier.split(separator: "-").compactMap { Int($0) }
        }
        let more = ["*/", "/*"]
        """
        #expect(!Self.violations(in: source, path: "X.swift").isEmpty)
    }

    @Test("Comments of every kind, and bare identifier mentions, are not violations")
    func commentsAndMentionsAreIgnored() {
        let harmless = [
            "// SimRuntime.iOS-27-2 is only mentioned in a comment",
            "/// guard let r = key.range(of: \"SimRuntime.iOS-\") else { return }",
            "/* SimRuntime identifiers are opaque. */",
            "/*\n parsing: key.range(of: \"SimRuntime.iOS-\")\n id.split(separator: \"-\").compactMap { Int($0) }\n*/",
            #"let id = SimctlFixtures.prefix + "iOS-27-2-iPhone19-4""#,
            "return device.runtimeIdentifier.localizedCaseInsensitiveContains(runtimeHint)\n    || device.name.isEmpty"
        ]
        for text in harmless {
            #expect(Self.violations(in: text, path: "X.swift").isEmpty, "\(text)")
        }
    }
}
