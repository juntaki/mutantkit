import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// An unverified post-SIGKILL cleanup aborts the whole run, fail-closed,
/// wherever it happens. One test per location, for each runner that has it:
///
/// | where           | handling                                              |
/// | schemata token  | current entry not scorable + run abort                |
/// | isolated mutant | current mutant not scorable + run abort               |
/// | baseline test   | run abort                                             |
/// | build           | run abort                                             |
/// | confirmation    | run-level infrastructure failure (not flaky/confirmation-failed) |
///
/// "Run abort" is observed as `run()` throwing `RunAbortedError` (no report,
/// no `Outcome`) and no later build or test being started. The build rows
/// run a real supervised process through `UnverifiedCleanupFixture`, so they
/// also prove the `ProcessSupervisor` → `RunContainmentMonitor` path.
@Suite("Run-level fail-closed abort on unverified cleanup", .subprocessExclusive)
struct RunLevelCleanupAbortTests {
    // MARK: - Schemata

    private struct SchemataFixture {
        let source: String
        let relativePath: String
        let program: SchemataProgram
        let pointsByID: [MutationID: MutationPoint]
        let sortedPoints: [MutationPoint]
        let projectRoot: URL
        let scratchRoot: URL

        static let projectIdentity = "App.xcodeproj"
        static let lowererID = "bool-literal"
        static let target = "App"

        static func make() throws -> SchemataFixture {
            let relativePath = "Widget.swift"
            let source = "func flag1() -> Bool { true }\nfunc flag2() -> Bool { true }\n"
            let discovered = try CoreOperatorExpansionTestSupport.discover(
                source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: relativePath
            )
            let sortedPoints = discovered.sorted { $0.utf8Range.start < $1.utf8Range.start }
            precondition(sortedPoints.count == 2)
            let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))
            var entries: [SchemataPlanEntry] = []
            var pointsByID: [MutationID: MutationPoint] = [:]
            for (index, point) in sortedPoints.enumerated() {
                entries.append(SchemataPlanEntry(
                    mutationID: point.id,
                    placement: .embedded(placements: [
                        SchemataEmbeddedPlacement(
                            chunkID: "chunk-A", selectorToken: SchemataSelectorToken(namespace: UInt64(index + 1), localIndex: 1),
                            sourceEmbeddingID: sourceEmbeddingID.rawValue, lowererID: lowererID, lowererVersion: 1,
                            projectIdentity: projectIdentity, target: target, module: target, product: "\(target).app", expectedImages: []
                        )
                    ]),
                    conflictGroup: nil, projectIdentity: projectIdentity, target: target, module: target, product: "\(target).app"
                ))
                pointsByID[point.id] = point
            }
            return SchemataFixture(
                source: source, relativePath: relativePath,
                program: SchemataProgram(
                    chunkID: "chunk-A", sourceEmbeddingID: sourceEmbeddingID.rawValue,
                    loweredSources: [SchemataSourceFile(relativePath: relativePath, contents: source)], entries: entries
                ),
                pointsByID: pointsByID, sortedPoints: sortedPoints,
                projectRoot: makeTempDir(prefix: "mutantkit-abort-project"), scratchRoot: makeTempDir(prefix: "mutantkit-abort-scratch")
            )
        }

        func token(at index: Int) -> SchemataSelectorToken {
            SchemataSelectorToken(namespace: UInt64(index + 1), localIndex: 1)
        }

        /// Both entries pass with a HIT unless a test overrides entry 0.
        func script(_ adapter: FakeSchemataAdapter, entry0: [FakeSchemataAdapter.Behavior] = [.passed(includeHit: true)]) {
            for index in 0 ..< 2 {
                adapter.scripts[token(at: index)] = .init(
                    compilationUnitID: CompilationUnitID.derive(
                        projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
                        sourcePath: sortedPoints[index].file, lowererID: Self.lowererID, lowererVersion: 1
                    ),
                    sourceEmbeddingID: SHA256Digest.of(Data(source.utf8)),
                    behaviors: index == 0 ? entry0 : [.passed(includeHit: true)]
                )
            }
        }

        func run(
            _ adapter: FakeSchemataAdapter, coverageCache: CoverageProfileCache? = nil, coverageCacheKey: CoverageProfileCache.Key? = nil
        ) async throws -> SchemataMutationRunner.Outcome {
            let runner = SchemataMutationRunner(
                planID: "plan-1", workUnitID: "wu-1", programs: [program], points: pointsByID,
                originalSources: [relativePath: Data(source.utf8)], build: adapter, test: adapter,
                workspaces: try WorkspaceManager(projectRoot: projectRoot, scratchRoot: scratchRoot),
                timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
                policy: MutationVerdictVerifier.VerdictVerificationPolicy(
                    retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
                ),
                selectCoveringTests: coverageCache != nil, workers: 1,
                coverageCache: coverageCache, coverageCacheKey: coverageCacheKey
            )
            return try await runner.run()
        }
    }

    @Test("Schemata token: an unverified primary aborts the run and no later entry runs")
    func schemataTokenAbortsTheRun() async throws {
        let fixture = try SchemataFixture.make()
        let adapter = FakeSchemataAdapter()
        fixture.script(adapter)
        adapter.unverifiedCleanupOnDispatch[fixture.token(at: 0)] = 0

        await #expect(throws: RunAbortedError.self) { _ = try await fixture.run(adapter) }
        #expect(adapter.runIDsSeenByToken[fixture.token(at: 0)]?.count == 1)
        #expect(adapter.runIDsSeenByToken[fixture.token(at: 1)] == nil, "no entry may run after the abort")
    }

    @Test("Schemata control: without an unverified cleanup both entries run and the run returns")
    func schemataControlRunsBothEntries() async throws {
        let fixture = try SchemataFixture.make()
        let adapter = FakeSchemataAdapter()
        fixture.script(adapter)

        let outcome = try await fixture.run(adapter)
        #expect(outcome.results.count == 2)
        #expect(adapter.runIDsSeenByToken[fixture.token(at: 1)]?.count == 1)
    }

    @Test("Schemata confirmation: an unverified confirmation aborts the run instead of becoming flaky")
    func schemataConfirmationAbortsTheRun() async throws {
        let fixture = try SchemataFixture.make()
        let adapter = FakeSchemataAdapter()
        fixture.script(adapter, entry0: [.timedOut, .timedOut])
        adapter.unverifiedCleanupOnDispatch[fixture.token(at: 0)] = 1

        await #expect(throws: RunAbortedError.self) { _ = try await fixture.run(adapter) }
        #expect(adapter.runIDsSeenByToken[fixture.token(at: 0)]?.count == 2, "the primary and its confirmation")
        #expect(adapter.runIDsSeenByToken[fixture.token(at: 1)] == nil, "no entry may run after the abort")
    }

    @Test("Schemata baseline: an unverified baseline test aborts before any chunk is built")
    func schemataBaselineAbortsTheRun() async throws {
        let fixture = try SchemataFixture.make()
        let adapter = FakeSchemataAdapter()
        fixture.script(adapter)
        adapter.baselineResult = Self.unverifiedPassingBaseline

        await #expect(throws: RunAbortedError.self) { _ = try await fixture.run(adapter) }
        #expect(adapter.buildCallCount == 0)
        #expect(adapter.runIDsSeenByToken.isEmpty)
    }

    @Test("Schemata baseline: a baseline that tripped the monitor measures no coverage and caches none")
    func schemataBaselineTripSkipsCoverage() async throws {
        let fixture = try SchemataFixture.make()
        let adapter = FakeSchemataAdapter()
        fixture.script(adapter)
        adapter.perTestCoverageToReturn = PerTestCoverageMap(coveringTests: [:], source: "test")
        adapter.baselineResult = Self.unverifiedPassingBaseline
        let cache = CoverageProfileCache(root: makeTempDir(prefix: "mutantkit-abort-schemata-coverage"))
        let key = CoverageProfileCache.Key(contextDigest: "coverage-digest")

        await #expect(throws: RunAbortedError.self) {
            _ = try await fixture.run(adapter, coverageCache: cache, coverageCacheKey: key)
        }
        #expect(adapter.measurePerTestCoverageCallCount == 0, "no new process may be launched after the baseline tripped")
        #expect(await cache.load(key) == nil)
    }

    @Test("Schemata build: a chunk build whose supervised process cannot be verified aborts the run")
    func schemataBuildAbortsTheRun() async throws {
        let fixture = try SchemataFixture.make()
        let adapter = FakeSchemataAdapter()
        fixture.script(adapter)
        adapter.buildRunsUnverifiedProcessOnCall = 1

        await #expect(throws: RunAbortedError.self) { _ = try await fixture.run(adapter) }
        #expect(adapter.runIDsSeenByToken.isEmpty, "no token may run against a chunk whose build could not be contained")
    }

    private static let unverifiedPassingBaseline = TestRunResult(
        status: .passed, summary: nil, command: CommandRecord(executable: "x", arguments: [], workingDirectory: "/"),
        resultArtifactPath: nil, diagnosis: "passed", cleanupVerified: false, cleanupDiagnosis: "injected"
    )

    // MARK: - Isolated

    private struct IsolatedFixture {
        let root = makeTempDir(prefix: "mutantkit-abort-isolated-project")
        let scratch = makeTempDir(prefix: "mutantkit-abort-isolated-scratch")

        func run(
            test: ScriptedCleanupTestAdapter, build: CountingBuildAdapter, retestKilledMutants: Bool = false,
            confirmCrashKills: Bool = false, confirmTimedOutMutants: Bool = false
        ) async throws -> RunReport {
            let url = root.appendingPathComponent("Sources/A.swift")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("struct A { var enabled = true; var other = true }".utf8).write(to: url)
            let configuration = Configuration(execution: ExecutionSettings(
                workers: 1, retestKilledMutants: retestKilledMutants, confirmCrashKills: confirmCrashKills,
                confirmTimedOutMutants: confirmTimedOutMutants
            ))
            let plan = try await MutationPlanner().makePlan(
                configuration: configuration, projectRoot: root, toolchain: makeToolchain(), diffScope: nil
            )
            #expect(plan.mutations.count >= 2, "the abort-stops-later-work assertions need a second mutant")
            return try await MutationRunner(
                plan: plan, configuration: configuration, projectRoot: root, build: build, test: test,
                workspaces: try WorkspaceManager(projectRoot: root, scratchRoot: scratch)
            ).run()
        }
    }

    @Test("Isolated mutant: an unverified mutant run aborts the run and no later mutant runs")
    func isolatedMutantAbortsTheRun() async throws {
        let test = ScriptedCleanupTestAdapter(mutantRuns: [(.passed, false)])
        let build = CountingBuildAdapter()

        await #expect(throws: RunAbortedError.self) { _ = try await IsolatedFixture().run(test: test, build: build) }
        #expect(await test.mutantCallCount == 1)
        #expect(build.mutantBuildCount == 1, "no later mutant may be built after the abort")
    }

    @Test("Isolated mutant: an unverified timed-out primary starts no confirmation rebuild")
    func isolatedTimedOutPrimaryStartsNoConfirmation() async throws {
        let test = ScriptedCleanupTestAdapter(mutantRuns: [(.timedOut, false)])
        let build = CountingBuildAdapter()

        await #expect(throws: RunAbortedError.self) {
            _ = try await IsolatedFixture().run(test: test, build: build, confirmTimedOutMutants: true)
        }
        #expect(await test.mutantCallCount == 1, "no confirmation test may run after the abort")
        #expect(build.mutantBuildCount == 1, "no confirmation rebuild may start after the abort")
    }

    @Test("Isolated mutant: an unverified crashed primary starts no confirmation rebuild")
    func isolatedCrashedPrimaryStartsNoConfirmation() async throws {
        let test = ScriptedCleanupTestAdapter(mutantRuns: [(.crashed, false)])
        let build = CountingBuildAdapter()

        await #expect(throws: RunAbortedError.self) {
            _ = try await IsolatedFixture().run(test: test, build: build, confirmCrashKills: true)
        }
        #expect(await test.mutantCallCount == 1, "no confirmation test may run after the abort")
        #expect(build.mutantBuildCount == 1, "no confirmation rebuild may start after the abort")
    }

    @Test("Isolated control: a verified timed-out primary does start its confirmation rebuild")
    func isolatedVerifiedTimedOutPrimaryIsConfirmed() async throws {
        let test = ScriptedCleanupTestAdapter(mutantRuns: [(.timedOut, true)])
        let build = CountingBuildAdapter()

        let report = try await IsolatedFixture().run(test: test, build: build, confirmTimedOutMutants: true)
        #expect(build.mutantBuildCount == report.results.count + 1, "one build per mutant plus the confirmation rebuild")
        #expect(await test.mutantCallCount == report.results.count + 1, "one test per mutant plus the confirmation test")
    }

    @Test("Isolated confirmation: an unverified confirmation retest aborts the run instead of becoming flaky")
    func isolatedConfirmationAbortsTheRun() async throws {
        let test = ScriptedCleanupTestAdapter(mutantRuns: [(.failed, true), (.passed, false)])
        let build = CountingBuildAdapter()

        await #expect(throws: RunAbortedError.self) {
            _ = try await IsolatedFixture().run(test: test, build: build, retestKilledMutants: true)
        }
        #expect(await test.mutantCallCount == 2)
        #expect(build.mutantBuildCount == 1)
    }

    @Test("Isolated baseline: an unverified baseline test aborts the run instead of returning a report")
    func isolatedBaselineAbortsTheRun() async throws {
        let test = ScriptedCleanupTestAdapter(baselineCleanupVerified: false, mutantRuns: [])
        let build = CountingBuildAdapter()

        await #expect(throws: RunAbortedError.self) { _ = try await IsolatedFixture().run(test: test, build: build) }
        #expect(await test.mutantCallCount == 0)
        #expect(build.mutantBuildCount == 0)
    }

    @Test("Isolated build: a mutant build whose supervised process cannot be verified aborts the run")
    func isolatedBuildAbortsTheRun() async throws {
        let test = ScriptedCleanupTestAdapter(mutantRuns: [(.passed, true), (.passed, true)])
        let build = CountingBuildAdapter(unverifiedProcessOnMutantBuild: 1)

        await #expect(throws: RunAbortedError.self) { _ = try await IsolatedFixture().run(test: test, build: build) }
        #expect(await test.mutantCallCount == 0, "nothing may be tested after an uncontained build")
        #expect(build.mutantBuildCount == 1)
    }

    // MARK: - Hybrid engine

    @Test("Hybrid: an unverified shared baseline aborts before either portion, with no isolated fallback")
    func hybridSharedBaselineAbortsTheRun() async throws {
        let fixture = IsolatedFixture()
        let url = fixture.root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("struct A { var enabled = true }".utf8).write(to: url)
        let configuration = Configuration(execution: ExecutionSettings(workers: 1))
        let plan = try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: fixture.root, toolchain: makeToolchain(), diffScope: nil
        )
        let test = ScriptedCleanupTestAdapter(baselineCleanupVerified: false, mutantRuns: [])
        let adapter = CleanupProjectAdapter(buildAdapter: CountingBuildAdapter(), testAdapter: test)
        let context = HybridExecutionEngine.Context(
            plan: plan, configuration: configuration, projectRoot: fixture.root, adapter: adapter, testAdapter: test,
            toolchain: makeToolchain(),
            coverageCache: CoverageProfileCache(root: makeTempDir(prefix: "mutantkit-abort-coverage")), coverageCacheKey: nil
        )

        await #expect(throws: RunAbortedError.self) {
            _ = try await HybridExecutionEngine.runHybrid(
                context: context,
                classification: HybridExecutionEngine.SchemataClassification(
                    programs: [], embeddedIDs: [], sources: [:], plannerFallbackReasons: [:]
                ),
                workspaces: try WorkspaceManager(projectRoot: fixture.root, scratchRoot: fixture.scratch),
                schemataWorkspaces: try WorkspaceManager(
                    projectRoot: fixture.root, scratchRoot: makeTempDir(prefix: "mutantkit-abort-schemata-scratch")
                ),
                startedAt: Date()
            )
        }
        #expect(await test.mutantCallCount == 0, "the isolated fallback portion must never run")
    }
}

extension RunLevelCleanupAbortTests {
    // MARK: - Verifier authority

    @Test("Verifier: an unverified primary run is an infrastructure failure, never a scored verdict")
    func verifierExcludesUnverifiedPrimary() throws {
        let point = try makeAnchoredPoint()
        let survived = makeObservations(point: point, outcome: .survived)
        #expect(MutationVerdictVerifier.verify(survived, policy: .permissive).outcome == .survived, "control: this shape survives")
        let observations = MutationObservations(
            plannedMutation: survived.plannedMutation, sourceApplication: survived.sourceApplication, build: survived.build,
            test: try SingleTestObservation(
                run: #require(survived.test).run.unverified(), applicationEvidence: #require(survived.test).applicationEvidence
            )
        )
        let record = MutationVerdictVerifier.verify(observations, policy: .permissive)
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("Verifier: an unverified confirmation is an infrastructure failure, not flaky")
    func verifierExcludesUnverifiedConfirmation() throws {
        let point = try makeAnchoredPoint()
        let flaky = makeObservations(point: point, outcome: .flaky)
        #expect(MutationVerdictVerifier.verify(flaky, policy: .permissive).outcome == .flaky, "control: this shape is flaky")

        let confirmation = try #require(flaky.confirmations.first)
        let observations = MutationObservations(
            plannedMutation: flaky.plannedMutation, sourceApplication: flaky.sourceApplication, build: flaky.build, test: flaky.test,
            confirmations: [ConfirmationObservation(
                kind: .kill, run: confirmation.run.unverified(), originalFailingTests: confirmation.originalFailingTests
            )]
        )
        let record = MutationVerdictVerifier.verify(observations, policy: .permissive)
        #expect(record.outcome == .infrastructureFailure)
    }

    // MARK: - Monitor scope

    @Test("A run scope throws RunAbortedError even when its body returned normally, and nested scopes share one monitor")
    func runScopeThrowsAfterATrip() async throws {
        await #expect(throws: RunAbortedError.self) {
            try await RunContainmentMonitor.withRunScope { outer in
                try await RunContainmentMonitor.withRunScope { inner in
                    #expect(inner === outer)
                }
                outer.recordUnverifiedCleanup("injected")
                return 1
            }
        }
        let untouched = try await RunContainmentMonitor.withRunScope { _ in 2 }
        #expect(untouched == 2)
    }
}

// MARK: - Fakes

private func makeTempDir(prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private extension TestRunResult {
    func unverified() -> TestRunResult {
        TestRunResult(
            status: status, summary: summary, command: command, resultArtifactPath: resultArtifactPath, diagnosis: diagnosis,
            isBatchAttributedTimeout: isBatchAttributedTimeout, crashProvenance: crashProvenance,
            cleanupVerified: false, cleanupDiagnosis: "injected"
        )
    }
}

/// Builds without a toolchain. `unverifiedProcessOnMutantBuild` (1-based)
/// makes that `buildMutant` call first run a real supervised process whose
/// post-SIGKILL cleanup cannot be verified.
private final class CountingBuildAdapter: BuildAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var mutantBuilds = 0
    private let unverifiedProcessOnMutantBuild: Int?

    init(unverifiedProcessOnMutantBuild: Int? = nil) {
        self.unverifiedProcessOnMutantBuild = unverifiedProcessOnMutantBuild
    }

    var mutantBuildCount: Int { lock.withLock { mutantBuilds } }

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        artifact(hash: "baseline-hash", in: workspace)
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        let call = lock.withLock {
            mutantBuilds += 1
            return mutantBuilds
        }
        if call == unverifiedProcessOnMutantBuild {
            _ = try await UnverifiedCleanupFixture.run()
        }
        return artifact(hash: "mutant-hash-\(call)", in: workspace)
    }

    private func artifact(hash: String, in workspace: URL) -> BuildArtifact {
        BuildArtifact(
            productsDirectory: workspace, productHash: hash, xctestrunPath: nil,
            command: CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
        )
    }
}

/// Baseline passes; each `runMutant` call returns the next scripted status
/// and cleanup verification. Also `SchemataTestable`, only so the hybrid
/// engine's capability guard accepts it; no token is ever run.
private actor ScriptedCleanupTestAdapter: TestAdapter, SchemataTestable {
    private let baselineCleanupVerified: Bool
    private var remaining: [(TestRunStatus, Bool)]
    private(set) var mutantCallCount = 0

    init(baselineCleanupVerified: Bool = true, mutantRuns: [(TestRunStatus, Bool)]) {
        self.baselineCleanupVerified = baselineCleanupVerified
        remaining = mutantRuns
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        Self.result(.passed, cleanupVerified: baselineCleanupVerified)
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        mutantCallCount += 1
        let (status, cleanupVerified) = remaining.isEmpty ? (.passed, true) : remaining.removeFirst()
        return Self.result(status, cleanupVerified: cleanupVerified)
    }

    func runSchemataToken(
        _ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String],
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        Issue.record("no schemata token may run in this test")
        return Self.result(.infrastructureFailure, cleanupVerified: true)
    }

    private static func result(_ status: TestRunStatus, cleanupVerified: Bool) -> TestRunResult {
        TestRunResult(
            status: status,
            summary: status == .failed
                ? TestOutcomeSummary(total: 1, passed: 0, failed: 1, failingTests: ["testX"], durationSeconds: 0.01)
                : nil,
            command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted \(status.rawValue)",
            cleanupVerified: cleanupVerified, cleanupDiagnosis: cleanupVerified ? nil : "injected unverified cleanup"
        )
    }
}

private struct CleanupProjectAdapter: ProjectAdapter {
    let buildAdapter: CountingBuildAdapter
    let testAdapter: ScriptedCleanupTestAdapter
    private let schemataBuilder = FakeSchemataAdapter()

    var kind: ProjectKind { .swiftPackageMacOS }
    var build: any BuildAdapter { buildAdapter }
    var test: any TestAdapter { testAdapter }
    var schemataBuild: (any SchemataBuildable)? { schemataBuilder }
    var schemataTest: (any SchemataTestable)? { testAdapter }
}
