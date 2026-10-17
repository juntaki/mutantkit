import Foundation
import MutationModel
import Testing

@Suite("Schemata qualification: a schemata measurement must really have run schemata")
struct SchemataQualificationTests {
    private func schemataResult(_ id: String) throws -> MutationResult {
        let observation = makeConsistentSchemataObservation()
        let point = try makeAnchoredPoint()
        let ref = PlannedMutationRef.forPoint(point, planID: "plan-1", workUnitID: "wu-1")
        let record = MutationVerdictVerifier.verify(
            MutationObservations(
                plannedMutation: ref,
                sourceApplication: .applied(makeEvidence(buildProductHash: "h1", applicationEvidence: .schemata(observation))),
                build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
                coverage: nil,
                test: SingleTestObservation(
                    run: TestRunResult(
                        status: .passed, summary: nil,
                        command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp"),
                        resultArtifactPath: nil, diagnosis: "ok", isBatchAttributedTimeout: false
                    ),
                    applicationEvidence: .schemata(observation), execution: wholeSuiteExecution
                )
            ),
            policy: .permissive
        )
        return try MutationResult.projected(from: record, point: point, planID: "plan-1", workUnitID: "wu-1", durationSeconds: 1)
    }

    private func isolatedResult() throws -> MutationResult {
        makeResult(point: try makeAnchoredPoint(), outcome: .survived)
    }

    private func report(_ strategy: ExecutionStrategyReport?, results: [MutationResult]) throws -> RunReport {
        let plan = makePlan(mutations: [try makeAnchoredPoint()])
        return RunReport(
            planID: plan.planID, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_100), projectRoot: plan.projectRoot, toolchain: makeToolchain(),
            baseline: makeBaseline(passed: true), ledger: makeLedger(results),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true),
            executionStrategy: strategy
        )
    }

    @Test("a run that really executed through schemata is valid")
    func validRun() throws {
        let strategy = ExecutionStrategyReport(requested: .schemata, effectiveCount: 1, fallbackCount: 0)
        let run = try report(strategy, results: [schemataResult("a")])
        #expect(SchemataQualification().violations(in: run).isEmpty)
    }

    @Test("a schemata run that silently ran everything isolated is invalid")
    func silentFallbackIsInvalid() throws {
        let strategy = ExecutionStrategyReport(
            requested: .schemata, effectiveCount: 0, fallbackCount: 1, fallbackReasonCounts: ["buildReceiptUnavailable": 1]
        )
        let run = try report(strategy, results: [isolatedResult()])
        let problems = SchemataQualification().violations(in: run)
        #expect(problems.contains { $0.contains("no mutation was executed through schemata") })
        #expect(problems.contains { $0.contains("buildReceiptUnavailable") })
        #expect(problems.contains { $0.contains("no result carries schemata-verified") })
    }

    @Test("a whole-run degradation is invalid")
    func degradationIsInvalid() throws {
        let strategy = ExecutionStrategyReport(
            requested: .schemata, effectiveCount: 0, fallbackCount: 1, degradationReason: "no usable runtime"
        )
        let problems = SchemataQualification().violations(in: try report(strategy, results: [isolatedResult()]))
        #expect(problems.contains { $0.contains("no usable runtime") })
    }

    @Test("an isolated run is not a schemata measurement")
    func isolatedRunIsInvalid() throws {
        let problems = SchemataQualification().violations(in: try report(nil, results: [isolatedResult()]))
        #expect(problems.contains { $0.contains("did not request schemata") })
    }

    @Test("fallbacks within the allowance are tolerated, shared-chunk build failures never are")
    func allowanceAndInfrastructureReasons() throws {
        let mixed = ExecutionStrategyReport(
            requested: .schemata, effectiveCount: 1, fallbackCount: 1, fallbackReasonCounts: ["activation.noStartup": 1]
        )
        let tolerated = try report(mixed, results: [schemataResult("a")])
        #expect(SchemataQualification(maximumUnexpectedFallbacks: 1).violations(in: tolerated).isEmpty)
        #expect(!SchemataQualification(maximumUnexpectedFallbacks: 0).violations(in: tolerated).isEmpty)

        let infrastructure = ExecutionStrategyReport(
            requested: .schemata, effectiveCount: 1, fallbackCount: 1, fallbackReasonCounts: ["sharedChunkBuildFailure": 1]
        )
        let broken = try report(infrastructure, results: [schemataResult("a")])
        let violations = SchemataQualification(maximumUnexpectedFallbacks: 5).violations(in: broken)
        #expect(violations.contains { $0.contains("sharedChunkBuildFailure") })
    }
}
