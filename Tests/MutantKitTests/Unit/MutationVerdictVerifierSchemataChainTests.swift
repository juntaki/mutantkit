import Foundation
import MutationModel
import Testing

// Split out of `MutationVerdictVerifierTests` purely to keep that file's
// own `type_body_length`/`file_length` reviewable per declaration — still
// pins the identical `MutationVerdictVerifier.verifySchemataChain` behavior,
// no behavioral split. See that file's own doc comment for the verifier's
// overall decision-table context.
@Suite("Mutation verdict verifier: schemata chain verification (ADR-0006 Stage 2)")
struct MutationVerdictVerifierSchemataChainTests {
    private static let planID = "plan-A"
    private static let workUnitID = "unit-1"

    private func ref(for point: MutationPoint) -> PlannedMutationRef {
        PlannedMutationRef.forPoint(point, planID: Self.planID, workUnitID: Self.workUnitID)
    }

    private func verify(
        policy: MutationVerdictVerifier.VerdictVerificationPolicy = .permissive,
        _ obs: (PlannedMutationRef) -> MutationObservations
    ) throws -> VerifiedMutationRecord {
        let point = try makeAnchoredPoint()
        return MutationVerdictVerifier.verify(obs(ref(for: point)), policy: policy)
    }

    private func run(status: TestRunStatus, summary: TestOutcomeSummary? = nil, isBatchAttributedTimeout: Bool = false) -> TestRunResult {
        TestRunResult(
            status: status, summary: summary,
            command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: "diag:\(status.rawValue)",
            isBatchAttributedTimeout: isBatchAttributedTimeout
        )
    }

    // MARK: - Schemata mode (ADR-0006 Stage 2: MutationVerdictVerifier.verifySchemataChain)

    private var schemataObservation: SchemataExecutionObservation { makeConsistentSchemataObservation() }

    private func schemataObservations(
        status: TestRunStatus, observation: SchemataExecutionObservation, coverage: CoverageObservation? = nil
    ) -> (PlannedMutationRef) -> MutationObservations {
        { ref in
            MutationObservations(
                plannedMutation: ref,
                sourceApplication: .applied(makeEvidence(buildProductHash: "h1", applicationEvidence: .schemata(observation))),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                coverage: coverage,
                test: SingleTestObservation(run: run(status: status), applicationEvidence: .schemata(observation))
            )
        }
    }

    @Test("schemata survived: passed, the whole chain verifies uniquely")
    func schemataSurvived() throws {
        let record = try verify(schemataObservations(status: .passed, observation: schemataObservation))
        #expect(record.outcome == .survived)
    }

    @Test("schemata infrastructureFailure: passed but no HIT was ever recorded, so the chain does not verify")
    func schemataUnverified() throws {
        let record = try verify(schemataObservations(status: .passed, observation: makeInconsistentSchemataObservation()))
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("schemata infrastructureFailure: the build receipt could not be resolved at all")
    func schemataNoBuildReceipt() throws {
        let observation = SchemataExecutionObservation(
            expectation: schemataObservation.expectation, buildReceipt: nil, transcript: schemataObservation.transcript
        )
        let record = try verify(schemataObservations(status: .passed, observation: observation))
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("schemata killedByAssertion: failed, the whole chain verifies uniquely")
    func schemataKilled() throws {
        let record = try verify(schemataObservations(status: .failed, observation: schemataObservation))
        #expect(record.outcome == .killedByAssertion)
    }

    @Test("schemata coverage contradiction: coverage says uncovered but the chain proves a verified hit")
    func schemataCoverageContradiction() throws {
        let record = try verify(schemataObservations(
            status: .passed, observation: schemataObservation, coverage: CoverageObservation(mutatedLineWasExecuted: false, source: "xccov")
        ))
        #expect(record.outcome == .infrastructureFailure, "a verified hit contradicting coverage must never silently become .noCoverage")
    }

    @Test("schemata noCoverage: coverage says uncovered, chain unverified (no contradiction)")
    func schemataNoCoverageNoContradiction() throws {
        let record = try verify(schemataObservations(
            status: .passed, observation: makeInconsistentSchemataObservation(),
            coverage: CoverageObservation(mutatedLineWasExecuted: false, source: "xccov")
        ))
        #expect(record.outcome == .noCoverage)
    }

    // MARK: - Schemata chain: every stage's ambiguity/mismatch fails closed

    private func schemataOutcome(_ observation: SchemataExecutionObservation, status: TestRunStatus = .passed) throws -> MutationOutcome {
        try verify(schemataObservations(status: status, observation: observation)).outcome
    }

    /// One STARTUP (plus, if `includeHit`, a matching HIT) built from the
    /// shared fixture values, with exactly one field overridden — the
    /// compact building block every "wrong X never verifies" test below
    /// shares.
    private func startupObservation(
        runID: RunID = schemataFixtureRunID, sourceEmbeddingID: SHA256Digest = schemataFixtureSourceEmbeddingID,
        compilationUnitID: CompilationUnitID = schemataFixtureCompilationUnitID, token: SchemataSelectorToken = schemataFixtureToken,
        processID: Int32 = 4242, imageUUID: ImageUUID = schemataFixtureImageUUID, includeHit: Bool = false
    ) -> SchemataExecutionObservation {
        var records: [RuntimeEventRecord] = [.startup(RuntimeStartupEvent(
            runID: runID, sourceEmbeddingID: sourceEmbeddingID, compilationUnitID: compilationUnitID, token: token,
            processID: processID, imageUUID: imageUUID, runtimeABIVersion: 3
        ))]
        if includeHit {
            records.append(.hit(RuntimeHitEvent(
                runID: runID, sourceEmbeddingID: sourceEmbeddingID, compilationUnitID: compilationUnitID, token: token,
                processID: processID, sequence: 1, imageUUID: imageUUID, runtimeABIVersion: 3
            )))
        }
        return SchemataExecutionObservation(
            expectation: makeSchemataExpectation(), buildReceipt: makeSchemataFixtureReceipt(),
            transcript: RuntimeTranscript(protocolVersion: 3, records: records)
        )
    }

    @Test("wrong sourceEmbeddingID: a STARTUP/HIT pair for a different chunk build never verifies")
    func wrongSourceEmbeddingIDNeverVerifies() throws {
        let observation = startupObservation(sourceEmbeddingID: SHA256Digest.of("a-different-chunk-build"), includeHit: true)
        #expect(try schemataOutcome(observation) == .infrastructureFailure)
    }

    @Test("wrong compilationUnitID: a STARTUP event for a different compilation unit never verifies")
    func wrongCompilationUnitIDNeverVerifies() throws {
        let wrongUnit = CompilationUnitID.derive(
            projectIdentity: "proj", target: "App", module: "App", sourcePath: "Other.swift", lowererID: "bool-literal", lowererVersion: 1
        )
        #expect(try schemataOutcome(startupObservation(compilationUnitID: wrongUnit)) == .infrastructureFailure)
    }

    @Test("wrong selector token: a STARTUP event for a different mutation's token never verifies")
    func wrongSelectorTokenNeverVerifies() throws {
        let otherToken = SchemataSelectorToken(namespace: schemataFixtureToken.namespace, localIndex: schemataFixtureToken.localIndex + 1)
        #expect(try schemataOutcome(startupObservation(token: otherToken)) == .infrastructureFailure)
    }

    @Test("wrong runID: a STARTUP event from a different (stale/replayed) run never verifies")
    func wrongRunIDNeverVerifies() throws {
        #expect(try schemataOutcome(startupObservation(runID: RunID())) == .infrastructureFailure)
    }

    @Test("wrong image UUID: a STARTUP event naming an image the build receipt never proved for this unit never verifies")
    func wrongImageUUIDNeverVerifies() throws {
        let unprovenImage = ImageUUID(rawValue: String(repeating: "ff", count: 16))!
        #expect(try schemataOutcome(startupObservation(imageUUID: unprovenImage)) == .infrastructureFailure)
    }

    @Test("duplicate STARTUP: two candidate STARTUP events from the identical process is ambiguous, never resolved by picking one")
    func duplicateStartupNeverVerifies() throws {
        let base = schemataObservation
        // Same processID (4242, `schemataFixtureStartup`'s own default) as
        // `base`'s own STARTUP — a genuine same-process duplicate, the only
        // shape `SchemataChainError.duplicateStartup` should ever fire for.
        let duplicated = RuntimeEventRecord.startup(RuntimeStartupEvent(
            runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
            compilationUnitID: schemataFixtureCompilationUnitID,
            token: schemataFixtureToken, processID: 4242, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
        ))
        let observation = SchemataExecutionObservation(
            expectation: base.expectation, buildReceipt: base.buildReceipt,
            transcript: RuntimeTranscript(protocolVersion: 3, records: base.transcript.records + [duplicated])
        )
        #expect(try schemataOutcome(observation) == .infrastructureFailure)
    }

    /// The real shape this whole verifier design change exists for
    /// (reproduced live via a single deterministic re-run of
    /// `mut_09dcafc5fb6ba22d` against real swift-syntax, 3/3 repetitions):
    /// a single `mutantkit run` invocation whose test runner spawns more
    /// than one process for the identical build. Each process independently
    /// loads the same image and independently proves activation — this
    /// must verify, never be treated as ambiguous just because there is
    /// more than one raw STARTUP/HIT in the transcript.
    @Test("Two different processes each with their own clean STARTUP->HIT chain: legitimate multi-process multiplicity, verifies")
    func multiProcessMultiplicityVerifies() throws {
        let base = schemataObservation
        let secondProcess: [RuntimeEventRecord] = [
            .startup(RuntimeStartupEvent(
                runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
                compilationUnitID: schemataFixtureCompilationUnitID,
                token: schemataFixtureToken, processID: 9999, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
            )),
            .hit(RuntimeHitEvent(
                runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
                compilationUnitID: schemataFixtureCompilationUnitID,
                token: schemataFixtureToken, processID: 9999, sequence: 1, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
            ))
        ]
        let observation = SchemataExecutionObservation(
            expectation: base.expectation, buildReceipt: base.buildReceipt,
            transcript: RuntimeTranscript(protocolVersion: 3, records: base.transcript.records + secondProcess)
        )
        #expect(try schemataOutcome(observation) == .survived)
    }

    /// Three processes: two complete chains plus one that merely started up
    /// without ever hitting the mutation site (it loaded the image but the
    /// test(s) that process ran never touched this call site) — still
    /// proven, from the two that did.
    @Test("Two complete chains plus one STARTUP-only process: still proven")
    func multiProcessWithOneStartupOnlyStillVerifies() throws {
        let base = schemataObservation
        let secondProcess: [RuntimeEventRecord] = [
            .startup(RuntimeStartupEvent(
                runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
                compilationUnitID: schemataFixtureCompilationUnitID,
                token: schemataFixtureToken, processID: 9999, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
            )),
            .hit(RuntimeHitEvent(
                runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
                compilationUnitID: schemataFixtureCompilationUnitID,
                token: schemataFixtureToken, processID: 9999, sequence: 1, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
            ))
        ]
        let thirdProcessStartupOnly = RuntimeEventRecord.startup(RuntimeStartupEvent(
            runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
            compilationUnitID: schemataFixtureCompilationUnitID,
            token: schemataFixtureToken, processID: 7777, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
        ))
        let observation = SchemataExecutionObservation(
            expectation: base.expectation, buildReceipt: base.buildReceipt,
            transcript: RuntimeTranscript(protocolVersion: 3, records: base.transcript.records + secondProcess + [thirdProcessStartupOnly])
        )
        #expect(try schemataOutcome(observation) == .survived)
    }

    /// A HIT with no matching STARTUP in that same process is an
    /// inconsistent transcript, not something a *different* process'
    /// complete chain should be allowed to paper over.
    @Test("An orphan HIT (no matching STARTUP in that process) never verifies, even alongside a valid chain from another process")
    func orphanHitAlongsideValidChainNeverVerifies() throws {
        let base = schemataObservation
        let orphanHit = RuntimeEventRecord.hit(RuntimeHitEvent(
            runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
            compilationUnitID: schemataFixtureCompilationUnitID,
            token: schemataFixtureToken, processID: 9999, sequence: 1, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
        ))
        let observation = SchemataExecutionObservation(
            expectation: base.expectation, buildReceipt: base.buildReceipt,
            transcript: RuntimeTranscript(protocolVersion: 3, records: base.transcript.records + [orphanHit])
        )
        #expect(try schemataOutcome(observation) == .infrastructureFailure)
    }

    @Test("duplicate HIT: two candidate HIT events from the matched STARTUP's own process is ambiguous, never resolved by picking one")
    func duplicateHitNeverVerifies() throws {
        let base = schemataObservation
        let duplicated = RuntimeEventRecord.hit(RuntimeHitEvent(
            runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
            compilationUnitID: schemataFixtureCompilationUnitID,
            token: schemataFixtureToken, processID: 4242, sequence: 2, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
        ))
        let observation = SchemataExecutionObservation(
            expectation: base.expectation, buildReceipt: base.buildReceipt,
            transcript: RuntimeTranscript(protocolVersion: 3, records: base.transcript.records + [duplicated])
        )
        #expect(try schemataOutcome(observation) == .infrastructureFailure)
    }

    @Test("HIT from a different process than the matched STARTUP never verifies")
    func hitFromDifferentProcessNeverVerifies() throws {
        let base = startupObservation()
        let wrongProcessHit = RuntimeEventRecord.hit(RuntimeHitEvent(
            runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
            compilationUnitID: schemataFixtureCompilationUnitID,
            token: schemataFixtureToken, processID: 9999, sequence: 1, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
        ))
        let observation = SchemataExecutionObservation(
            expectation: base.expectation, buildReceipt: base.buildReceipt,
            transcript: RuntimeTranscript(protocolVersion: 3, records: base.transcript.records + [wrongProcessHit])
        )
        #expect(try schemataOutcome(observation) == .infrastructureFailure)
    }

    /// A HIT with literally zero matching STARTUP records anywhere in the
    /// transcript (not even a mismatched one) is still an inconsistent
    /// transcript, never "the mutation was simply never executed" —
    /// `.noStartup` is reserved for absence, `.orphanHit` for a HIT with
    /// no STARTUP proof behind it. Getting this wrong matters beyond the
    /// verifier itself: Group 2's `schemataIsolatedFallbackReason` treats
    /// `.noStartup` as fallback-eligible (this exact case must never
    /// qualify) but never `.orphanHit`.
    @Test("A HIT with zero matching STARTUP records anywhere never verifies as noStartup — it's an orphan HIT")
    func hitWithNoStartupAtAllIsOrphanNotNoStartup() throws {
        let orphanHit = RuntimeEventRecord.hit(RuntimeHitEvent(
            runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
            compilationUnitID: schemataFixtureCompilationUnitID,
            token: schemataFixtureToken, processID: 4242, sequence: 1, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
        ))
        let observation = SchemataExecutionObservation(
            expectation: makeSchemataExpectation(), buildReceipt: makeSchemataFixtureReceipt(),
            transcript: RuntimeTranscript(protocolVersion: 3, records: [orphanHit])
        )
        #expect(try schemataOutcome(observation) == .infrastructureFailure)
    }
}
