@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// The other half of ADR-0008 Addendum 4's fan-out/observability
/// requirement. `SchemataMutationRunnerSharedChunkBuildFailureTests` already
/// pins that `SchemataMutationRunner` *computes* one aggregate
/// `SharedChunkBuildFailureEvent` per failed chunk build; this suite pins
/// that the CLI layer actually *reports* it — as an
/// `OperationalIssue` in the final `RunReport` and as the same one-line `!`
/// console message `SchemataRunOrchestration.classify` already uses for its
/// own degradations.
///
/// Why this needed its own suite: on a real 602-mutant corpus run
/// (`swift-async-algorithms`, 2026-08) two of these events fired, covering
/// 208 mutants and 7.24 h of wall time, and the operator saw nothing at all
/// — `sharedChunkBuildFailureEvents` had zero production consumers, and
/// `merge` reduced `Outcome.isolatedFallbacks` to bare `MutationID`s,
/// discarding every reason with it. Both gaps are closed here, and both are
/// pinned below against the *real* runner's own output rather than a
/// hand-built event, so the wiring cannot pass while the producer drifts.
@Suite("Schemata fallback observability (ADR-0008 Addendum 4 fan-out reporting)")
struct SchemataFallbackObservabilityTests {
    // MARK: - Fixture (mirrors SchemataMutationRunnerSharedChunkBuildFailureTests' own 3-entry chunk)

    private static let projectIdentity = "App.xcodeproj"
    private static let lowererID = "bool-literal"
    private static let lowererVersion = 1
    private static let target = "App"
    private static let relativePath = "Widget.swift"
    private static let source = "func a() -> Bool { true }\nfunc b() -> Bool { true }\nfunc c() -> Bool { true }\n"
    private static let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))

    private func threePoints() throws -> [MutationPoint] {
        let discovered = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        let sorted = discovered.sorted { $0.utf8Range.start < $1.utf8Range.start }
        precondition(sorted.count == 3)
        return sorted
    }

    private func entry(mutationID: MutationID, chunkID: String, localIndex: UInt32, namespace: UInt64) -> SchemataPlanEntry {
        SchemataPlanEntry(
            mutationID: mutationID,
            placement: .embedded(placements: [
                SchemataEmbeddedPlacement(
                    chunkID: chunkID, selectorToken: SchemataSelectorToken(namespace: namespace, localIndex: localIndex),
                    sourceEmbeddingID: Self.sourceEmbeddingID.rawValue, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion,
                    projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
                    product: "\(Self.target).app", expectedImages: []
                )
            ]),
            conflictGroup: nil, projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
            product: "\(Self.target).app"
        )
    }

    private func program(chunkID: String, entries: [SchemataPlanEntry]) -> SchemataProgram {
        SchemataProgram(
            chunkID: chunkID, sourceEmbeddingID: Self.sourceEmbeddingID.rawValue,
            loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.source)],
            entries: entries
        )
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One real `SchemataMutationRunner` run whose single chunk's shared
    /// build throws a typed `BuildFailure` — the synthetic reproduction of
    /// the real-corpus event, produced by the production runner itself.
    private func outcomeFromSyntheticSharedChunkBuildFailure() async throws -> SchemataMutationRunner.Outcome {
        let points = try threePoints()
        let entries = points.enumerated().map { index, point in
            entry(mutationID: point.id, chunkID: "chunk-A", localIndex: UInt32(index + 1), namespace: 1)
        }
        let adapter = FakeSchemataAdapter()
        adapter.buildFailureScript[1] = .throwBuildFailure(
            kind: .compilationError, diagnosis: "missing return in instance method expected to return 'Reduced?'"
        )
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [program(chunkID: "chunk-A", entries: entries)],
            points: Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) }),
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-observability-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-observability-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30),
            toolchainHash: "toolchain", buildArgumentsHash: "args", policy: .permissive
        )
        return try await runner.run()
    }

    // MARK: - The report channel

    @Test("""
    A shared-chunk build failure becomes exactly one non-empty operational issue naming the chunk, the mutant count it cost, \
    and the compiler diagnosis behind it
    """)
    func sharedChunkBuildFailureBecomesOneOperationalIssue() async throws {
        let outcome = try await outcomeFromSyntheticSharedChunkBuildFailure()
        #expect(outcome.sharedChunkBuildFailureEvents.count == 1, "precondition: the runner produced the event this suite reports")

        let issues = SchemataRunOrchestration.sharedChunkBuildFailureIssues(outcome.sharedChunkBuildFailureEvents)
        let issue = try #require(issues.first, "the event must not be silently dropped — this is the whole defect being fixed")
        #expect(issues.count == 1, "one issue per failed chunk, never one per affected MutationID")
        #expect(issue.kind == .schemataChunkBuildFailed)
        #expect(issue.severity == .warning, "every affected mutation still gets a real isolated verdict; score is unaffected")
        #expect(issue.mutationID == nil, "the event is chunk-level; attributing it to one mutation would misstate what failed")
        #expect(!issue.diagnosis.isEmpty)
        #expect(issue.diagnosis.contains("chunk-A"), "\(issue.diagnosis)")
        #expect(issue.diagnosis.contains("3 mutants"), "\(issue.diagnosis)")
        #expect(
            issue.diagnosis.contains("missing return in instance method expected to return 'Reduced?'"),
            "the operator must learn *why* the chunk did not compile, not merely that it did not: \(issue.diagnosis)"
        )
        #expect(issue.diagnosis.contains("isolated"), "\(issue.diagnosis)")
    }

    @Test("An operational issue survives a JSON round trip, so a reader of report.json sees the same thing the console did")
    func operationalIssueRoundTripsThroughJSON() async throws {
        let outcome = try await outcomeFromSyntheticSharedChunkBuildFailure()
        let issues = SchemataRunOrchestration.sharedChunkBuildFailureIssues(outcome.sharedChunkBuildFailureEvents)
        let decoded = try JSONDecoder().decode([OperationalIssue].self, from: JSONEncoder().encode(issues))
        #expect(decoded == issues)
        #expect(decoded.first?.kind == .schemataChunkBuildFailed)
    }

    @Test("A run with no failed chunk build reports no issue at all — this channel stays quiet when nothing is wrong")
    func noEventProducesNoIssue() {
        #expect(SchemataRunOrchestration.sharedChunkBuildFailureIssues([]).isEmpty)
    }

    @Test("A one-mutant chunk is reported in the singular, so the message never reads '1 mutants'")
    func singleAffectedMutationIsReportedInTheSingular() {
        let issues = SchemataRunOrchestration.sharedChunkBuildFailureIssues([
            SchemataMutationRunner.SharedChunkBuildFailureEvent(
                chunkID: "chunk-solo", affectedMutationCount: 1, diagnosticReference: "switch must be exhaustive"
            )
        ])
        #expect(issues.first?.diagnosis.contains("1 mutant forfeited") == true, "\(String(describing: issues.first?.diagnosis))")
    }

    // MARK: - The per-mutation fallback reasons `merge` used to discard

    @Test("Every dynamic fallback reason reaches the report as a count histogram, instead of being reduced to bare MutationIDs")
    func fallbackReasonsSurviveAsAHistogram() async throws {
        let outcome = try await outcomeFromSyntheticSharedChunkBuildFailure()
        #expect(outcome.isolatedFallbacks.count == 3)
        let counts = SchemataRunOrchestration.fallbackReasonCounts(outcome.isolatedFallbacks)
        #expect(counts == ["sharedChunkBuildFailure": 3])
    }

    @Test("The histogram keeps every reason distinct — a hang-budget overflow is never conflated with a build failure or a no-HIT")
    func histogramKeysAreDistinctPerReason() {
        let ids = (1 ... 4).map { MutationID(rawValue: "mut_\($0)") }
        let counts = SchemataRunOrchestration.fallbackReasonCounts([
            .init(mutationID: ids[0], reason: .sharedChunkBuildFailure),
            .init(mutationID: ids[1], reason: .hangBudgetExceeded),
            .init(mutationID: ids[2], reason: .activation(.noHit)),
            .init(mutationID: ids[3], reason: .activation(.noStartup))
        ])
        #expect(counts == [
            "sharedChunkBuildFailure": 1, "hangBudgetExceeded": 1, "activation.noHit": 1, "activation.noStartup": 1
        ])
    }

    @Test("A ExecutionStrategyReport carrying the histogram round-trips through JSON, and one without it still decodes")
    func executionStrategyReportHistogramIsSchemaAdditive() throws {
        let report = ExecutionStrategyReport(
            requested: .schemata, effectiveCount: 145, fallbackCount: 457,
            fallbackReasonCounts: ["sharedChunkBuildFailure": 208, "hangBudgetExceeded": 125]
        )
        let decoded = try JSONDecoder().decode(ExecutionStrategyReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
        #expect(decoded.fallbackReasonCounts?["sharedChunkBuildFailure"] == 208)

        // A report written before this field existed must still decode —
        // `report.json` is a published artifact other tools already read.
        let legacy = Data("""
        {"requested":"schemata","effectiveCount":1,"fallbackCount":2}
        """.utf8)
        let decodedLegacy = try JSONDecoder().decode(ExecutionStrategyReport.self, from: legacy)
        #expect(decodedLegacy.fallbackReasonCounts == nil)
    }

    // MARK: - The planner-time fallback reasons `fallbackReasonCounts` alone never covered (Gate 3 Phase H19)

    @Test("Every planner-time fallback reason reaches the report as a count histogram, keeping every reason distinct")
    func plannerFallbackReasonsSurviveAsAHistogram() {
        let counts = SchemataRunOrchestration.plannerFallbackReasonCounts([
            .resultBuilderBody,
            .patternPosition,
            .controlFlowConstant,
            .operatorNotYetLowered(operatorID: "swift.core.arithmetic-operator-replacement"),
            .operatorNotYetLowered(operatorID: "swift.core.arithmetic-operator-replacement"),
            .unsupportedOperand(reason: "a function call, evaluated twice, could have a side effect"),
            .structuralConflict(reason: "shares a rewrite envelope with mut_other")
        ])
        #expect(counts == [
            "resultBuilderBody": 1,
            "patternPosition": 1,
            "controlFlowConstant": 1,
            "operatorNotYetLowered.swift.core.arithmetic-operator-replacement": 2,
            "unsupportedOperand": 1,
            "structuralConflict": 1
        ])
    }

    @Test("The free-form diagnostic payload of unsupportedOperand/structuralConflict/platformUnsupported is dropped from the key — never a per-mutation-unique histogram entry")
    func freeFormDiagnosisTextNeverBecomesPartOfTheKey() {
        let counts = SchemataRunOrchestration.plannerFallbackReasonCounts([
            .unsupportedOperand(reason: "first mutant's own diagnosis text"),
            .unsupportedOperand(reason: "a completely different mutant's own diagnosis text"),
            .structuralConflict(reason: "yet another distinct diagnosis"),
            .platformUnsupported(reason: "and one more")
        ])
        #expect(counts == ["unsupportedOperand": 2, "structuralConflict": 1, "platformUnsupported": 1])
    }

    @Test("A ExecutionStrategyReport carrying both histograms round-trips through JSON, and a legacy report predating this field still decodes")
    func plannerFallbackReasonCountsIsSchemaAdditive() throws {
        let report = ExecutionStrategyReport(
            requested: .schemata, effectiveCount: 32, fallbackCount: 68,
            fallbackReasonCounts: ["activation.noStartup": 35, "activation.noHit": 1, "knownUncovered": 12],
            plannerFallbackReasonCounts: ["resultBuilderBody": 2, "unsupportedOperand": 18]
        )
        let decoded = try JSONDecoder().decode(ExecutionStrategyReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
        #expect(decoded.plannerFallbackReasonCounts?["unsupportedOperand"] == 18)

        // The exact invariant Phase H16's real-production-app 100-mutant run found
        // violated (48 dynamic-only vs. 68 actual fallbackCount) — now
        // closeable by summing both histograms.
        let dynamicTotal = (decoded.fallbackReasonCounts ?? [:]).values.reduce(0, +)
        let plannerTotal = (decoded.plannerFallbackReasonCounts ?? [:]).values.reduce(0, +)
        #expect(dynamicTotal + plannerTotal == decoded.fallbackCount)

        // A report written before this field existed must still decode.
        let legacy = Data("""
        {"requested":"schemata","effectiveCount":1,"fallbackCount":2}
        """.utf8)
        let decodedLegacy = try JSONDecoder().decode(ExecutionStrategyReport.self, from: legacy)
        #expect(decodedLegacy.plannerFallbackReasonCounts == nil)
    }
}
