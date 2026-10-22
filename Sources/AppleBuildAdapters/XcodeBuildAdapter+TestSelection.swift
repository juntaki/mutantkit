import Foundation
import MutationExecution
import MutationModel

// MARK: - Coverage

extension XcodeBuildAdapter: CoverageMeasuring {
    /// Rebuilds and re-tests the baseline once more, this time with
    /// coverage instrumentation, and reads back the result. Deliberately a
    /// second build rather than reusing `runBaseline`'s own bundle: that
    /// build was never instrumented (see `build(in:enableCoverage:)`), so
    /// its bundle has no coverage to read regardless of what flag the test
    /// step is given. `nil` when the rebuild, the retest, or the read
    /// itself fails — coverage is opt-in evidence; its absence never
    /// becomes a fabricated claim.
    public func readCoverage(in workspace: URL, projectRoot: URL) async -> CoverageMap? {
        guard let artifact = try? await build(in: workspace, enableCoverage: true) else { return nil }
        guard let run = try? await runTests(
            artifact: artifact,
            in: workspace,
            label: "coverage-baseline",
            timeoutSeconds: configuration.timeouts.baselineSeconds,
            enableCoverage: true
        ), run.status == .passed, let bundle = run.resultArtifactPath else { return nil }

        return await XccovCoverageReader.read(archive: bundle, projectRoot: projectRoot)
    }
}

// MARK: - Test selection

extension XcodeBuildAdapter: TestSelecting {
    public func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        // An empty selection is never sent to `-only-testing:` — that would
        // run nothing, and a run that tested nothing must never be mistaken
        // for one that passed. Falls back to the full configured list, the
        // same as `selectedTests == nil`.
        let filters = selectedTests.flatMap { $0.isEmpty ? nil : $0.map(\.onlyTestingArgument) }
        return try await runTests(
            artifact: artifact,
            in: workspace,
            label: point.id.description,
            timeoutSeconds: timeoutSeconds,
            testFilters: filters,
            // Only meaningful when the selection is truly narrowed: each
            // identifier in `selectedTests` names exactly one test, so its
            // count is the exact number of tests this run is expected to
            // execute. `configuration.tests.targets`, `filters`' own
            // fallback whenever `selectedTests` is nil/empty, names targets
            // (whole suites) instead — its count is not a test count at
            // all, so this must stay nil in that case rather than pass a
            // number that would misfire the zero-work invariant below.
            expectedTestCount: filters?.count
        )
    }

    public func measurePerTestCoverage(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        await PerTestCoverageProfileAttempt.resolve(
            fast: { await measurePerTestCoverageFast(artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds) },
            serial: { await measurePerTestCoverageSerial(artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds) }
        )
    }

    private func measurePerTestCoverageFast(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageProfileAttempt {
        .unavailable(reason: "no fast per-test coverage backend is implemented yet")
    }

    /// Runs every test the baseline bundle reports, one at a time, against
    /// the artifact already built for the baseline — no rebuild — with
    /// coverage enabled and its own scratch result bundle, and merges what
    /// each one touched into a reverse index.
    ///
    /// A one-time cost paid once per execution, not per mutant: found worth
    /// it on a real project, where the fixed cost of re-running an entire
    /// suite dominated every mutant's wall clock regardless of how few tests
    /// actually exercised the mutated line. Runs sequentially, one simulator
    /// lease at a time via `runTests`; spreading this pass across several
    /// leased devices concurrently is a further optimisation, not attempted
    /// here.
    ///
    /// The retry, and what becomes of a test that still cannot be proven,
    /// are `PerTestCoverageAttribution.attribute`'s — see its doc comment,
    /// and `PerTestCoverageMap`'s, for the policy and why it is safe. One
    /// thing specific to this adapter: a test that legitimately covers
    /// nothing is not distinguished from one that could not be measured,
    /// because `XccovCoverageReader.read` conservatively folds a
    /// validly-parsed, genuinely-empty export into the same `nil` a
    /// malformed one produces (see its own doc comment). Such a test is
    /// therefore treated as unattributed — safe, since that only means it is
    /// always run, but not the narrowest correct behaviour; sharpening it is
    /// a performance question for later.
    /// - Parameter artifact: `runBaseline`'s own, uninstrumented artifact —
    ///   kept only to enumerate test identifiers from its already-produced
    ///   bundle; never built or tested against directly. Per-test coverage
    ///   needs a coverage-instrumented binary (see
    ///   `build(in:enableCoverage:)`), built once here and reused for
    ///   every individual test run, exactly the same "instrumented copy is
    ///   never what activation evidence is measured against" split
    ///   `readCoverage` makes.
    private func measurePerTestCoverageSerial(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        let baselineBundle = resultBundlePath(in: workspace, label: "baseline")
        let tests = await Self.enumerateTestIdentifiers(inBundle: baselineBundle)
        guard !tests.isEmpty else { return nil }

        guard let coverageArtifact = try? await build(in: workspace, enableCoverage: true) else { return nil }

        // The loop, the retry policy and what becomes of a test that cannot
        // be proven are all `PerTestCoverageAttribution.attribute`'s — see
        // its doc comment. What is adapter-specific, and all that is left
        // here, is how one test is run and how its coverage is read back.
        return await PerTestCoverageAttribution.attribute(
            tests: tests, source: "xcodebuild-xccov-per-test",
            progress: ProgressReporter(total: tests.count, label: "per-test coverage")
        ) { test, attempt in
            guard let run = try? await runTests(
                artifact: coverageArtifact,
                in: workspace,
                // Distinct per attempt: a retry that reused the first
                // attempt's bundle path would be read against whatever the
                // failed attempt left behind, which is precisely the
                // half-written state being retried past.
                label: attempt == 1
                    ? "pertest-\(test.onlyTestingArgument)"
                    : "pertest-retry\(attempt)-\(test.onlyTestingArgument)",
                timeoutSeconds: timeoutSeconds,
                testFilters: [test.onlyTestingArgument],
                enableCoverage: true
            ) else { return nil }
            guard run.status == .passed, let bundle = run.resultArtifactPath else { return nil }
            return await XccovCoverageReader.read(archive: bundle, projectRoot: workspace)
        }
    }

    /// Walks `xcresulttool get test-results tests` for one bundle, pulling
    /// out every `Test Case` leaf and the `Unit test bundle` ancestor that
    /// names its target — the two things `-only-testing:` needs. A `Test
    /// Case` node's own `nodeIdentifier` is already shaped `Class/method()`
    /// (confirmed against a real bundle), so no separate class-name
    /// tracking is needed; only the trailing `()` is stripped.
    static func enumerateTestIdentifiers(inBundle bundle: URL) async -> [TestIdentifier] {
        guard FileManager.default.fileExists(atPath: bundle.path) else { return [] }

        let result = try? await ProcessSupervisor.run(
            executable: ToolPaths.xcrun,
            arguments: ["xcresulttool", "get", "test-results", "tests", "--path", bundle.path, "--compact"],
            workingDirectory: bundle.deletingLastPathComponent(),
            timeoutSeconds: 120
        )
        guard let result, result.succeeded else { return [] }
        return parseTestIdentifiers(result.standardOutput)
    }

    /// Parses `xcresulttool get test-results tests --compact` output. Exposed
    /// for tests so a captured document can drive the walk without a
    /// toolchain or a real bundle.
    ///
    /// `qualifiedName`'s own doc comment describes `"<Class>/<method>"` —
    /// true for XCTest, whose `nodeIdentifier` is exactly that shape
    /// (`"AddTests/testAdd()"`, confirmed by `XcodeTestIdentifierEnumerationTests`'
    /// own captured fixture). A Swift Testing `nodeIdentifier` is shaped
    /// differently — confirmed by direct reproduction against a real
    /// Xcode/iOS-Simulator Swift Testing target: it is
    /// `"<Target>/<method>()"` (the *target* name, never the enclosing
    /// `@Suite`'s own name, which never appears in the identifier at all)
    /// — so `qualifiedName` for a Swift Testing test ends up
    /// `"<Target>/<method>"`, not `"<Class>/<method>"`. This looks
    /// unusual next to the XCTest case, but it is exactly what makes
    /// `onlyTestingArgument` (`target + "/" + qualifiedName + "()"`)
    /// produce the one filter shape `xcodebuild -only-testing:` actually
    /// matches for a Swift Testing function — empirically, that shape is
    /// `<Target>/<Target>/<method>()` (the target name doubled), not
    /// `<Target>/<SuiteName>/<method>()` as the XCTest-shaped convention
    /// would suggest. See `TestIdentifier.onlyTestingArgument`'s own doc
    /// comment for the full account, including why this was previously
    /// silently broken (missing `()`, not this target-doubling shape).
    static func parseTestIdentifiers(_ data: Data) -> [TestIdentifier] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let testNodes = root["testNodes"] as? [[String: Any]]
        else { return [] }

        var found: [TestIdentifier] = []
        func walk(_ node: [String: Any], target: String?) {
            let nodeType = node["nodeType"] as? String
            // `xcresulttool` names a UI test target's own bundle node "UI
            // test bundle", never "Unit test bundle" — confirmed against a
            // real UI-test-only bundle (Phase 5A,
            // `Fixtures/AccessibilityUISubstrate`). Recognizing only "Unit
            // test bundle" here silently dropped every UI test's identifier
            // from enumeration (`currentTarget` stayed `nil`, so the `Test
            // Case` guard below never matched): a UI test target added to
            // `tests.targets` would enumerate as if it had zero tests,
            // starving `selectCoveringTests`'s per-test coverage
            // measurement and any schemata identifier resolution of a UI
            // test's own identifiers, even though the test genuinely ran.
            let currentTarget = isTestBundleNode(nodeType) ? (node["name"] as? String) : target

            if nodeType == "Test Case", let currentTarget,
               let identifier = node["nodeIdentifier"] as? String {
                let qualifiedName = identifier.hasSuffix("()") ? String(identifier.dropLast(2)) : identifier
                found.append(TestIdentifier(target: currentTarget, qualifiedName: qualifiedName))
            }

            for child in (node["children"] as? [[String: Any]]) ?? [] {
                walk(child, target: currentTarget)
            }
        }
        for node in testNodes { walk(node, target: nil) }
        return found
    }

    /// Whether an `xcresulttool` `nodeType` names a test-bundle-level node —
    /// the node whose own `name` is the actual test target's name. Shared
    /// with `XCResultAdapter.ownFailures`, which threads a target name down
    /// for display the identical way. Two node type strings, empirically
    /// confirmed against real result bundles: `"Unit test bundle"` for an
    /// XCTest/Swift Testing unit target, `"UI test bundle"` for an XCUITest
    /// target (see `Fixtures/AccessibilityUISubstrate`, Phase 5A).
    static func isTestBundleNode(_ nodeType: String?) -> Bool {
        nodeType == "Unit test bundle" || nodeType == "UI test bundle"
    }
}
