import Foundation
import MutationModel

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
/// `Codable` so a baseline pass's attribution can be persisted across runs
/// by `CoverageProfileCache`: re-running the same source/test/toolchain
/// combination reuses the measured map instead of paying the profiling cost
/// again. The on-disk form is the obvious nested dictionary — a structural
/// change to `coveringTests` invalidates existing caches by failing to
/// decode, which is the safe direction.
public struct PerTestCoverageMap: Sendable, Hashable, Codable {
    /// Repository-relative file → 1-based line → the tests whose baseline
    /// run executed it.
    public let coveringTests: [String: [Int: Set<TestIdentifier>]]
    /// Where the claim came from, so a wrong one can be traced back to its source.
    public let source: String

    public init(coveringTests: [String: [Int: Set<TestIdentifier>]], source: String) {
        self.coveringTests = coveringTests
        self.source = source
    }

    public var isEmpty: Bool { coveringTests.isEmpty }

    /// The tests known to cover this site, or `nil` when the map has
    /// nothing to say about it. Never an empty set: a line no profiled test
    /// touched is, by construction, a line the union in `aggregate()` also
    /// never reached, which the existing `.noCoverage` fast path already
    /// classifies before a mutant reaches test selection — this map is only
    /// ever consulted for a line already known to be covered by *something*.
    public func testsCovering(file: String, line: Int) -> Set<TestIdentifier>? {
        coveringTests[file]?[line]
    }

    /// The union of every line any test covered — the same fact a
    /// whole-suite `CoverageMap` measures directly, derived here for free
    /// instead of reading a separate whole-run report a second time.
    public func aggregate() -> CoverageMap {
        var executedLines: [String: Set<Int>] = [:]
        for (file, lines) in coveringTests {
            executedLines[file] = Set(lines.keys)
        }
        return CoverageMap(executedLines: executedLines, source: source)
    }
}
