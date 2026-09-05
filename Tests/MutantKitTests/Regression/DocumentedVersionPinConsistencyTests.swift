import Foundation
import Testing

/// Turns a one-time manual audit into a permanent, mechanical gate — the
/// same stance `ProcessSupervisorBypassRegressionTests` takes, for a
/// different bug class.
///
/// The audit: `README.md` told every reader to pin
/// `uses: juntaki/mutantkit@v0.3.0` (three times, one of them annotated
/// "pin an exact release tag"), and `action.yml`'s `version:` input gave
/// `"v0.3.0"` as its example — while the only tags that have ever existed
/// are `v0.1.0-alpha.1`, `v0.1.0` and `v0.2.0`, and `README.md`'s own
/// status line three lines above the first bad pin said "Status: v0.2.0
/// (latest release)". A user copying the README's CI snippet got an
/// unresolvable action. It was byte-identical in the public repo, so it was
/// shipped, not merely drafted.
///
/// Nothing mechanical could have caught it: the version appears in prose,
/// in YAML the workflow linter never sees, and in a Markdown fence. The
/// only invariant available is an internal one, and it is enough —
/// **every MutantKit version this repository's user-facing documentation
/// names must be the version the documentation itself declares as the
/// latest release.** Whether that version has a matching git tag is the
/// release gate's job (`Scripts/release-gate.sh`), not this test's: a
/// snapshot checkout of the projected public tree has no tags to check
/// against, so a git-based assertion here would be untestable exactly
/// where it most needs to hold.
///
/// The scan is textual, per line, and deliberately narrow in one respect:
/// a `vX.Y.Z` inside a URL pointing somewhere other than this project's own
/// repository is somebody else's version number (the SARIF 2.1.0
/// specification link in `README.md` is the real instance) and is skipped.
/// Everything else — a pinned action ref, a release-download path, an
/// example in an input description, a version named in running prose — must
/// agree.
@Suite("Regression: documented MutantKit version pins agree with the declared release")
struct DocumentedVersionPinConsistencyTests {
    // MARK: - Locations

    /// `#filePath`-anchored, like `ProcessSupervisorBypassRegressionTests`:
    /// it resolves identically in this repository and in a projected public
    /// snapshot, and needs no environment, no git, and no build products.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/MutantKitTests/Regression/<this file>
            .deletingLastPathComponent() // Regression
            .deletingLastPathComponent() // MutantKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    /// Every file a user reads before typing a version. `docs/` and
    /// `skills/` are globbed rather than listed so a new document is
    /// covered the day it is added, which is exactly when a stale pin is
    /// most likely to be copied into it.
    private static var scannedFiles: [URL] {
        let root = repositoryRoot
        var files = [root.appendingPathComponent("README.md"), root.appendingPathComponent("action.yml")]
        for directory in ["docs", "skills"] {
            let base = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "md" {
                files.append(url)
            }
        }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Scanner

    struct VersionReference: Equatable, CustomStringConvertible {
        let version: String
        let file: String
        let line: Int
        let text: String

        var description: String { "\(file):\(line) — \(version) in: \(text.trimmingCharacters(in: .whitespaces))" }
    }

    /// Scanned by hand rather than by `NSRegularExpression`, for one
    /// practical reason: every regex here would have to be built with
    /// `try!` in a `static let`, which this project's lint configuration
    /// rejects (`force_try`) and its baseline comment forbids papering over.
    /// The grammar is small enough that the character walk below is both
    /// shorter to verify and directly unit-tested at the bottom of this file.
    ///
    /// Recognises `vMAJOR.MINOR.PATCH`, optionally followed by a
    /// `-prerelease` suffix, so `v0.1.0-alpha.1` — a tag this project really
    /// has cut — is read whole rather than silently truncated to `v0.1.0`.
    /// Boundaries match what `\bv…\b` would do: the character before the
    /// `v` and the character after the token must not be alphanumeric.
    static func versionReferences(in text: String, file: String) -> [VersionReference] {
        var found: [VersionReference] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            for version in versionTokens(in: maskingForeignURLs(rawLine)) {
                found.append(VersionReference(version: version, file: file, line: index + 1, text: rawLine))
            }
        }
        return found
    }

    static func versionTokens(in line: String) -> [String] {
        let characters = Array(line)
        var tokens: [String] = []
        var index = 0

        while index < characters.count {
            guard characters[index] == "v" else { index += 1; continue }
            // Leading boundary: `sarif-v2.1.0` still starts a token (`-` is
            // not alphanumeric), matching `\b`; `revv1.2.3` does not.
            if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber {
                index += 1
                continue
            }
            guard let end = versionTokenEnd(characters, from: index) else { index += 1; continue }
            tokens.append(String(characters[index ..< end]))
            index = end
        }
        return tokens
    }

    /// The index just past a well-formed version token starting at `start`,
    /// or `nil` if what follows the `v` is not one.
    private static func versionTokenEnd(_ characters: [Character], from start: Int) -> Int? {
        var index = start + 1
        for component in 0 ..< 3 {
            let digitsStart = index
            while index < characters.count, characters[index].isNumber { index += 1 }
            guard index > digitsStart else { return nil }
            if component < 2 {
                guard index < characters.count, characters[index] == "." else { return nil }
                index += 1
            }
        }
        // Optional `-prerelease`, itself alphanumeric-and-dots.
        if index < characters.count, characters[index] == "-" {
            let suffixStart = index + 1
            var suffixEnd = suffixStart
            while suffixEnd < characters.count,
                  characters[suffixEnd].isLetter || characters[suffixEnd].isNumber || characters[suffixEnd] == "." {
                suffixEnd += 1
            }
            if suffixEnd > suffixStart { index = suffixEnd }
        }
        // Trailing boundary.
        if index < characters.count, characters[index].isLetter || characters[index].isNumber { return nil }
        return index
    }

    /// Blanks every character of a URL that does not point at this
    /// project's own repository, so nothing inside it can match.
    ///
    /// Masked rather than allow-listed by value on purpose: an allow-list
    /// keyed on the literal `v2.1.0` (the SARIF specification link in
    /// `README.md`, the only real instance today) would also silence a
    /// genuine MutantKit `v2.1.0` pin the day one exists.
    static func maskingForeignURLs(_ line: String) -> String {
        var characters = Array(line)
        var index = 0
        while index < characters.count {
            guard characters[index] == "h",
                  let schemeEnd = matchScheme(characters, at: index) else { index += 1; continue }
            var end = schemeEnd
            while end < characters.count, !" \t`)]".contains(characters[end]) { end += 1 }
            if !String(characters[index ..< end]).contains("juntaki/mutantkit") {
                for position in index ..< end { characters[position] = " " }
            }
            index = end
        }
        return String(characters)
    }

    /// The index just past `http://` or `https://` starting at `start`.
    private static func matchScheme(_ characters: [Character], at start: Int) -> Int? {
        for scheme in ["https://", "http://"] {
            let scheme = Array(scheme)
            guard start + scheme.count <= characters.count else { continue }
            if Array(characters[start ..< start + scheme.count]) == scheme { return start + scheme.count }
        }
        return nil
    }

    /// The one version the documentation declares authoritative, read from
    /// `README.md`'s own status line.
    static func declaredLatestRelease(in readme: String) -> String? {
        for line in readme.components(separatedBy: .newlines) where line.contains("(latest release)") {
            if let version = versionTokens(in: maskingForeignURLs(line)).first { return version }
        }
        return nil
    }

    // MARK: - The gate

    @Test("README declares exactly one latest release, and it parses")
    func readmeDeclaresALatestRelease() throws {
        let readme = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let declared = try #require(
            Self.declaredLatestRelease(in: readme),
            "README.md must carry a line naming the latest release, e.g. \"**Status: v0.2.0 (latest release)**\""
        )
        #expect(declared.hasPrefix("v"))

        let declaringLines = readme.components(separatedBy: .newlines).filter { $0.contains("(latest release)") }
        #expect(
            declaringLines.count == 1,
            "exactly one line may declare the latest release, or there is no single source of truth; found \(declaringLines.count)"
        )
    }

    @Test("Every documented MutantKit version equals the declared latest release")
    func everyDocumentedVersionMatchesTheDeclaredRelease() throws {
        let readme = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let declared = try #require(Self.declaredLatestRelease(in: readme))

        var mismatches: [VersionReference] = []
        var scanned = 0
        for file in Self.scannedFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
            for reference in Self.versionReferences(in: text, file: relative) {
                scanned += 1
                if reference.version != declared { mismatches.append(reference) }
            }
        }

        // Zero references would mean the scan silently covered nothing --
        // "no work" must not read as "passed", the same way this project
        // refuses to treat an empty test filter as a green run.
        #expect(scanned > 0, "the version scan matched nothing at all; the file set or the pattern is wrong")

        #expect(
            mismatches.isEmpty,
            """
            \(mismatches.count) documented version(s) disagree with README's declared latest release (\(declared)):
            \(mismatches.map(\.description).joined(separator: "\n"))

            Either the pin is stale, or the release was cut and README's status line was not updated.
            A tag that does not exist makes `uses: juntaki/mutantkit@<tag>` unresolvable for every user
            who copies the snippet.
            """
        )
    }

    // MARK: - The scanner itself is tested, not assumed

    @Test("The scan catches the exact shape of the bug it exists to prevent")
    func scanCatchesAStalePin() {
        let document = """
        > **Status: v0.2.0 (latest release), in active development.**

        ```yaml
        - uses: juntaki/mutantkit@v0.3.0   # pin an exact release tag
        ```
        """
        let declared = Self.declaredLatestRelease(in: document)
        #expect(declared == "v0.2.0")

        let references = Self.versionReferences(in: document, file: "fixture.md")
        #expect(references.map(\.version) == ["v0.2.0", "v0.3.0"])
        #expect(references.filter { $0.version != declared }.map(\.line) == [4])
    }

    @Test("A version inside a foreign URL is not a MutantKit version")
    func foreignURLVersionsAreIgnored() {
        let line = "see [SARIF 2.1.0](https://docs.oasis-open.org/sarif/sarif/v2.1.0/os/sarif-v2.1.0-os.html)"
        #expect(Self.versionReferences(in: line, file: "fixture.md").isEmpty)
    }

    @Test("A version inside this project's own release URL is still checked")
    func projectOwnURLVersionsAreChecked() {
        let line = "https://github.com/juntaki/mutantkit/releases/download/v9.9.9/mutantkit.tar.gz"
        #expect(Self.versionReferences(in: line, file: "fixture.md").map(\.version) == ["v9.9.9"])
    }

    @Test("A pre-release tag is read whole, not truncated to its release part")
    func preReleaseTagsAreReadWhole() {
        let references = Self.versionReferences(in: "pinned at v0.1.0-alpha.1 for now", file: "fixture.md")
        #expect(references.map(\.version) == ["v0.1.0-alpha.1"])
    }
}
