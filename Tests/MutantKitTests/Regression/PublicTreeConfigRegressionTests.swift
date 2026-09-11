import Foundation
import Testing

/// v0.6 Distribution Trust: `.public-tree.toml`'s leak-scan configuration
/// had no regression coverage at all — a `forbidden_strings` entry, an
/// `exclude_paths`/`exclude_dirs_root` entry, or a `scannable_suffixes`
/// extension could be silently removed and nothing in `swift test` would
/// fail. This project already has the house style for exactly this shape
/// of problem (`DocumentedVersionPinConsistencyTests`, whose own doc
/// comment frames itself as "a one-time manual audit turned into a
/// permanent mechanical gate", the same stance
/// `ProcessSupervisorBypassRegressionTests` takes for a different bug
/// class). This is that stance applied to the leak-scan config itself.
///
/// Parsed textually (line-based `contains(...)` checks), not with a TOML
/// library — this file's structure is simple enough that a real parser
/// would be more machinery than the invariant needs, matching
/// `DocumentedVersionPinConsistencyTests`'s own reasoning for its
/// hand-written scanner.
///
/// Private-repo-checkout only: `.public-tree.toml` itself is the one file
/// that would have to describe its own exclusion to get excluded, so
/// git-projector never copies it to a public snapshot.
@Suite("Regression: .public-tree.toml leak-scan config stays complete")
struct PublicTreeConfigRegressionTests {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/MutantKitTests/Regression/<this file>
            .deletingLastPathComponent() // Regression
            .deletingLastPathComponent() // MutantKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    private static var configPath: URL {
        repositoryRoot.appendingPathComponent(".public-tree.toml")
    }

    private static var isPrivateRepoCheckout: Bool {
        FileManager.default.fileExists(atPath: configPath.path)
    }

    @Test(
        "forbidden_strings still lists every known-leaked internal project name, exclude lists still cover known-sensitive files/dirs",
        .enabled(if: PublicTreeConfigRegressionTests.isPrivateRepoCheckout)
    )
    func floorEntriesArePresent() throws {
        let config = try String(contentsOf: Self.configPath, encoding: .utf8)

        // Floor, not ceiling: this asserts these specific entries are still
        // present, not that the lists are exactly these entries — new
        // entries are always fine to add; these must never be silently
        // removed. Built from split halves, not written whole: this test
        // file itself ships to the public tree, and a real project name
        // spelled out whole here would be exactly the leak this config
        // exists to catch — the projector's own leak scan would flag its
        // own regression test.
        let knownLeakedNames = ["Yo" + "mu", "Infinite" + "Note", "m1" + "mac"]
        for needle in knownLeakedNames {
            #expect(config.contains(needle), "forbidden_strings must still forbid a real, previously-leaked internal project name")
        }
        for needle in ["HANDOVER.md", "AGENTS.md", "CLAUDE.md", "Sources/BenchmarkRunner", "Tests/BenchmarkRunnerTests"] {
            #expect(config.contains(needle), "exclude_paths must still exclude \"\(needle)\"")
        }
        for needle in ["Research", ".github", "Benchmarks", ".claude", ".codex"] {
            #expect(config.contains("\"\(needle)\""), "exclude_dirs_root must still exclude \"\(needle)\"")
        }
    }

    /// The concrete gap a 2026-09 audit found: `scannable_suffixes` did not
    /// include `.txt`/`.h`/`.c`, so real, shipped, non-excluded files with
    /// those extensions (`Tests/MutantKitTests/Fixtures/*.swift.txt`,
    /// `Sources/MutantKitSchemataRuntimeC/{include/*.h,*.c}`) were entirely
    /// invisible to the leak scan. This test would have caught that
    /// directly: walk every real, non-excluded file under `Sources/`/
    /// `Tests/` and assert every extension actually present is in
    /// `scannable_suffixes`.
    @Test(
        "scannable_suffixes covers every file extension actually present under Sources/ and Tests/",
        .enabled(if: PublicTreeConfigRegressionTests.isPrivateRepoCheckout)
    )
    func scannableSuffixesCoverRealExtensions() throws {
        let config = try String(contentsOf: Self.configPath, encoding: .utf8)
        let listed = Self.stringLiterals(inTomlArrayNamed: "scannable_suffixes", in: config)
        #expect(!listed.isEmpty, "could not parse scannable_suffixes from .public-tree.toml -- did its format change?")

        // Only extensions that actually reach the public snapshot matter
        // here — a file under an already-excluded path (e.g.
        // Tests/BenchmarkRunnerTests/Fixtures/*.json) is never scanned
        // *or* published, so it isn't a gap. Reuses exclude_paths verbatim
        // rather than hand-duplicating it, so this test can't silently
        // drift from the real exclude list the same way the scan itself
        // must not.
        let excludedPathPrefixes = Self.stringLiterals(inTomlArrayNamed: "exclude_paths", in: config)

        var extensionsFound = Set<String>()
        for directory in ["Sources", "Tests"] {
            let root = Self.repositoryRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                // .build/DerivedData-shaped noise can appear under a
                // checkout depending on where tests run from; this project
                // already excludes those from the public tree at any
                // depth, and they are never real shipped source anyway.
                let path = url.path
                if path.contains("/.build/") || path.contains("/.swiftpm/") { continue }
                let relative = url.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
                if excludedPathPrefixes.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { continue }
                let ext = url.pathExtension
                extensionsFound.insert(ext.isEmpty ? "" : ".\(ext)")
            }
        }

        let uncovered = extensionsFound.subtracting(listed)
        #expect(
            uncovered.isEmpty,
            "these file extensions exist under Sources/ or Tests/ but are not in .public-tree.toml's scannable_suffixes, so the leak scan never looks inside them: \(uncovered.sorted())"
        )
    }

    /// v0.6-v0.8 audit: `forbidden_strings` was an ad hoc list a human
    /// only grew *after* a name had already leaked (one internal project's
    /// name sat live in the public repo for ~4 weeks first, see
    /// `knownLeakedNames` above) -- there was no artifact
    /// enumerating "every local `~/work/*` project name that must never
    /// appear." `Scripts/local-project-names.txt` is that artifact,
    /// seeded from `ls ~/work` with a documented, judgment-based
    /// exclusion list (names too generic to forbid literally, e.g.
    /// `orca`/`phr` colliding with ordinary identifier/English
    /// substrings already shipped in this repo's own source, plus a few
    /// self-referential/already-public names -- see that file's own
    /// header comment for the exact reasoning per exclusion).
    ///
    /// git-projector's `forbidden_strings` policy field has no mechanism
    /// to read an external file at scan time (confirmed against
    /// git_projector/config.py: it's a plain inline TOML array), so the
    /// two files are kept in sync by
    /// `Scripts/sync-local-project-name-forbidden-strings.py`, run by
    /// hand after editing the `.txt` file. This test is the mechanical
    /// gate that catches a forgotten sync: every non-excluded name in the
    /// `.txt` file must already have a case-insensitive match somewhere
    /// in `forbidden_strings`.
    @Test(
        "every non-excluded name in Scripts/local-project-names.txt is covered by forbidden_strings",
        .enabled(if: PublicTreeConfigRegressionTests.isPrivateRepoCheckout)
    )
    func localProjectNamesAreSyncedToForbiddenStrings() throws {
        let namesPath = Self.repositoryRoot.appendingPathComponent("Scripts/local-project-names.txt")
        let namesText = try String(contentsOf: namesPath, encoding: .utf8)
        let config = try String(contentsOf: Self.configPath, encoding: .utf8)

        // Mirrors the sync script's own two passes over the .txt file:
        // collect "#   - <name>: ..." exclusion bullets, then every
        // non-comment, non-blank line as a real name to check for.
        var excluded = Set<String>()
        var names: [String] = []
        for rawLine in namesText.components(separatedBy: .newlines) {
            if let bulletRange = rawLine.range(of: #"^#\s+- ([\w.\-]+):"#, options: .regularExpression) {
                let bullet = String(rawLine[bulletRange])
                if let colonIndex = bullet.lastIndex(of: ":") {
                    let dashIndex = bullet.range(of: "- ")!.upperBound
                    excluded.insert(String(bullet[dashIndex ..< colonIndex]))
                }
                continue
            }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            names.append(trimmed)
        }
        #expect(!names.isEmpty, "could not parse any names from Scripts/local-project-names.txt -- did its format change?")

        let forbiddenLower = Set(Self.stringLiterals(inTomlArrayNamed: "forbidden_strings", in: config).map {
            $0.hasPrefix("(?i)") ? String($0.dropFirst(4)).lowercased() : $0.lowercased()
        })

        for name in names where !excluded.contains(name) {
            #expect(
                forbiddenLower.contains(name.lowercased()),
                "\"\(name)\" is listed in Scripts/local-project-names.txt but has no case-insensitive match in forbidden_strings -- run Scripts/sync-local-project-name-forbidden-strings.py"
            )
        }
    }

    /// Minimal TOML-array-of-strings reader, line-based rather than a raw
    /// substring search: this file's own comments include literal `[`/`]`
    /// characters (e.g. "the `[overlay]` manifest below", inside
    /// `exclude_paths`'s own array), so the naive "find the next `]`"
    /// approach truncates early on real content. Instead: find the
    /// `name = [` line, then read subsequent lines — skipping full-line
    /// comments (`#...`) — until a line that, trimmed, is exactly `]`
    /// (this file's own closing-bracket convention, verified against every
    /// array in it), extracting every double-quoted literal from the
    /// non-comment lines in between. Good enough for this file's own
    /// hand-written style — see this suite's own doc comment for why a
    /// real TOML library isn't used here.
    private static func stringLiterals(inTomlArrayNamed name: String, in text: String) -> Set<String> {
        let lines = text.components(separatedBy: .newlines)
        guard let startIndex = lines.firstIndex(where: { $0.hasPrefix("\(name) = [") }) else { return [] }

        var literals = Set<String>()
        for line in lines[(startIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "]" { break }
            if trimmed.hasPrefix("#") { continue }
            var current = trimmed.startIndex
            while let open = trimmed[current...].firstIndex(of: "\"") {
                guard let close = trimmed[trimmed.index(after: open)...].firstIndex(of: "\"") else { break }
                literals.insert(String(trimmed[trimmed.index(after: open) ..< close]))
                current = trimmed.index(after: close)
            }
        }
        return literals
    }
}
