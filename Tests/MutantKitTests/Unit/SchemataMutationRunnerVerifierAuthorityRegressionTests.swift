import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// ADR-0008 §5 item 7: written last, against the *finished* control-flow
/// shape (`runPrimary`/`runConfirmation`/`runEntries`), specifically so it
/// exercises the mechanism this ADR actually shipped, not an intermediate
/// design. Two independent checks:
///
/// 1. **Structural** — no code path this ADR introduced constructs a
///    `VerifiedMutationRecord` outside `MutationVerdictVerifier.verify`.
///    `finalize(point:...)` (`SchemataMutationRunner.swift`) is the sole
///    choke point; a source-level count is a blunt but effective proof that
///    no second call site was added anywhere in this file, matching the
///    ADR's own "assert, by construction... that no new code path
///    constructs a verdict outside it" requirement.
/// 2. **Behavioral** — replays `SchemataConfirmationCrashTimeoutVerifierTests
///    .timeoutConfirmationFinishingNormallyIsFlakyNotCascaded`'s scenario
///    (a primary timeout whose confirmation resolves normally must stay
///    `.flaky`, never promoted to `.verifiedTimeout`, since schemata mode's
///    `isBatchAttributedTimeout` is permanently `false`) through the *full*
///    runner, with ADR-0008's mid-chunk rebuild genuinely interposed between
///    the primary and confirmation runs — proving the rebuild (a new code
///    path) cannot smuggle different evidence into the verifier and flip
///    this invariant.
///
/// Addendum 4 (shared schemata chunk build-failure attribution) adds no new
/// call site to `finalize`/`MutationVerdictVerifier.verify` — its whole
/// point is to route affected `MutationID`s to `.isolatedFallback` instead
/// of calling `finalize` at all — so check 1's source-level count already
/// covers it without modification. The behavioral half (that no verdict,
/// correct or otherwise, is fabricated for a shared-build-failure-routed
/// `MutationID`) is pinned in
/// `SchemataMutationRunnerSharedChunkBuildFailureTests`.
@Suite("SchemataMutationRunner: ADR-0008 verifier-authority regression")
struct SchemataMutationRunnerVerifierAuthorityRegressionTests {
    @Test("""
    MutationVerdictVerifier.verify(_:policy:) is called from exactly one place in SchemataMutationRunner.swift — finalize's own \
    choke point
    """)
    func verifierIsCalledFromExactlyOneChokePoint() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent() // Unit/
            .deletingLastPathComponent() // MutantKitTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
        let runnerSourceURL = repoRoot.appendingPathComponent("Sources/MutationExecution/SchemataMutationRunner.swift")
        let contents = try String(contentsOf: runnerSourceURL, encoding: .utf8)
        let occurrences = contents.components(separatedBy: "MutationVerdictVerifier.verify(").count - 1
        #expect(occurrences == 1, "expected exactly one MutationVerdictVerifier.verify(...) call site (finalize); found \(occurrences)")
    }

    // MARK: - Behavioral: the rebuild must not weaken the .flaky invariant

    private static let source = "func flag() -> Bool { true }\n"
    private static let relativePath = "Widget.swift"
    private static let projectIdentity = "App.xcodeproj"
    private static let lowererID = "bool-literal"
    private static let lowererVersion = 1
    private static let target = "App"
    private static let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))

    private func point() throws -> MutationPoint {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        return try #require(points.first)
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("""
    A primary timeout-kill's mandatory containment rebuild still leaves a confirmation-resolves-normally verdict at .flaky, \
    never promoted
    """)
    func rebuildInterposedBeforeConfirmationDoesNotWeakenTheFlakyInvariant() async throws {
        let mutationPoint = try point()
        let mutationID = mutationPoint.id
        let unit = CompilationUnitID.derive(
            projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target,
            sourcePath: mutationPoint.file, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
        )
        let token = SchemataSelectorToken(namespace: 1, localIndex: 1)
        let adapter = FakeSchemataAdapter()
        // Primary times out; the confirmation that Trigger 1's rebuild
        // deliberately runs against a *fresh* build then resolves normally.
        adapter.scripts[token] = .init(
            compilationUnitID: unit, sourceEmbeddingID: Self.sourceEmbeddingID, behaviors: [.timedOut, .passed(includeHit: true)]
        )

        let entry = SchemataPlanEntry(
            mutationID: mutationID,
            placement: .embedded(placements: [
                SchemataEmbeddedPlacement(
                    chunkID: "chunk-A", selectorToken: token,
                    sourceEmbeddingID: Self.sourceEmbeddingID.rawValue, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion,
                    projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target, product: "\(Self.target).app", expectedImages: []
                )
            ]),
            conflictGroup: nil, projectIdentity: Self.projectIdentity, target: Self.target, module: Self.target, product: "\(Self.target).app"
        )
        let program = SchemataProgram(
            chunkID: "chunk-A", sourceEmbeddingID: Self.sourceEmbeddingID.rawValue,
            loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.source)],
            entries: [entry]
        )

        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [program], points: [mutationID: mutationPoint],
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-verifier-authority-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-verifier-authority-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: MutationVerdictVerifier.VerdictVerificationPolicy(
                retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: true
            )
        )
        let outcome = try await runner.run()

        // The rebuild genuinely happened (proof this test exercises Trigger
        // 1, not a no-op): call 1 (initial) + call 2 (Trigger 1, before the
        // confirmation).
        #expect(adapter.buildCallCount == 2)
        #expect(outcome.isolatedFallbacks.isEmpty)
        let result = try #require(outcome.results.first { $0.id == mutationID })
        #expect(result.outcome == .flaky)
    }
}
