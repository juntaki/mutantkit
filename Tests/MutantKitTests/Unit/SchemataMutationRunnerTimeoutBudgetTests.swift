import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Schemata mode's two structurally different wall-clock limits, and the
/// regression that collapsed them into one.
///
/// `SchemataMutationRunner` used to take a single `timeoutSeconds` and apply
/// it to both `runBaseline` (correct — that *is* the baseline limit) and
/// every `runSchemataToken` spawn (wrong — that is one mutant's run). The
/// only production caller passed `timeouts.baselineSeconds`, so on a real
/// 602-mutant corpus run every schemata mutant was budgeted 600 s while
/// isolated mode correctly budgeted the configured 186 s; the 19 mutants
/// that actually hit it burned 5.99 h of the run's 6.58 h schemata wall
/// time.
///
/// These tests pin both halves — a token run bounded by the *mutant* limit,
/// and the baseline run still bounded by its own, deliberately longer one —
/// against the real adapter-facing values, since the `timeoutSeconds`
/// argument the adapter receives is the only thing that actually reaches
/// `ProcessSupervisor`.
@Suite("SchemataMutationRunner: baseline vs. per-mutant timeout budgets")
struct SchemataMutationRunnerTimeoutBudgetTests {
    // MARK: - Fixture: one two-entry chunk, both entries scoring normally

    private static let projectIdentity = "App.xcodeproj"
    private static let lowererID = "bool-literal"
    private static let lowererVersion = 1
    private static let target = "App"
    private static let relativePath = "Widget.swift"
    private static let source = "func a() -> Bool { true }\nfunc b() -> Bool { true }\n"
    private static let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))

    private func twoPoints() throws -> [MutationPoint] {
        let discovered = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        let sorted = discovered.sorted { $0.utf8Range.start < $1.utf8Range.start }
        precondition(sorted.count == 2)
        return sorted
    }

    private func entry(mutationID: MutationID, localIndex: UInt32) -> SchemataPlanEntry {
        SchemataPlanEntry(
            mutationID: mutationID,
            placement: .embedded(placements: [
                SchemataEmbeddedPlacement(
                    chunkID: "chunk-A", selectorToken: SchemataSelectorToken(namespace: 1, localIndex: localIndex),
                    sourceEmbeddingID: Self.sourceEmbeddingID.rawValue, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion,
                    projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
                    product: "\(Self.target).app", expectedImages: []
                )
            ]),
            conflictGroup: nil, projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
            product: "\(Self.target).app"
        )
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs one chunk of two embedded entries against `timeouts`, with both
    /// entries scripted to pass with a genuine HIT (so neither is dropped
    /// before it ever spawns a process), and returns the adapter that
    /// recorded every `timeoutSeconds` the runner actually asked for.
    @discardableResult
    private func run(
        timeouts: TimeoutSettings, behaviors: [FakeSchemataAdapter.Behavior] = [.passed(includeHit: true)],
        policy: MutationVerdictVerifier.VerdictVerificationPolicy = .permissive
    ) async throws -> (adapter: FakeSchemataAdapter, outcome: SchemataMutationRunner.Outcome) {
        let points = try twoPoints()
        let entries = points.enumerated().map { index, point in entry(mutationID: point.id, localIndex: UInt32(index + 1)) }
        let adapter = FakeSchemataAdapter()
        for index in points.indices {
            adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: UInt32(index + 1))] = .init(
                compilationUnitID: CompilationUnitID.derive(
                    projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
                    sourcePath: Self.relativePath, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
                ),
                sourceEmbeddingID: Self.sourceEmbeddingID,
                behaviors: behaviors
            )
        }
        let program = SchemataProgram(
            chunkID: "chunk-A", sourceEmbeddingID: Self.sourceEmbeddingID.rawValue,
            loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.source)],
            entries: entries
        )
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [program],
            points: Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) }),
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-timeout-budget-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-timeout-budget-scratch")
            ),
            timeouts: timeouts, toolchainHash: "toolchain", buildArgumentsHash: "args", policy: policy
        )
        return (adapter, try await runner.run())
    }

    /// The exact shape of the real run that exposed the defect: a default
    /// 600 s baseline limit alongside a 186 s fixed per-mutant limit.
    private static let realCorpusTimeouts = TimeoutSettings(
        baselineSeconds: 600,
        mutant: MutantTimeoutSettings(strategy: .fixed, multiplier: 3, minimumSeconds: 30, maximumSeconds: 186)
    )

    // MARK: - The regression itself

    @Test("Every schemata token run is bounded by the per-mutant limit, never by the baseline limit")
    func tokenRunsUseTheMutantLimit() async throws {
        let (adapter, outcome) = try await run(timeouts: Self.realCorpusTimeouts)

        #expect(outcome.results.count == 2, "precondition: both entries actually spawned and scored")
        #expect(adapter.tokenTimeoutSeconds.count == 2)
        for observed in adapter.tokenTimeoutSeconds {
            #expect(
                observed == 186,
                """
                a schemata token run must get the configured per-mutant limit (186 s), the same one isolated mode uses — \
                600 s here would mean the baseline limit is being reused per mutant, the defect this test exists for
                """
            )
        }
        #expect(!adapter.tokenTimeoutSeconds.contains(600), "the baseline limit must never reach a per-mutant spawn")
    }

    @Test("The baseline run keeps its own, longer limit — the fix must not shorten the one run that legitimately needs it")
    func baselineRunKeepsTheBaselineLimit() async throws {
        let (adapter, _) = try await run(timeouts: Self.realCorpusTimeouts)
        #expect(adapter.baselineTimeoutSeconds == [600], "the baseline runs the whole unmutated suite once; that limit is unchanged")
    }

    @Test("A timeout confirmation re-run is bounded by the per-mutant limit too, not the baseline one")
    func confirmationRunsUseTheMutantLimit() async throws {
        let (adapter, _) = try await run(
            timeouts: Self.realCorpusTimeouts,
            // Primary times out, confirmation times out too — two token
            // spawns for the same mutant, both of which used to be given the
            // baseline budget (the real run paid 600 s twice per hang).
            behaviors: [.timedOut, .timedOut],
            policy: MutationVerdictVerifier.VerdictVerificationPolicy(
                retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
            )
        )
        #expect(adapter.tokenTimeoutSeconds.count > 2, "each mutant should have spawned a primary run and a confirmation run")
        #expect(Set(adapter.tokenTimeoutSeconds) == [186])
        #expect(adapter.baselineTimeoutSeconds == [600])
    }

    // MARK: - Adaptive resolution, matching isolated mode's own

    @Test("An adaptive per-mutant limit is resolved from this run's own measured baseline duration, exactly as isolated mode does")
    func adaptiveMutantLimitIsResolvedFromTheMeasuredBaseline() async throws {
        // The fake baseline returns immediately, so the measured duration is
        // ~0 and `resolve` reduces to `max(overheadAllowance, minimum)` —
        // deliberately chosen distinct from both `baselineSeconds` and
        // `maximumSeconds` so neither could produce this value by accident.
        let timeouts = TimeoutSettings(
            baselineSeconds: 600,
            mutant: MutantTimeoutSettings(
                strategy: .adaptive, multiplier: 3, minimumSeconds: 5, maximumSeconds: 400, overheadAllowanceSeconds: 90
            )
        )
        let (adapter, _) = try await run(timeouts: timeouts)
        let observed = try #require(adapter.tokenTimeoutSeconds.first)
        #expect(
            abs(observed - 90) < 1,
            "adaptive resolve(baseline≈0) is overheadAllowance (90 s), not the 600 s baseline limit and not the 400 s ceiling: \(observed)"
        )
    }

    @Test("A fixed per-mutant strategy pins the ceiling, and still never the baseline limit")
    func fixedStrategyUsesTheConfiguredMaximum() async throws {
        let timeouts = TimeoutSettings(
            baselineSeconds: 999,
            mutant: MutantTimeoutSettings(strategy: .fixed, multiplier: 3, minimumSeconds: 30, maximumSeconds: 42)
        )
        let (adapter, _) = try await run(timeouts: timeouts)
        #expect(Set(adapter.tokenTimeoutSeconds) == [42])
        #expect(adapter.baselineTimeoutSeconds == [999])
    }
}
