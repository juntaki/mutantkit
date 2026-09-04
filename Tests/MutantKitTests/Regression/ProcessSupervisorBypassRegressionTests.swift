import Foundation
import Testing

/// Turns a one-time manual audit into a permanent, mechanical gate.
///
/// `HostResourcePreflight.bootedSimulatorCount()` used to hand-roll its own
/// `Foundation.Process`/`Pipe`/`withTaskGroup` timeout race instead of this
/// project's own `ProcessSupervisor` (`Sources/MutationExecution/
/// ProcessSupervisor.swift`) — and hung indefinitely under real concurrent
/// process load in a full acceptance run, because `Process.waitUntilExit()`
/// depends on Foundation's own process-wide, SIGCHLD-driven completion
/// tracking, which lost the notification for that one child. See that
/// file's own fix commit and `ProcessSupervisor`'s own doc comment ("Two
/// properties matter here, and neither is available from
/// `Foundation.Process`") for exactly what a raw `Process()` use does NOT
/// get for free: an absolute timeout bound, `SIGTERM` → grace →
/// `SIGKILL` escalation onto the whole process group, descendant-tree
/// reaping regardless of process-group escape, and a proof (`outputComplete`)
/// that captured output is not silently truncated.
///
/// A manual audit is a photograph, not a gate — it is accurate for exactly
/// as long as nobody adds a new call site. This suite re-runs that audit
/// against the real `Sources/` tree every time the test suite runs, so a
/// future change that reintroduces the same bug class — a bare `Process`/
/// `NSTask` construction (including `Process.init(...)`, a contextual
/// `.init()` on an explicitly `Process`-typed binding, or the
/// `Process.launchedProcess(...)` create-and-launch factory), a
/// `typealias` that renames `Process` to something else, or a direct
/// `posix_spawn`-family (`posix_spawn`, `posix_spawnp`, …), `fork`/
/// `vfork`, `exec`-family, `system`, or `popen` call — anywhere outside
/// the documented allow-list below fails immediately, with the exact file
/// and line, instead of waiting to hang some future CI run the way the
/// original bug did.
///
/// This is a per-line textual/regex scan, not a compiler: it does not
/// resolve a contextual `.init()` split across multiple lines, does not
/// follow indirection through whatever alias a flagged `typealias`
/// introduces, and cannot see fully dynamic constructs (e.g. Objective-C
/// runtime lookups). It is a fast, permanent net for the real-world
/// spellings a contributor is actually likely to write — including
/// several an earlier version of this same suite still missed, see
/// `scanCatchesRealWorldBypassSpelling` below — not a formal proof of
/// absence.
@Suite("Regression: no raw Process/posix_spawn bypasses of ProcessSupervisor")
struct ProcessSupervisorBypassRegressionTests {
    // MARK: - Allow-list

    /// Whole `Sources/` targets this scan does not enter at all.
    ///
    /// The first six are research/probe-only executables named in
    /// `Package.swift` — standalone tools for a specific investigation or
    /// evaluation protocol, never part of the mutation-execution path a
    /// real `mutantkit run` takes, so they carry none of the trust
    /// obligations `ProcessSupervisor` exists to uphold.
    ///
    /// `BenchmarkRunner` was added to this list while *writing* this test,
    /// not before: running this exact scan against the real tree found
    /// five real `Process()` constructions in that target
    /// (`BenchmarkPreflight.swift`, `MeasurementCollector.swift`,
    /// `ProjectMaterializer.swift`, `ToolchainDiscovery.swift` ×2) that an
    /// earlier same-day manual audit had missed — direct, mechanical proof
    /// of why this suite needs to exist at all. `BenchmarkRunner` is
    /// MutantBench-Swift, `Package.swift`'s own comment on the target:
    /// "Deliberately depends on nothing else in this package —
    /// `MutationModel`/`MutationExecution` included. Both MutantKit and
    /// Muter are external processes to this target, never in-process
    /// engines." It never participates in producing a mutation verdict —
    /// it shells out to the already-built `mutantkit` binary and to Muter
    /// as black boxes to compare their wall time — so it sits in the same
    /// "not the trust surface" category as the six probes above, even
    /// though nothing in `Package.swift` labels it that way today. Its own
    /// timed tool invocations already go through a hardened,
    /// `ProcessSupervisor`-equivalent `posix_spawn` implementation
    /// (`ToolRunner.swift`, allow-listed by file below); the five
    /// `Process()` sites this exclusion actually covers are short-lived
    /// toolchain/version/preflight queries, not part of any mutation run.
    /// Hardening or removing them is real, separate work for whoever owns
    /// `BenchmarkRunner` next — out of scope for this suite, whose job is
    /// only to keep the allow-list honest and visible, never to silently
    /// grow it.
    private static let excludedTargets: Set<String> = [
        "BudgetV2Eval",
        "PlanSubsetDerivation",
        "SchemataEligibilityClassifier",
        "PlanStats",
        "SchemataChunkBuildProbe",
        "DirectXCTestInvokeProbe",
        "BenchmarkRunner"
    ]

    /// Individual files excluded even though their target is otherwise in
    /// scope — paths relative to `Sources/`.
    private static let excludedFiles: Set<String> = [
        // The raw `posix_spawn` implementation everything else in this
        // allow-list is supposed to route through instead of reimplementing.
        "MutationExecution/ProcessSupervisor.swift",
        // `BenchmarkRunner`'s own decoupled, hardened `posix_spawn`
        // reimplementation for its timed tool invocations — see the
        // `excludedTargets` doc comment above. Listed explicitly (not
        // just covered by the whole-target exclusion) so this file keeps
        // showing up if `BenchmarkRunner` is ever narrowed to a per-file
        // allow-list instead of a whole-target one.
        "BenchmarkRunner/ToolRunner.swift"
    ]

    // MARK: - Forbidden patterns

    private struct ForbiddenPattern {
        let description: String
        let regex: NSRegularExpression

        init(_ description: String, _ pattern: String) {
            self.description = description
            // swiftlint:disable:next force_try
            regex = try! NSRegularExpression(pattern: pattern)
        }
    }

    /// Every pattern this scan treats as "the same bug class as the
    /// `HostResourcePreflight` hang": a way to spawn and wait on a child
    /// process that bypasses `ProcessSupervisor`'s deterministic
    /// timeout/escalation/reaping/output-completeness guarantees.
    ///
    /// Widened after an adversarial review reproduced several real-world
    /// spellings the original, narrower list missed: `Process.init(...)`
    /// and a contextual `.init()` on a `Process`-typed binding (neither
    /// contains the literal text `Process(` the first pattern below
    /// requires); `Process.launchedProcess(...)`, Foundation's own
    /// create-and-launch factory — one call, an unmanaged child, exactly
    /// this gate's bug class; `posix_spawnp(...)`, which the previous
    /// exact-literal `posix_spawn(` pattern did not match (the allow-listed
    /// reference implementation this project actually uses is itself built
    /// on a `posix_spawn` call, which makes `posix_spawnp` a plausible
    /// thing for a contributor to copy toward); a `typealias` that renames
    /// `Process` to something else, defeating every `Process`-name-based
    /// pattern below for whatever code uses the alias afterward; and the
    /// entirely-missing `system(...)`/`popen(...)`.
    private static let forbiddenPatterns: [ForbiddenPattern] = [
        ForbiddenPattern("bare `Process(` construction — route through ProcessSupervisor.run(...) instead", #"\bProcess\("#),
        ForbiddenPattern(
            "`Process.init(` construction — route through ProcessSupervisor.run(...) instead",
            #"\bProcess\.init\s*\("#
        ),
        ForbiddenPattern(
            "contextual `.init()` on an explicitly `Process`-typed binding — route through ProcessSupervisor.run(...) instead",
            #":\s*\bProcess\b\s*=\s*\.init\s*\("#
        ),
        ForbiddenPattern(
            "`Process.launchedProcess(` create-and-launch factory — route through ProcessSupervisor.run(...) instead",
            #"\bProcess\.launchedProcess\s*\("#
        ),
        ForbiddenPattern("`NSTask(` construction — route through ProcessSupervisor.run(...) instead", #"\bNSTask\("#),
        ForbiddenPattern(
            "a `typealias` renaming `Process` — defeats this scan's other Process-name patterns for any code that "
                + "uses the alias; construct/route the real Process type instead",
            #"\btypealias\s+\w+\s*=\s*Process\b"#
        ),
        ForbiddenPattern(
            "direct `posix_spawn`-family call outside ProcessSupervisor (posix_spawn, posix_spawnp, …)",
            #"\bposix_spawn\w*\s*\("#
        ),
        ForbiddenPattern("direct `fork()`/`vfork()` call", #"\b(fork|vfork)\s*\(\s*\)"#),
        ForbiddenPattern(
            "direct exec-family call (execv/execve/execvp/execl/execlp/execle)",
            #"\bexec(v|ve|vp|l|lp|le)\s*\("#
        ),
        ForbiddenPattern("direct `system(` call", #"\bsystem\s*\("#),
        ForbiddenPattern("direct `popen(` call", #"\bpopen\s*\("#)
    ]

    // MARK: - Scan

    private struct Violation: CustomStringConvertible {
        let relativePath: String
        let line: Int
        let matchedText: String
        let patternDescription: String

        var description: String {
            "Sources/\(relativePath):\(line): \(patternDescription) — found `\(matchedText)`"
        }
    }

    /// Derived from this file's own location, exactly like
    /// `AcceptanceSupport.packageRoot`/`SchemataEligibilityClassifierTests`
    /// already do, so this does not depend on the working directory
    /// `swift test` happens to be invoked from.
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/MutantKitTests/Regression/ProcessSupervisorBypassRegressionTests.swift
            .deletingLastPathComponent() // Regression
            .deletingLastPathComponent() // MutantKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources")
    }

    /// Whether this checkout is the private repo -- the only tree where
    /// every `excludedTargets`/`excludedFiles` entry above is guaranteed to
    /// exist. A public-projection snapshot (see the private repo's own
    /// `.public-tree.toml`) is a deliberately filtered subset: several
    /// allow-listed research-only targets (and, as of the entry documented
    /// above, `BenchmarkRunner`) are excluded from it BY DESIGN, not by
    /// staleness. Detected by the presence of `.public-tree.toml` itself at
    /// the package root -- the private repo always has it, a public
    /// projection never does (it's the one file that would have to
    /// describe its own exclusion to get excluded, so git-projector never
    /// copies it) -- rather than hand-duplicating `.public-tree.toml`'s own
    /// exclude list here, which would silently drift out of sync with it.
    private static var isPrivateRepoCheckout: Bool {
        FileManager.default.fileExists(
            atPath: sourcesRoot.deletingLastPathComponent().appendingPathComponent(".public-tree.toml").path
        )
    }

    /// Every `.swift` file under an in-scope target — walks the real
    /// directory tree at test time, never a fixed snapshot of file names,
    /// so a brand-new file is covered automatically the moment it exists.
    private static func productionSwiftFiles() throws -> [(url: URL, relativePath: String)] {
        let fileManager = FileManager.default
        let root = sourcesRoot
        let targetDirs = try fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )

        var files: [(url: URL, relativePath: String)] = []
        for targetDir in targetDirs.sorted(by: { $0.path < $1.path }) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: targetDir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard !excludedTargets.contains(targetDir.lastPathComponent) else { continue }

            guard let enumerator = fileManager.enumerator(
                at: targetDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
                guard !excludedFiles.contains(relativePath) else { continue }
                files.append((fileURL, relativePath))
            }
        }
        return files
    }

    /// A match is ignored when it falls after the first `//` that actually
    /// starts a line comment — covers both ordinary and `///` doc comments.
    /// Tracks whether each character is inside a `"..."` string literal
    /// (with `\"` escape handling) so a `//` embedded in a string — a
    /// URL like `"https://example.com"` on the same line as a real
    /// `Process()` call, which an adversarial review found this used to
    /// suppress entirely — is never mistaken for a comment start. Still
    /// intentionally non-exhaustive (no block-comment handling, and a
    /// multi-line string literal is not tracked across lines); if a
    /// genuine false positive ever shows up, the fix is to reword the
    /// comment/string or add the file to `excludedFiles`, not to weaken
    /// this check.
    private static func isWithinLineComment(line: String, matchRange: Range<String.Index>) -> Bool {
        guard let commentStart = firstLineCommentStart(in: line) else { return false }
        return commentStart < matchRange.lowerBound
    }

    /// The index of the first `//` in `line` that is not inside a
    /// `"..."` string literal, or `nil` if the line has none.
    private static func firstLineCommentStart(in line: String) -> String.Index? {
        var isInsideStringLiteral = false
        var previousCharacterWasBackslash = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if isInsideStringLiteral {
                if previousCharacterWasBackslash {
                    previousCharacterWasBackslash = false
                } else if character == "\\" {
                    previousCharacterWasBackslash = true
                } else if character == "\"" {
                    isInsideStringLiteral = false
                }
            } else if character == "\"" {
                isInsideStringLiteral = true
            } else if character == "/" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "/" {
                    return index
                }
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func violations(inFileAt url: URL, relativePath: String) throws -> [Violation] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var found: [Violation] = []
        for (index, line) in content.components(separatedBy: .newlines).enumerated() {
            let nsRange = NSRange(line.startIndex ..< line.endIndex, in: line)
            for pattern in forbiddenPatterns {
                guard let match = pattern.regex.firstMatch(in: line, range: nsRange),
                      let range = Range(match.range, in: line) else { continue }
                guard !isWithinLineComment(line: line, matchRange: range) else { continue }
                found.append(Violation(
                    relativePath: relativePath, line: index + 1, matchedText: String(line[range]), patternDescription: pattern.description
                ))
            }
        }
        return found
    }

    private static func scan() throws -> [Violation] {
        var all: [Violation] = []
        for file in try productionSwiftFiles() {
            all.append(contentsOf: try violations(inFileAt: file.url, relativePath: file.relativePath))
        }
        return all
    }

    // MARK: - Tests

    @Test("Production Sources/ has no raw Process/NSTask/posix_spawn/fork/exec outside the documented allow-list")
    func noBypassesOutsideAllowList() throws {
        let violations = try Self.scan()
        let message = Self.failureMessage(for: violations)
        #expect(violations.isEmpty, "\(message)")
    }

    /// Split out from the `#expect` call above purely because the Swift
    /// type checker times out on a long chain of `+`-concatenated string
    /// literals inside a single `#expect(...)` macro expansion — a known,
    /// unrelated compiler limitation, nothing about this string itself.
    private static func failureMessage(for violations: [Violation]) -> String {
        var lines = [
            "Found \(violations.count) raw process-spawn bypass(es) of ProcessSupervisor outside the documented allow-list.",
            "Route through ProcessSupervisor.run(...) instead, or — only if this really is research/probe-only tooling",
            "outside the mutation-execution trust path — extend the allow-list in this file with a justification, the",
            "same way BenchmarkRunner's own entry explains itself:"
        ]
        lines.append(contentsOf: violations.map(\.description))
        return lines.joined(separator: "\n")
    }

    /// Guards the allow-list itself: a target that gets renamed or removed
    /// (and a stale entry left behind) would silently narrow this scan's
    /// real coverage without any test ever going red for it.
    ///
    /// Private-repo checkout only (see `isPrivateRepoCheckout`) -- against
    /// a public-projection snapshot, several entries are legitimately
    /// absent by design, which this specific staleness guard cannot
    /// distinguish from a genuine stale entry; `noBypassesOutsideAllowList`
    /// above still runs the real scan there unconditionally.
    @Test(
        "Every allow-listed target and file still exists under Sources/",
        .enabled(if: ProcessSupervisorBypassRegressionTests.isPrivateRepoCheckout)
    )
    func allowListEntriesAreReal() {
        let fileManager = FileManager.default
        for target in Self.excludedTargets {
            var isDirectory: ObjCBool = false
            let path = Self.sourcesRoot.appendingPathComponent(target).path
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            #expect(
                exists && isDirectory.boolValue,
                "Allow-listed target '\(target)' no longer exists under Sources/ — remove its stale entry from excludedTargets"
            )
        }
        for file in Self.excludedFiles {
            let path = Self.sourcesRoot.appendingPathComponent(file).path
            #expect(
                fileManager.fileExists(atPath: path),
                "Allow-listed file '\(file)' no longer exists — remove its stale entry from excludedFiles"
            )
        }
    }

    // MARK: - Self-test: the scan actually catches what it claims to

    /// Pins this suite's own coverage instead of only asserting it in a doc
    /// comment. Each fixture line below is a real-world spelling an
    /// adversarial review reproduced as missed by an earlier version of
    /// `forbiddenPatterns`/`isWithinLineComment` — this test feeds each one
    /// through the actual `violations(inFileAt:relativePath:)` scan
    /// function used by `scan()` (not a reimplementation of its logic)
    /// against a throwaway fixture file outside `Sources/`, so a future
    /// change that narrows a pattern or reintroduces the line-comment bug
    /// fails here before it can silently reopen the gap it closed.
    @Test("Forbidden-pattern scan catches every real-world bypass spelling this gate exists to catch", arguments: [
        (name: "Process.init() explicit construction", line: "let task = Process.init()"),
        (name: "contextual .init() on an explicitly Process-typed binding", line: "let task: Process = .init()"),
        (
            name: "Process.launchedProcess(...) create-and-launch factory",
            line: #"let task = Process.launchedProcess(launchPath: "/bin/ls", arguments: [])"#
        ),
        (name: "posix_spawnp(...) — the 'p' variant, not just posix_spawn(", line: "posix_spawnp(&pid, path, nil, nil, argv, envp)"),
        (name: "typealias renaming Process to something else", line: "typealias RenamedProcess = Process"),
        (name: "system(...) call", line: #"system("/bin/ls")"#),
        (name: "popen(...) call", line: #"popen("/bin/ls", "r")"#),
        (
            name: #"genuine Process() sharing a line with a "https://" URL"#,
            line: #"let task = Process() // see https://example.com for context"#
        )
    ])
    func scanCatchesRealWorldBypassSpelling(name: String, line: String) throws {
        let violations = try Self.violations(inFixtureLine: line)
        #expect(!violations.isEmpty, "Expected the scan to catch \(name) in line `\(line)`, but it found nothing.")
    }

    /// The flip side of the fix above: a `//` that genuinely starts a
    /// comment (nothing before it on the line is inside a string literal)
    /// must still suppress a match on that same line, exactly as before —
    /// pins that the string-literal tracking added to fix the URL false
    /// negative did not also reopen a false positive on ordinary comments.
    @Test("Forbidden-pattern scan still ignores a real match inside a genuine line comment")
    func scanIgnoresGenuineLineComment() throws {
        let violations = try Self.violations(inFixtureLine: "// let task = Process() -- just an example in a comment")
        #expect(violations.isEmpty, "Expected a commented-out example not to be flagged, found: \(violations)")
    }

    /// Writes `line` as the sole content of a throwaway `.swift` file under
    /// a fresh temporary directory and runs the real per-file scan
    /// function against it — the same function `scan()` runs against every
    /// file under `Sources/`. The fixture lives entirely outside
    /// `Sources/`, so this never touches, depends on, or needs cleanup of
    /// the production tree.
    private static func violations(inFixtureLine line: String) throws -> [Violation] {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ProcessSupervisorBypassRegressionTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let fixtureURL = directory.appendingPathComponent("Fixture.swift")
        try line.write(to: fixtureURL, atomically: true, encoding: .utf8)
        return try violations(inFileAt: fixtureURL, relativePath: "Fixture.swift")
    }
}
