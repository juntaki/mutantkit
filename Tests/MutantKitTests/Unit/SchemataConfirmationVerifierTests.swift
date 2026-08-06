import Foundation
import MutationModel
import Testing

/// ADR-0006 Stage 3: schemata confirmations go through the exact same
/// `MutationVerdictVerifier.confirm` a real run would, never a
/// runner-side shortcut. Every case here pins that a confirmation must
/// prove its own independent STARTUP -> HIT chain — reusing the primary
/// run's own RunID, omitting the HIT, or reporting the wrong process/
/// image/compilation unit must never be credited, exactly as an unproven
/// primary observation never is.
@Suite("Schemata confirmation: verifier-only chain validation")
struct SchemataConfirmationVerifierTests {
    private static let enabledPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
        retestKilledMutants: true, confirmCrashKills: true, confirmTimedOutMutants: true
    )

    private func run(status: TestRunStatus, summary: TestOutcomeSummary? = nil, isBatchAttributedTimeout: Bool = false) -> TestRunResult {
        TestRunResult(
            status: status, summary: summary,
            command: CommandRecord(executable: "/usr/bin/xcrun", arguments: [], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: "diag:\(status.rawValue)", isBatchAttributedTimeout: isBatchAttributedTimeout
        )
    }

    private func verify(
        primary: SchemataExecutionObservation, primaryStatus: TestRunStatus, primarySummary: TestOutcomeSummary? = nil,
        confirmations: [ConfirmationObservation], policy: MutationVerdictVerifier.VerdictVerificationPolicy = enabledPolicy
    ) throws -> VerifiedMutationRecord {
        let point = try makeAnchoredPoint()
        let ref = PlannedMutationRef.forPoint(point, planID: "plan-confirm", workUnitID: "unit-confirm")
        let evidence = MutationEvidence(
            sourceBeforeHash: ContentHash.of("before"), sourceAfterHash: ContentHash.of("after"),
            sourceDiff: "--- a\n+++ b\n", buildProductHash: "h1", applicationEvidence: .schemata(primary)
        )
        let observations = MutationObservations(
            plannedMutation: ref,
            sourceApplication: .applied(evidence),
            build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
            test: SingleTestObservation(run: run(status: primaryStatus, summary: primarySummary), applicationEvidence: .schemata(primary)),
            confirmations: confirmations
        )
        return MutationVerdictVerifier.verify(observations, policy: policy)
    }

    // MARK: - confirmationRequirement

    @Test("confirmationRequirement: killedByAssertion with retestKilledMutants on requires .retestKilledMutant")
    func requirementForKillWhenEnabled() throws {
        let point = try makeAnchoredPoint()
        let ref = PlannedMutationRef.forPoint(point, planID: "plan-1", workUnitID: "unit-1")
        let primary = makeConsistentSchemataObservation()
        let testObservation = SingleTestObservation(
            run: run(status: .failed, summary: makeTestSummary(failed: 1)), applicationEvidence: .schemata(primary)
        )
        let observations = MutationObservations(
            plannedMutation: ref,
            sourceApplication: .applied(MutationEvidence(
                sourceBeforeHash: "b", sourceAfterHash: "a", sourceDiff: "d",
                buildProductHash: "h1", applicationEvidence: .schemata(primary)
            )),
            build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
            test: testObservation
        )
        #expect(
            MutationVerdictVerifier.confirmationRequirement(for: observations, policy: Self.enabledPolicy) == .retestKilledMutant
        )
    }

    @Test("confirmationRequirement: policy disables each confirmation type in turn")
    func requirementDisabledPerType() throws {
        let point = try makeAnchoredPoint()
        let ref = PlannedMutationRef.forPoint(point, planID: "plan-1", workUnitID: "unit-1")
        let primary = makeConsistentSchemataObservation()
        func observations(status: TestRunStatus) -> MutationObservations {
            let testObservation = SingleTestObservation(
                run: run(status: status, summary: makeTestSummary(failed: status == .failed ? 1 : 0)),
                applicationEvidence: .schemata(primary)
            )
            return MutationObservations(
                plannedMutation: ref,
                sourceApplication: .applied(MutationEvidence(
                    sourceBeforeHash: "b", sourceAfterHash: "a", sourceDiff: "d",
                    buildProductHash: "h1", applicationEvidence: .schemata(primary)
                )),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                test: testObservation
            )
        }
        let disabled = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: false, confirmCrashKills: false, confirmTimedOutMutants: false
        )
        #expect(MutationVerdictVerifier.confirmationRequirement(for: observations(status: .failed), policy: disabled) == .none)
        #expect(MutationVerdictVerifier.confirmationRequirement(for: observations(status: .crashed), policy: disabled) == .none)
        #expect(MutationVerdictVerifier.confirmationRequirement(for: observations(status: .timedOut), policy: disabled) == .none)
    }

    // MARK: - Assertion kill confirmation

    @Test("assertion kill + valid confirmation kill: killedByAssertion")
    func killWithValidConfirmation() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation()
        let record = try verify(
            primary: primary, primaryStatus: .failed, primarySummary: makeTestSummary(total: 2, failed: 1),
            confirmations: [ConfirmationObservation(
                kind: .kill, run: run(status: .failed, summary: makeTestSummary(total: 2, failed: 1)),
                schemataObservation: confirmation, originalFailingTests: makeTestSummary(total: 2, failed: 1).failingTests
            )]
        )
        #expect(record.outcome == .killedByAssertion)
    }

    @Test("assertion kill + confirmation pass: not killedByAssertion")
    func killWithPassingConfirmation() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation()
        let record = try verify(
            primary: primary, primaryStatus: .failed, primarySummary: makeTestSummary(total: 2, failed: 1),
            confirmations: [ConfirmationObservation(
                kind: .kill, run: run(status: .passed), schemataObservation: confirmation,
                originalFailingTests: makeTestSummary(total: 2, failed: 1).failingTests
            )]
        )
        #expect(record.outcome == .flaky)
    }

    @Test("assertion kill + confirmation chain missing (no HIT): not killedByAssertion")
    func killWithMissingConfirmationChain() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation(includeHit: false)
        let record = try verify(
            primary: primary, primaryStatus: .failed, primarySummary: makeTestSummary(total: 2, failed: 1),
            confirmations: [ConfirmationObservation(
                kind: .kill, run: run(status: .failed, summary: makeTestSummary(total: 2, failed: 1)),
                schemataObservation: confirmation, originalFailingTests: makeTestSummary(total: 2, failed: 1).failingTests
            )]
        )
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("assertion kill + duplicate confirmation STARTUP: not killedByAssertion")
    func killWithDuplicateConfirmationStartup() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation(duplicateStartup: true)
        let record = try verify(
            primary: primary, primaryStatus: .failed, primarySummary: makeTestSummary(total: 2, failed: 1),
            confirmations: [ConfirmationObservation(
                kind: .kill, run: run(status: .failed, summary: makeTestSummary(total: 2, failed: 1)),
                schemataObservation: confirmation, originalFailingTests: makeTestSummary(total: 2, failed: 1).failingTests
            )]
        )
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("assertion kill + duplicate confirmation HIT: not killedByAssertion")
    func killWithDuplicateConfirmationHit() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation(duplicateHit: true)
        let record = try verify(
            primary: primary, primaryStatus: .failed, primarySummary: makeTestSummary(total: 2, failed: 1),
            confirmations: [ConfirmationObservation(
                kind: .kill, run: run(status: .failed, summary: makeTestSummary(total: 2, failed: 1)),
                schemataObservation: confirmation, originalFailingTests: makeTestSummary(total: 2, failed: 1).failingTests
            )]
        )
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("assertion kill + stale RunID (confirmation reuses the primary run's own RunID): not killedByAssertion")
    func killWithStaleRunID() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation(runID: schemataFixtureRunID)
        let record = try verify(
            primary: primary, primaryStatus: .failed, primarySummary: makeTestSummary(total: 2, failed: 1),
            confirmations: [ConfirmationObservation(
                kind: .kill, run: run(status: .failed, summary: makeTestSummary(total: 2, failed: 1)),
                schemataObservation: confirmation, originalFailingTests: makeTestSummary(total: 2, failed: 1).failingTests
            )]
        )
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("assertion kill + wrong PID (STARTUP and HIT from different processes): not killedByAssertion")
    func killWithWrongPID() throws {
        let primary = makeConsistentSchemataObservation()
        let runID = RunID()
        let startup = RuntimeStartupEvent(
            runID: runID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID, compilationUnitID: schemataFixtureCompilationUnitID,
            token: schemataFixtureToken, processID: 1111, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
        )
        let hit = RuntimeHitEvent(
            runID: runID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID, compilationUnitID: schemataFixtureCompilationUnitID,
            token: schemataFixtureToken, processID: 2222, sequence: 1, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
        )
        let confirmation = SchemataExecutionObservation(
            expectation: SchemataRunExpectation(
                mutationID: schemataFixtureMutationID, compilationUnitID: schemataFixtureCompilationUnitID,
                sourceEmbeddingID: schemataFixtureSourceEmbeddingID, selectorToken: schemataFixtureToken, runID: runID
            ),
            buildReceipt: makeSchemataFixtureReceipt(),
            transcript: RuntimeTranscript(protocolVersion: 3, records: [.startup(startup), .hit(hit)])
        )
        let record = try verify(
            primary: primary, primaryStatus: .failed, primarySummary: makeTestSummary(total: 2, failed: 1),
            confirmations: [ConfirmationObservation(
                kind: .kill, run: run(status: .failed, summary: makeTestSummary(total: 2, failed: 1)),
                schemataObservation: confirmation, originalFailingTests: makeTestSummary(total: 2, failed: 1).failingTests
            )]
        )
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("assertion kill + wrong image UUID: not killedByAssertion")
    func killWithWrongImageUUID() throws {
        let primary = makeConsistentSchemataObservation()
        let confirmation = makeSchemataConfirmationObservation(imageUUID: ImageUUID(rawValue: String(repeating: "ff", count: 16))!)
        let record = try verify(
            primary: primary, primaryStatus: .failed, primarySummary: makeTestSummary(total: 2, failed: 1),
            confirmations: [ConfirmationObservation(
                kind: .kill, run: run(status: .failed, summary: makeTestSummary(total: 2, failed: 1)),
                schemataObservation: confirmation, originalFailingTests: makeTestSummary(total: 2, failed: 1).failingTests
            )]
        )
        #expect(record.outcome == .infrastructureFailure)
    }

    @Test("assertion kill + wrong compilationUnitID: not killedByAssertion")
    func killWithWrongCompilationUnitID() throws {
        let primary = makeConsistentSchemataObservation()
        let wrongUnit = CompilationUnitID.derive(
            projectIdentity: "proj", target: "App", module: "App", sourcePath: "Other.swift", lowererID: "bool-literal", lowererVersion: 1
        )
        let confirmation = makeSchemataConfirmationObservation(compilationUnitID: wrongUnit)
        let record = try verify(
            primary: primary, primaryStatus: .failed, primarySummary: makeTestSummary(total: 2, failed: 1),
            confirmations: [ConfirmationObservation(
                kind: .kill, run: run(status: .failed, summary: makeTestSummary(total: 2, failed: 1)),
                schemataObservation: confirmation, originalFailingTests: makeTestSummary(total: 2, failed: 1).failingTests
            )]
        )
        #expect(record.outcome == .infrastructureFailure)
    }
}
