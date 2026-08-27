import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Threads `Configuration.execution.selectCoveringTests` into schemata mode
/// (the sibling of `MutationRunnerTestSelectionTests` for isolated mode):
/// does `SchemataMutationRunner` narrow a mutant's `runSchemataToken` call to
/// the tests `TestSelecting.measurePerTestCoverage` attributed to its line,
/// and does it always fall back to the full configured list — never to an
/// empty selection — whenever that attribution has nothing to say. A
/// confirmation rerun must reproduce the exact same narrowed scope as the
/// primary run it is confirming, not a different one.
///
/// Uses `FakeSchemataAdapter` (shared with the Group 2 dynamic-fallback and
/// ADR-0008 containment suites) with its `TestSelecting` conformance, so
/// `SchemataMutationRunner`'s own `test as? any TestSelecting` cast succeeds
/// exactly the way a real `SwiftPackageMacOSAdapter`/`XcodeBuildAdapter`
/// would. No process is spawned anywhere in this suite.
@Suite("SchemataMutationRunner: coverage-based test selection")
struct SchemataMutationRunnerTestSelectionTests {
    private static let source = "func flag() -> Bool { true }\n"
    private static let relativePath = "Widget.swift"
    private static let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))
    private static let projectIdentity = "App.xcodeproj"
    private static let lowererID = "bool-literal"
    private static let lowererVersion = 1
    private static let target = "App"
    private static let token = SchemataSelectorToken(namespace: 1, localIndex: 1)
    private static let addTest = TestIdentifier(target: "AppTests", qualifiedName: "WidgetTests/testFlag")

    private func point() throws -> MutationPoint {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        return try #require(points.first, "expected a bool-literal candidate")
    }

    private func compilationUnitID(point: MutationPoint) -> CompilationUnitID {
        CompilationUnitID.derive(
            projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
            sourcePath: point.file, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
        )
    }

    private func entry(mutationID: MutationID) -> SchemataPlanEntry {
        SchemataPlanEntry(
            mutationID: mutationID,
            placement: .embedded(placements: [
                SchemataEmbeddedPlacement(
                    chunkID: "chunk-A", selectorToken: Self.token,
                    sourceEmbeddingID: Self.sourceEmbeddingID.rawValue, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion,
                    projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target, product: "\(Self.target).app",
                    expectedImages: []
                )
            ]),
            conflictGroup: nil, projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
            product: "\(Self.target).app"
        )
    }

    private func program(entry: SchemataPlanEntry) -> SchemataProgram {
        SchemataProgram(
            chunkID: "chunk-A", sourceEmbeddingID: Self.sourceEmbeddingID.rawValue,
            loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.source)],
            entries: [entry]
        )
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs one embedded mutation through the runner, with `perTestCoverage`
    /// (`.some(nil)` for "profiled but this line was never attributed",
    /// `nil` for "no attribution measured at all") controlling what
    /// `measurePerTestCoverage` hands back.
    private func run(
        selectCoveringTests: Bool,
        attribution: Set<TestIdentifier>??,
        confirmCrashKills: Bool = false,
        behaviors: [FakeSchemataAdapter.Behavior]
    ) async throws -> (SchemataMutationRunner.Outcome, FakeSchemataAdapter) {
        let mutationPoint = try point()
        let mutationID = mutationPoint.id
        let unit = compilationUnitID(point: mutationPoint)

        let adapter = FakeSchemataAdapter()
        adapter.scripts[Self.token] = .init(compilationUnitID: unit, sourceEmbeddingID: Self.sourceEmbeddingID, behaviors: behaviors)
        adapter.perTestCoverageToReturn = attribution.map { covering in
            PerTestCoverageMap(
                coveringTests: covering.map { [mutationPoint.file: [mutationPoint.line: $0]] } ?? [:],
                source: "test"
            )
        } ?? nil

        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [program(entry: entry(mutationID: mutationID))],
            points: [mutationID: mutationPoint],
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-schemata-selection-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-schemata-selection-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: MutationVerdictVerifier.VerdictVerificationPolicy(
                retestKilledMutants: false, confirmCrashKills: confirmCrashKills, confirmTimedOutMutants: false
            ),
            selectCoveringTests: selectCoveringTests
        )
        let outcome = try await runner.run()
        return (outcome, adapter)
    }

    @Test("selectCoveringTests on, attribution known: the token run is narrowed to the attributed tests")
    func knownAttributionNarrowsTheRun() async throws {
        let (outcome, adapter) = try await run(
            selectCoveringTests: true, attribution: .some([Self.addTest]), behaviors: [.passed(includeHit: true)]
        )

        #expect(outcome.results.count == 1)
        #expect(adapter.selectedTestsSeen == [[Self.addTest]])
    }

    @Test("selectCoveringTests on, attribution unknown for this exact site: falls back to the unrestricted run, not an empty one")
    func unknownAttributionFallsBackToUnrestricted() async throws {
        let (outcome, adapter) = try await run(
            selectCoveringTests: true, attribution: .some(nil), behaviors: [.passed(includeHit: true)]
        )

        #expect(outcome.results.count == 1)
        #expect(adapter.selectedTestsSeen == [nil])
    }

    @Test("selectCoveringTests on, no per-test coverage measured at all (adapter returned nil): falls back to the unrestricted run")
    func noPerTestCoverageAtAllFallsBackToUnrestricted() async throws {
        let (outcome, adapter) = try await run(
            selectCoveringTests: true, attribution: nil, behaviors: [.passed(includeHit: true)]
        )

        #expect(outcome.results.count == 1)
        #expect(adapter.selectedTestsSeen == [nil])
    }

    @Test("selectCoveringTests off (the config default): every token run stays unrestricted even though the adapter could narrow")
    func flagOffNeverNarrowsEvenIfTheAdapterCould() async throws {
        let (outcome, adapter) = try await run(
            selectCoveringTests: false, attribution: .some([Self.addTest]), behaviors: [.passed(includeHit: true)]
        )

        #expect(outcome.results.count == 1)
        #expect(adapter.selectedTestsSeen == [nil])
    }

    @Test("A crash confirmation rerun reproduces the exact same narrowed selection as the primary run, never a different one")
    func confirmationReproducesTheSameSelection() async throws {
        let (outcome, adapter) = try await run(
            selectCoveringTests: true, attribution: .some([Self.addTest]),
            confirmCrashKills: true, behaviors: [.crashed, .crashed]
        )

        #expect(outcome.results.count == 1)
        // Primary run, then the independent confirmation run — both narrowed
        // to the exact same attributed test, never recomputed or widened.
        #expect(adapter.selectedTestsSeen == [[Self.addTest], [Self.addTest]])
    }

    // MARK: - Selected-test-aware timeout

    // A `10...30`s, `selectedTests.count`-scaled clamp lived here
    // previously — narrowing a known selection's timeout well below the
    // whole-suite number. Gate 3's real-iOS-project run found it
    // uncalibrated for Xcode/Simulator's fixed per-invocation overhead (see
    // `TimeoutController.mutantLimitSeconds(selectedTests:)`'s own doc
    // comment and `Research/benchmarks/gate3-ios-schemata-2026-08-23`), so a
    // known selection now resolves to the same whole-suite number an
    // unknown one always did — the three tests below assert that identical
    // outcome instead of a narrower one.

    @Test("A known, non-empty selection resolves to the same whole-suite timeout as an unknown one, not a narrower clamp")
    func knownSelectionMatchesWholeSuiteTimeout() async throws {
        let (outcome, adapter) = try await run(
            selectCoveringTests: true, attribution: .some([Self.addTest]), behaviors: [.passed(includeHit: true)]
        )

        #expect(outcome.results.count == 1)
        let observed = try #require(adapter.tokenTimeoutSeconds.first)
        // TimeoutSettings(baselineSeconds: 30) with an unmeasured (~0s) fake
        // baseline resolves to ~ the adaptive default's overheadAllowance (60s).
        // The fake baseline's own "measured duration" is real wall-clock time
        // around instant fake work, not a true ~0 -- under real CI
        // contention (observed directly, recurring) that measurement can
        // drift by several seconds. Widened from 1s to 10s: still comfortably
        // tighter than the 30s gap to the nearest wrong answer.
        #expect(abs(observed - 60) < 10)
    }

    @Test("An unknown/unattributed selection keeps today's whole-suite-scaled timeout, completely unchanged")
    func unknownSelectionFallsThroughToWholeSuiteTimeout() async throws {
        let (outcome, adapter) = try await run(
            selectCoveringTests: true, attribution: .some(nil), behaviors: [.passed(includeHit: true)]
        )

        #expect(outcome.results.count == 1)
        let observed = try #require(adapter.tokenTimeoutSeconds.first)
        // TimeoutSettings(baselineSeconds: 30) with an unmeasured (~0s) fake
        // baseline resolves to ~ the adaptive default's overheadAllowance (60s).
        // The fake baseline's own "measured duration" is real wall-clock time
        // around instant fake work, not a true ~0 -- under real CI
        // contention (observed directly, recurring) that measurement can
        // drift by several seconds. Widened from 1s to 10s: still comfortably
        // tighter than the 30s gap to the nearest wrong answer.
        #expect(abs(observed - 60) < 10)
    }

    @Test("A confirmation reruns under the exact same resolved limit the primary run used, never a separately-resolved one")
    func confirmationReusesThePrimaryRunsResolvedTimeout() async throws {
        let (outcome, adapter) = try await run(
            selectCoveringTests: true, attribution: .some([Self.addTest]),
            confirmCrashKills: true, behaviors: [.crashed, .crashed]
        )

        #expect(outcome.results.count == 1)
        #expect(adapter.tokenTimeoutSeconds.count == 2)
        #expect(
            abs(adapter.tokenTimeoutSeconds[0] - adapter.tokenTimeoutSeconds[1]) < 0.001,
            "primary and confirmation must resolve to the identical limit, got \(adapter.tokenTimeoutSeconds)"
        )
    }
}
