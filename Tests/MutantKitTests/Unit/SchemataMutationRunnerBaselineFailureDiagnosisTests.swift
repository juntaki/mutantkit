import Foundation
import MutationExecution
import MutationModel
import Testing

/// A failed schemata baseline must surface the observer's own account of
/// what happened, and the baseline record it was observed on.
///
/// Both were being discarded: `run()` re-derived "N of M tests failed" from
/// `record.testSummary` and threw only that string, so the established
/// baseline's `diagnosis` — the one sentence carrying the run's `status` and
/// the adapter's structured reason — never reached anyone, and the record
/// itself never left the runner at all. On the failure shape that actually
/// occurred in CI (a baseline whose suite ran nothing: `0 of 0`) the derived
/// sentence named neither what failed nor that nothing had run, and the
/// report showed an all-`nil` stand-in record in place of the real one.
@Suite("SchemataMutationRunner: a failed baseline keeps its own diagnosis and record")
struct SchemataMutationRunnerBaselineFailureDiagnosisTests {
    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(
        preEstablishedBaseline: SharedBaselineEstablisher.Outcome? = nil, adapter: FakeSchemataAdapter = FakeSchemataAdapter()
    ) async throws {
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: [], points: [:], originalSources: [:],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-baseline-diagnosis-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-baseline-diagnosis-scratch")
            ),
            timeouts: TimeoutSettings(baselineSeconds: 30), toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: .permissive, preEstablishedBaseline: preEstablishedBaseline
        )
        _ = try await runner.run()
    }

    private func baselineFailure(
        of outcome: SharedBaselineEstablisher.Outcome? = nil, adapter: FakeSchemataAdapter = FakeSchemataAdapter()
    ) async -> (BaselineRecord, String)? {
        do {
            try await run(preEstablishedBaseline: outcome, adapter: adapter)
            Issue.record("a baseline that did not pass must not let the run proceed")
            return nil
        } catch let error as SchemataMutationRunner.RunError {
            switch error {
            case let .baselineDidNotPass(record, diagnosis):
                #expect("\(error)".contains(diagnosis), "the error's own description must carry the diagnosis it was given")
                return (record, diagnosis)
            }
        } catch {
            Issue.record("expected a RunError, got \(error)")
            return nil
        }
    }

    /// The exact CI shape: a suite that ran no tests at all. The summary
    /// exists and is all zeroes, so the count-derived sentence *is*
    /// available — and must still lose to the establisher's own diagnosis,
    /// because "0 of 0 tests failed" describes a red suite and an empty one
    /// identically.
    @Test("A baseline that ran no tests throws the establisher's diagnosis, not the count-derived sentence")
    func zeroOfZeroBaselineKeepsTheRealDiagnosis() async throws {
        let record = BaselineRecord(
            passed: false,
            testSummary: TestOutcomeSummary(total: 0, passed: 0, failed: 0, failingTests: [], durationSeconds: 1.5),
            durationSeconds: 42, buildProductHash: "product-hash", buildCommand: nil, testCommand: nil
        )
        let diagnosis = "The unmutated suite did not pass (failed): no test bundle produced any result."

        let failure = try #require(await baselineFailure(of: .failed(record: record, diagnosis: diagnosis)))

        #expect(failure.1 == diagnosis)
        #expect(!failure.1.contains("0 of 0 tests failed"))
        // The record itself, not a stand-in: `SchemataRunOrchestration.merge`
        // attaches exactly this one to the degraded report, where an
        // all-`nil` synthesized record told a reader nothing about whether
        // the project had even built.
        #expect(failure.0.buildProductHash == "product-hash")
        #expect(failure.0.durationSeconds == 42)
    }

    /// The one case neither `establishBaseline` path throws from: an
    /// `.established(_)` whose record nevertheless says it did not pass.
    /// `SharedBaselineEstablisher` never produces one, but the type permits
    /// it and the run must still fail closed — with the counts, because here
    /// there is no observation left to quote.
    @Test("An .established baseline whose record did not pass still fails closed, from the counts")
    func establishedButFailedRecordStillFailsClosed() async throws {
        let record = BaselineRecord(
            passed: false,
            testSummary: TestOutcomeSummary(total: 7, passed: 5, failed: 2, failingTests: ["A/b"], durationSeconds: 1),
            durationSeconds: 3, buildProductHash: nil, buildCommand: nil, testCommand: nil
        )
        let outcome = SharedBaselineEstablisher.Outcome.established(
            EstablishedBaseline(record: record, testDurationSeconds: 1, perTestCoverage: nil, coverage: nil)
        )

        let failure = try #require(await baselineFailure(of: outcome))

        #expect(failure.1 == "2 of 7 tests failed")
    }

    /// The runner's own baseline path — the one taken when no baseline was
    /// pre-established for it. It words the failure exactly as
    /// `SharedBaselineEstablisher` does, from the same observation, rather
    /// than keeping a second phrasing of its own.
    @Test("A baseline this runner established itself throws the observed status and diagnosis")
    func selfEstablishedBaselineFailureCarriesTheObservation() async throws {
        let adapter = FakeSchemataAdapter()
        adapter.baselineResult = TestRunResult(
            status: .crashed, summary: nil, command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "."),
            resultArtifactPath: nil, diagnosis: "The runner died before reporting any test."
        )

        let failure = try #require(await baselineFailure(adapter: adapter))

        #expect(failure.1.contains("(crashed)"), "the observed status must survive: \(failure.1)")
        #expect(failure.1.contains("The runner died before reporting any test."))
        #expect(failure.0.passed == false)
        #expect(failure.0.testCommand?.executable == "swift", "the record must be the one this run produced")
    }
}
