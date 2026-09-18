/// One test XCTest can be told to run alone: `-only-testing:<target>/<Class>/<method>`.
public struct TestIdentifier: Sendable, Hashable, Codable {
    /// The test target (bundle) this test belongs to, e.g. `"AppTests"`.
    public let target: String
    /// `"<Class>/<method>"`, e.g. `"AddTests/testAdd"` — no trailing `()`.
    public let qualifiedName: String

    public init(target: String, qualifiedName: String) {
        self.target = target
        self.qualifiedName = qualifiedName
    }

    /// The exact string `-only-testing:` accepts.
    ///
    /// The trailing `()` is required: confirmed by direct reproduction
    /// against a real Xcode/iOS-Simulator Swift Testing target —
    /// omitting it (this property's prior form) makes `xcodebuild` match
    /// **zero** tests for a Swift Testing `@Test` function, silently,
    /// with no error. XCTest tolerates the `()` either way (confirmed
    /// the same way, against a real XCTest target:
    /// `-only-testing:Target/Class/method()` and
    /// `-only-testing:Target/Class/method` both correctly select exactly
    /// one test), so appending it unconditionally is safe for both
    /// frameworks rather than needing to detect which one a given
    /// `TestIdentifier` came from.
    ///
    /// This was the root cause of a real, previously-unexplained gap:
    /// `selectCoveringTests: true` failed to narrow per-test coverage
    /// attribution for Xcode + Swift Testing schemes specifically —
    /// every one of `XcodeBuildAdapter.measurePerTestCoverage`'s
    /// per-test `-only-testing:`-filtered runs was silently selecting
    /// zero tests, so every single-test coverage measurement pass
    /// produced no coverage at all, and the whole per-test map came
    /// back empty, falling back to the safe-but-coarse "run every test"
    /// behavior. `qualifiedName` itself is left exactly as documented
    /// above (no trailing `()`) — `BatchXCTestRunBuilder`'s own
    /// `OnlyTestIdentifiers` construction reads `.qualifiedName`
    /// directly, not this property, and was not verified as part of
    /// this fix; see that type's own
    /// `resolvingTestRootPlaceholders`/`narrowed` construction if the
    /// identical Swift-Testing-matching question is ever raised for the
    /// batched-test-execution path specifically.
    public var onlyTestingArgument: String { "\(target)/\(qualifiedName)()" }
}

/// Which individual tests exercised which lines, at baseline.
///
/// Built once, by running every test in isolation with coverage enabled
/// against the artifact already built for the baseline — see
/// `TestSelecting.measurePerTestCoverage`. A mutant then only needs the
/// handful of tests whose baseline run actually touched its line, instead of
/// the whole configured test list, which is the dominant per-mutant cost on
/// a real project: rebuilding is comparatively cheap, but re-running an
/// entire suite that mostly has nothing to do with the one line that
/// changed is not.
///
/// The map only ever narrows a mutant's test invocation, never widens or
/// substitutes it: `testsCovering` returns `nil` for anything it was not
/// able to attribute (a file it never profiled, a line profiling did not
/// reach), and every caller must treat `nil` as "run everything" — the exact
/// behaviour a coverage-blind run already has.
///
/// ## Partial attribution
///
/// A profiling pass over a real suite is a few hundred separate test runs,
/// and an individual one can fail to be *provable* — order-dependent and
/// failing alone, crashed, timed out, or its coverage export unreadable.
/// This type models that directly: such a test lands in `unattributedTests`
/// instead of invalidating every other test's successfully measured
/// attribution.
///
/// Carrying the unprovable tests is what makes a partial map safe to use at
/// all, and it is the *only* thing that does. An unattributed test's
/// coverage is unknown, so it could cover any line — which means every
/// selection has to include it. `testsCovering` therefore returns
/// `attributed(line) ∪ unattributedTests`, never the attributed set alone.
/// That selection is provably no narrower than the truth: every *attributed*
/// test's coverage was read in full, so a line none of them recorded is a
/// line none of them execute, and the only tests that could still reach it
/// are exactly the ones in `unattributedTests`.
///
/// The predecessor of this type had no such set and instead discarded the
/// entire map the moment one test could not be proven (P12-B Finding D's own
/// remedy, in each adapter's `measurePerTestCoverageSerial`). That was sound
/// — and was itself the fix for the genuinely unsafe shape, which P12-B B1
/// confirmed live: a version that simply dropped the unprovable test's entry
/// and kept the rest, yielding a map that looks complete while silently
/// missing that test's real coverage, which turns a mutant only that test
/// would have killed into a false survivor. That shape must never come back,
/// and carrying the test rather than dropping it is what keeps it away.
///
/// What the all-or-nothing remedy cost, though, was the whole pass: measured
/// on a 647-test iOS project, two consecutive runs each paid ~100 minutes of
/// profiling, each returned `nil` over one flaky simulator run, each narrowed
/// nothing (every mutant ran all 647 tests) and each cached nothing — so the
/// next run paid it again. `unattributedTests` keeps Finding D's soundness
/// without its bet.
///
/// `Codable` so a baseline pass's attribution can be persisted across runs
/// by `CoverageProfileCache`: re-running the same source/test/toolchain
/// combination reuses the measured map instead of paying the profiling cost
/// again. The on-disk form is the obvious nested dictionary — a structural
/// change to `coveringTests` invalidates existing caches by failing to
/// decode, which is the safe direction. `unattributedTests` is decoded
/// permissively for the opposite reason, and it is safe in exactly this one
/// direction: an entry written before this field existed came from the
/// all-or-nothing era, where a stored map was by construction complete, so
/// the empty default it decodes to is that entry's own true value.
public struct PerTestCoverageMap: Sendable, Hashable, Codable {
    /// Repository-relative file → 1-based line → the tests whose baseline
    /// run executed it.
    public let coveringTests: [String: [Int: Set<TestIdentifier>]]
    /// Tests whose isolated baseline run could not be proven, so nothing is
    /// known about what they cover. Empty for a complete pass.
    public let unattributedTests: Set<TestIdentifier>
    /// Where the claim came from, so a wrong one can be traced back to its source.
    public let source: String

    public init(
        coveringTests: [String: [Int: Set<TestIdentifier>]],
        source: String,
        unattributedTests: Set<TestIdentifier> = []
    ) {
        self.coveringTests = coveringTests
        self.unattributedTests = unattributedTests
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coveringTests = try container.decode([String: [Int: Set<TestIdentifier>]].self, forKey: .coveringTests)
        source = try container.decode(String.self, forKey: .source)
        unattributedTests = try container.decodeIfPresent(Set<TestIdentifier>.self, forKey: .unattributedTests) ?? []
    }

    public var isEmpty: Bool { coveringTests.isEmpty }

    /// Whether every test in the suite was successfully attributed. Only a
    /// complete map can answer "which lines did the suite never reach at
    /// all" — see `aggregate()`.
    public var isComplete: Bool { unattributedTests.isEmpty }

    /// The tests that must run for this site, or `nil` when the map has
    /// nothing to say about it.
    ///
    /// The union with `unattributedTests` is the whole safety argument for a
    /// partial map — see the type's own doc comment. Never an empty set for
    /// a complete map: a line no profiled test touched is, by construction,
    /// a line the union in `aggregate()` also never reached, which the
    /// `.noCoverage` fast path already classifies before a mutant reaches
    /// test selection.
    public func testsCovering(file: String, line: Int) -> Set<TestIdentifier>? {
        let attributed = coveringTests[file]?[line]
        guard !unattributedTests.isEmpty else { return attributed }
        return (attributed ?? []).union(unattributedTests)
    }

    /// The union of every line any test covered — the same fact a
    /// whole-suite `CoverageMap` measures directly, derived here for free
    /// instead of reading a separate whole-run report a second time.
    ///
    /// `nil` for a partial map, and this is the load-bearing half of what
    /// makes a partial map safe. A `CoverageMap` is consumed by
    /// `isKnownUncovered`, whose whole job is to assert a *negative* — "the
    /// suite never reached this line" — and turn it into a `.noCoverage`
    /// verdict with no build and no test run at all. That negative is
    /// exactly what an unattributed test's unknown coverage can falsify: a
    /// line only that one test reaches would look unreached here, and the
    /// mutant on it would be scored `.noCoverage` — laundering missing data
    /// into a claim about the suite, which is the one thing this tool must
    /// never do. Callers already treat a `nil` coverage map as
    /// coverage-blind (every mutant built and tested, or the separately
    /// measured whole-suite `readCoverage` used instead), so the fallback
    /// costs time and never correctness.
    public func aggregate() -> CoverageMap? {
        guard isComplete else { return nil }
        var executedLines: [String: Set<Int>] = [:]
        for (file, lines) in coveringTests {
            executedLines[file] = Set(lines.keys)
        }
        return CoverageMap(executedLines: executedLines, source: source)
    }
}
