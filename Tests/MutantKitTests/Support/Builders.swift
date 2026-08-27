import Foundation
@testable import MutationModel
import SwiftCoreOperators

/// Test-only convenience for the many acceptance tests written before the
/// schemata backend existed, when `MutationEvidence` only ever carried an
/// isolated-mode `ActivationEvidence` directly. `nil` for a `.schemata`
/// result, exactly as it would have been absent before this field existed —
/// deliberately not a production API: `MutationApplicationEvidence`'s own
/// doc comment explains why production code must switch on the case instead.
extension MutationApplicationEvidence {
    var isolatedActivation: ActivationEvidence? {
        if case let .isolated(activation) = self { activation } else { nil }
    }
}

// MARK: - Plan and run scaffolding

//
// Integrity tests need a whole run's worth of objects to exercise one
// invariant. These builders keep each test down to the single field it is
// actually about, so a reader can see the property being protected instead of
// twenty lines of unrelated setup.

func makeToolchain() -> ToolchainFingerprint {
    ToolchainFingerprint(
        toolVersion: "0.1.0",
        toolCommitSHA: "0000000000000000000000000000000000000000",
        swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2",
        xcodeVersion: nil
    )
}

func makeTestSummary(total: Int = 10, passed: Int = 10, failed: Int = 0) -> TestOutcomeSummary {
    TestOutcomeSummary(
        total: total,
        passed: passed,
        failed: failed,
        failingTests: failed > 0 ? ["ExampleTests/testSomething()"] : [],
        durationSeconds: 1.5
    )
}

func makeBaseline(passed: Bool = true) -> BaselineRecord {
    BaselineRecord(
        passed: passed,
        testSummary: passed ? makeTestSummary() : makeTestSummary(passed: 9, failed: 1),
        durationSeconds: 12,
        buildProductHash: ContentHash.of("baseline-binary"),
        buildCommand: nil,
        testCommand: nil
    )
}

func makePlan(
    mutations: [MutationPoint],
    skipped: [SkippedMutation] = [],
    sourceFileHashes: [String: String] = [:]
) -> MutationPlan {
    MutationPlan(
        planID: "plan-0001",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        projectRoot: "/tmp/project",
        toolchain: makeToolchain(),
        configurationHash: Configuration().configurationHash,
        sourceFileHashes: sourceFileHashes,
        mutations: mutations,
        skipped: skipped,
        operators: [
            BoolLiteralInversionOperator.descriptor,
            RelationalOperatorReplacementOperator.descriptor
        ]
    )
}

/// Evidence that satisfies `provesSourceApplication`: distinct hashes and a
/// non-empty diff.
///
/// `applicationEvidence` overrides `activation` when both are supplied —
/// present so a caller building a `.schemata(...)` case (which `activation`
/// cannot express, since it only wraps `ActivationEvidence` for `.isolated`)
/// can still use this builder instead of constructing `MutationEvidence`
/// directly. Since `MutationVerdictVerifier` cross-checks this evidence's
/// own `applicationEvidence` against `SingleTestObservation`'s, callers
/// building both from the same fixture should keep them identical.
func makeEvidence(
    buildProductHash: String? = ContentHash.of("mutant-binary"),
    activation: ActivationEvidence? = nil,
    applicationEvidence: MutationApplicationEvidence? = nil
) -> MutationEvidence {
    MutationEvidence(
        sourceBeforeHash: ContentHash.of("before"),
        sourceAfterHash: ContentHash.of("after"),
        sourceDiff: "--- a/Sources/Example.swift\n+++ b/Sources/Example.swift\n@@ -1,1 +1,1 @@\n-true\n+false\n",
        buildProductHash: buildProductHash,
        applicationEvidence: applicationEvidence ?? activation.map(MutationApplicationEvidence.isolated)
    )
}

// MARK: - Schemata fixtures (ADR-0006 Stage 2: raw observations only)

let schemataFixtureCompilationUnitID = CompilationUnitID.derive(
    projectIdentity: "proj", target: "App", module: "App", sourcePath: "Widget.swift", lowererID: "bool-literal", lowererVersion: 1
)
let schemataFixtureBuildTarget = BuildTargetIdentity(projectIdentity: "proj", targetName: "App", moduleName: "App")
let schemataFixtureSourceEmbeddingID = SHA256Digest.of("artifact-abc")
let schemataFixtureImageUUID = ImageUUID(rawValue: String(repeating: "aa", count: 16))!
let schemataFixtureToken = SchemataSelectorToken(namespace: 42, localIndex: 3)
let schemataFixtureMutationID = MutationID(rawValue: "mut_deadbeefdeadbeef")
let schemataFixtureRunID = RunID()

/// A real, self-consistent `SchemataBuildReceipt` naming exactly one
/// compilation unit and one built image containing it — the fixture every
/// schemata evidence builder below shares, since `verifySchemataChain`
/// requires a real receipt to resolve the unit-to-image step at all.
func makeSchemataFixtureReceipt() -> SchemataBuildReceipt {
    let unit = CompilationUnitReceipt(
        compilationUnitID: schemataFixtureCompilationUnitID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
        buildTarget: schemataFixtureBuildTarget
    )
    let image = try! BuiltImageReceipt(
        buildTarget: schemataFixtureBuildTarget, binaryPath: "/build/App", contentHash: SHA256Digest.of("app-binary"),
        slices: [BuiltImageSlice(architecture: BuiltArchitectureIdentity(cpuType: 0x0100_000C, cpuSubtype: 0), imageUUID: schemataFixtureImageUUID)]
    )
    return try! SchemataBuildReceipt(
        planID: "plan-1", workUnitID: "wu-1", chunkID: "chunk-1", toolchainHash: SHA256Digest.of("toolchain"),
        buildArgumentsHash: SHA256Digest.of("args"), runtimeABIVersion: 3, images: [image], compilationUnits: [unit]
    )
}

private func schemataFixtureStartup(processID: Int32 = 4242) -> RuntimeStartupEvent {
    RuntimeStartupEvent(
        runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID, compilationUnitID: schemataFixtureCompilationUnitID,
        token: schemataFixtureToken, processID: processID, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
    )
}

private func schemataFixtureHit(processID: Int32 = 4242, sequence: UInt64 = 1) -> RuntimeHitEvent {
    RuntimeHitEvent(
        runID: schemataFixtureRunID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID, compilationUnitID: schemataFixtureCompilationUnitID,
        token: schemataFixtureToken, processID: processID, sequence: sequence, imageUUID: schemataFixtureImageUUID, runtimeABIVersion: 3
    )
}

func makeSchemataExpectation(mutationID: MutationID = schemataFixtureMutationID) -> SchemataRunExpectation {
    SchemataRunExpectation(
        mutationID: mutationID, compilationUnitID: schemataFixtureCompilationUnitID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID,
        selectorToken: schemataFixtureToken, runID: schemataFixtureRunID
    )
}

/// A `SchemataExecutionObservation` whose real build receipt and transcript
/// together prove a unique STARTUP -> HIT chain —
/// `MutationVerdictVerifier.verifySchemataChain` succeeds against this.
func makeConsistentSchemataObservation() -> SchemataExecutionObservation {
    SchemataExecutionObservation(
        expectation: makeSchemataExpectation(), buildReceipt: makeSchemataFixtureReceipt(),
        transcript: RuntimeTranscript(protocolVersion: 3, records: [.startup(schemataFixtureStartup()), .hit(schemataFixtureHit())])
    )
}

/// The same fixture as `makeConsistentSchemataObservation()`, but with no
/// HIT ever recorded — `verifySchemataChain` throws `.nonUniqueHit` (zero
/// candidates).
func makeInconsistentSchemataObservation() -> SchemataExecutionObservation {
    SchemataExecutionObservation(
        expectation: makeSchemataExpectation(), buildReceipt: makeSchemataFixtureReceipt(),
        transcript: RuntimeTranscript(protocolVersion: 3, records: [.startup(schemataFixtureStartup())])
    )
}

/// A genuinely independent confirmation observation — its own fresh
/// `RunID` by default (never `schemataFixtureRunID`, the primary
/// observation's), with every other field independently overridable so a
/// test can build exactly one broken confirmation chain at a time (a
/// stale/reused RunID, a duplicate STARTUP/HIT, a wrong PID/image/unit, or
/// no HIT at all).
func makeSchemataConfirmationObservation(
    runID: RunID = RunID(), processID: Int32 = 5252, imageUUID: ImageUUID = schemataFixtureImageUUID,
    compilationUnitID: CompilationUnitID = schemataFixtureCompilationUnitID, includeHit: Bool = true,
    duplicateStartup: Bool = false, duplicateHit: Bool = false
) -> SchemataExecutionObservation {
    let startup = RuntimeStartupEvent(
        runID: runID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID, compilationUnitID: compilationUnitID,
        token: schemataFixtureToken, processID: processID, imageUUID: imageUUID, runtimeABIVersion: 3
    )
    var records: [RuntimeEventRecord] = [.startup(startup)]
    if duplicateStartup {
        // Same `processID` as the first STARTUP above — a *different*
        // process independently starting up is legitimate multi-process
        // multiplicity (`VerifiedSchemataChain`'s own doc comment), not a
        // duplicate; only two STARTUPs from the identical process violate
        // the runtime's own at-most-once contract.
        records.append(.startup(RuntimeStartupEvent(
            runID: runID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID, compilationUnitID: compilationUnitID,
            token: schemataFixtureToken, processID: processID, imageUUID: imageUUID, runtimeABIVersion: 3
        )))
    }
    if includeHit {
        let hit = RuntimeHitEvent(
            runID: runID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID, compilationUnitID: compilationUnitID,
            token: schemataFixtureToken, processID: processID, sequence: 1, imageUUID: imageUUID, runtimeABIVersion: 3
        )
        records.append(.hit(hit))
        if duplicateHit {
            records.append(.hit(RuntimeHitEvent(
                runID: runID, sourceEmbeddingID: schemataFixtureSourceEmbeddingID, compilationUnitID: compilationUnitID,
                token: schemataFixtureToken, processID: processID, sequence: 2, imageUUID: imageUUID, runtimeABIVersion: 3
            )))
        }
    }
    return SchemataExecutionObservation(
        expectation: SchemataRunExpectation(
            mutationID: schemataFixtureMutationID, compilationUnitID: schemataFixtureCompilationUnitID,
            sourceEmbeddingID: schemataFixtureSourceEmbeddingID, selectorToken: schemataFixtureToken, runID: runID
        ),
        buildReceipt: makeSchemataFixtureReceipt(), transcript: RuntimeTranscript(protocolVersion: 3, records: records)
    )
}

/// Builds a `MutationResult` with an arbitrary, caller-chosen outcome for
/// tests that exercise reporters/integrity/sharding rather than the
/// verifier itself. Goes through the real `VerdictProof`/
/// `VerifiedMutationRecord`/`MutationResult.projected` path (via
/// `@testable import`, since `VerifiedMutationRecord` has no public
/// initializer by design — ADR-0006 Stage 1) so a fabricated result is
/// still shaped exactly like a real verified one, just with the proof case
/// picked directly from `outcome` instead of derived from observations.
func makeResult(
    point: MutationPoint,
    outcome: MutationOutcome,
    evidence: MutationEvidence? = makeEvidence(
        activation: .buildProductDiffersFromBaseline(
            mutantHash: ContentHash.of("mutant-binary"),
            baselineHash: ContentHash.of("baseline-binary")
        )
    ),
    testSummary: TestOutcomeSummary? = makeTestSummary(),
    diagnosis: String = "test diagnosis",
    planID: String = "plan-0001",
    workUnitID: String = "plan-0001",
    durationSeconds: Double = 2,
    buildDurationSeconds: Double? = nil,
    testDurationSeconds: Double? = nil,
    confirmationDurationSeconds: Double? = nil
) -> MutationResult {
    let ref = PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID)
    let proof: VerdictProof = switch outcome {
    case .killedByAssertion, .killedByCrash, .verifiedTimeout, .survived:
        .executed(ExecutedMutationProof(
            mutationRef: ref, outcome: outcome, evidence: evidence ?? makeEvidence(), testSummary: testSummary, diagnosis: diagnosis
        ))
    case .noCoverage:
        .noCoverage(NoCoverageProof(
            mutationRef: ref, sourceApplication: evidence ?? makeEvidence(), coverageSource: "test-coverage", diagnosis: diagnosis
        ))
    case .unviable:
        .unviable(BuildFailureProof(mutationRef: ref, diagnosis: diagnosis, evidence: evidence))
    default:
        .excluded(ExclusionProof(mutationRef: ref, outcome: outcome, diagnosis: diagnosis))
    }
    let record = VerifiedMutationRecord(mutationRef: ref, proof: proof, verificationVersion: MutationVerdictVerifier.currentVersion)
    // swiftlint:disable:next force_try
    return try! MutationResult.projected(
        from: record, point: point, planID: planID, workUnitID: workUnitID, durationSeconds: durationSeconds,
        buildDurationSeconds: buildDurationSeconds, testDurationSeconds: testDurationSeconds,
        confirmationDurationSeconds: confirmationDurationSeconds
    )
}

private func makeCommand() -> CommandRecord {
    CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/tmp")
}

/// Builds `MutationObservations` that `MutationVerdictVerifier.verify`
/// actually classifies to `outcome` — for tests exercising
/// `MutationResultCache`/`CheckpointStore`, which now store and re-verify
/// raw observations rather than an already-decided `MutationResult`
/// (ADR-0006 Stage 1, second review round). Only covers the outcomes the
/// verifier can actually produce from observations — `.baselineMismatch`
/// and `.skipped` are never emitted by `verify` itself (both are set
/// elsewhere: a failed baseline invalidates a whole run in
/// `IntegrityChecker`, and a skip is a planning-time decision that never
/// reaches the runner at all), so there is no observation shape left to
/// build for either.
func makeObservations(
    point: MutationPoint, outcome: MutationOutcome, planID: String = "plan-0001", workUnitID: String = "plan-0001"
) -> MutationObservations {
    let ref = PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID)
    let provenActivation: MutationApplicationEvidence = .isolated(.buildProductDiffersFromBaseline(
        mutantHash: ContentHash.of("mutant-binary"), baselineHash: ContentHash.of("baseline-binary")
    ))
    let evidence = makeEvidence(activation: .buildProductDiffersFromBaseline(
        mutantHash: ContentHash.of("mutant-binary"), baselineHash: ContentHash.of("baseline-binary")
    ))

    func run(_ status: TestRunStatus) -> TestRunResult {
        TestRunResult(status: status, summary: nil, command: makeCommand(), resultArtifactPath: nil, diagnosis: "test diagnosis")
    }

    switch outcome {
    case .survived:
        return MutationObservations(
            plannedMutation: ref, sourceApplication: .applied(evidence),
            build: BuildObservation(outcome: .succeeded(buildProductHash: ContentHash.of("mutant-binary"), command: makeCommand())),
            test: SingleTestObservation(run: run(.passed), applicationEvidence: provenActivation)
        )
    case .killedByAssertion:
        return MutationObservations(
            plannedMutation: ref, sourceApplication: .applied(evidence),
            build: BuildObservation(outcome: .succeeded(buildProductHash: ContentHash.of("mutant-binary"), command: makeCommand())),
            test: SingleTestObservation(run: run(.failed), applicationEvidence: provenActivation)
        )
    case .killedByCrash:
        return MutationObservations(
            plannedMutation: ref, sourceApplication: .applied(evidence),
            build: BuildObservation(outcome: .succeeded(buildProductHash: ContentHash.of("mutant-binary"), command: makeCommand())),
            test: SingleTestObservation(run: run(.crashed), applicationEvidence: provenActivation)
        )
    case .noCoverage:
        return MutationObservations(
            plannedMutation: ref, sourceApplication: .applied(evidence),
            coverage: CoverageObservation(mutatedLineWasExecuted: false, source: "test-coverage")
        )
    case .verifiedTimeout:
        return MutationObservations(
            plannedMutation: ref, sourceApplication: .applied(evidence),
            build: BuildObservation(outcome: .succeeded(buildProductHash: ContentHash.of("mutant-binary"), command: makeCommand())),
            test: SingleTestObservation(run: run(.timedOut), applicationEvidence: provenActivation),
            confirmations: [ConfirmationObservation(
                kind: .timeout, run: run(.timedOut), activation: .buildProductDiffersFromBaseline(
                    mutantHash: ContentHash.of("mutant-binary"), baselineHash: ContentHash.of("baseline-binary")
                ), confirmingBuildProductHash: ContentHash.of("mutant-binary")
            )]
        )
    case .flaky:
        return MutationObservations(
            plannedMutation: ref, sourceApplication: .applied(evidence),
            build: BuildObservation(outcome: .succeeded(buildProductHash: ContentHash.of("mutant-binary"), command: makeCommand())),
            test: SingleTestObservation(run: run(.failed), applicationEvidence: provenActivation),
            confirmations: [ConfirmationObservation(kind: .kill, run: run(.passed), originalFailingTests: ["X/y()"])]
        )
    case .timedOut:
        return MutationObservations(
            plannedMutation: ref, sourceApplication: .applied(evidence),
            build: BuildObservation(outcome: .succeeded(buildProductHash: ContentHash.of("mutant-binary"), command: makeCommand())),
            test: SingleTestObservation(run: run(.timedOut), applicationEvidence: provenActivation)
        )
    case .unviable:
        return MutationObservations(
            plannedMutation: ref, sourceApplication: .applied(evidence),
            build: BuildObservation(outcome: .failed(kind: .compilationError, diagnosis: "does not compile", command: makeCommand()))
        )
    case .notApplied:
        return MutationObservations(plannedMutation: ref, sourceApplication: .notApplied(diagnosis: "anchor rejected"))
    case .infrastructureFailure:
        return MutationObservations(plannedMutation: ref, infrastructureFailureDiagnosis: "infrastructure failure")
    case .baselineMismatch, .skipped:
        preconditionFailure("\(outcome) is never emitted by MutationVerdictVerifier.verify — see this function's doc comment")
    }
}

/// Builds a `ResultLedger<MutationResult>` from an array for tests that
/// call `IntegrityChecker.check`/`PlanSharding.merge` directly rather than
/// through `makeReport`. `try!`: these are fixtures the test itself
/// controls, so a duplicate `mutationRef` here is a bug in the test, not a
/// case to handle gracefully.
func makeLedger(_ results: [MutationResult]) -> ResultLedger<MutationResult> {
    var ledger = ResultLedger<MutationResult>()
    for result in results {
        // swiftlint:disable:next force_try
        try! ledger.insert(result)
    }
    return ledger
}

func makeReport(
    plan: MutationPlan,
    results: [MutationResult],
    baselinePassed: Bool = true
) -> RunReport {
    RunReport(
        planID: plan.planID,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        finishedAt: Date(timeIntervalSince1970: 1_700_000_100),
        projectRoot: plan.projectRoot,
        toolchain: makeToolchain(),
        baseline: makeBaseline(passed: baselinePassed),
        ledger: makeLedger(results),
        integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: baselinePassed)
    )
}

/// A single real, fully-anchored point — the common starting material for
/// integrity tests, which care about the surrounding record rather than the
/// mutation itself.
func makeAnchoredPoint(file: String = "Sources/Example.swift") throws -> MutationPoint {
    let source = """
    struct Example {
        func isReady() -> Bool { return true }
    }
    """
    let points = try discover(source, path: file, using: Operators.boolLiteral)
    return points[0]
}

// MARK: - Deliberate corruption

//
// Discovery cannot produce a broken point, which is the whole idea — so tests
// that need one have to build it by hand from a real point.

extension MutationPoint {
    func with(
        id: MutationID? = nil,
        utf8Range: ByteRange? = nil,
        occurrenceIndex: Int? = nil,
        operatorVersion: Int? = nil,
        replacementText: String? = nil
    ) -> MutationPoint {
        MutationPoint(
            id: id ?? self.id,
            file: file,
            enclosingDeclaration: enclosingDeclaration,
            operatorID: operatorID,
            operatorVersion: operatorVersion ?? self.operatorVersion,
            occurrenceIndex: occurrenceIndex ?? self.occurrenceIndex,
            utf8Range: utf8Range ?? self.utf8Range,
            originalText: originalText,
            replacementText: replacementText ?? self.replacementText,
            prefixTokenFingerprint: prefixTokenFingerprint,
            suffixTokenFingerprint: suffixTokenFingerprint,
            sourceFileHash: sourceFileHash,
            expectedSyntaxKind: expectedSyntaxKind,
            confidence: confidence,
            executionMode: executionMode,
            line: line,
            column: column
        )
    }
}
