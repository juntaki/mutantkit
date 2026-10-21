import Foundation
import MutationModel

extension MutationRunner {
    // Extracted from this type: `internal` (not `fileprivate`) because
    // `MutationConfirmationCoordinator`, in its own file, takes this as a
    // parameter to every confirmation retest method.
    struct BaselineContext: Sendable {
        let record: BaselineRecord
        let productHash: String?
        let timeouts: TimeoutController
        /// Lines the baseline suite executed. `nil` means coverage was not
        /// measured; an empty-but-present map means every line was unreached.
        /// Either way the runner does not fabricate `noCoverage` from absence.
        let coverage: CoverageMap?
        /// Which tests covered which lines, when `selectCoveringTests` asked
        /// for the attribution and the adapter could produce one. `nil`
        /// means every mutant runs the full configured test list — the same
        /// safe fallback `coverage == nil` is for the `.noCoverage` check.
        let perTestCoverage: PerTestCoverageMap?
        /// Unmutated products kept for kill baseline controls, when needed.
        var control: BaselineControlSource?
    }

    enum BaselineAttempt {
        case established(BaselineContext)
        case failed(record: BaselineRecord, diagnosis: String)
    }

    /// Builds and tests the project unmutated.
    ///
    /// This happens in a sandbox like everything else, and not only to leave the
    /// working tree alone: the baseline's build product hash is what every
    /// mutant's is compared against, and a hash taken from a differently-shaped
    /// tree would not be comparable to one taken from a sandbox.
    func establishBaseline() async -> BaselineAttempt {
        if let preEstablishedBaseline {
            return Self.baselineAttempt(from: preEstablishedBaseline, configuration: configuration)
        }

        let started = Date()

        let sandbox: Sandbox
        do {
            sandbox = try await workspaces.createSandbox(id: Self.baselineSandboxID)
        } catch {
            return .failed(
                record: unusableBaseline(startedAt: started),
                diagnosis: "The baseline sandbox could not be created: \(error)"
            )
        }

        let attempt = await establishBaseline(in: sandbox.workspaceRoot, startedAt: started)
        // The control's products carry this sandbox's paths (`#filePath`), so
        // it lives as long as the control does.
        var control: BaselineControlSource?
        if case let .established(context) = attempt { control = context.control }
        await BaselineControlSource.retainOrDestroy(sandbox, control: control, workspaces: workspaces)
        return attempt
    }

    func establishBaseline(in sandbox: URL, startedAt: Date) async -> BaselineAttempt {
        let timeouts = TimeoutController(settings: configuration.timeouts)

        let artifact: BuildArtifact
        do {
            artifact = try await build.buildBaseline(in: sandbox)
        } catch let failure as BuildFailure {
            return .failed(
                record: unusableBaseline(startedAt: startedAt),
                diagnosis: "The project does not build unmutated: \(failure.diagnosis)"
            )
        } catch {
            return .failed(
                record: unusableBaseline(startedAt: startedAt),
                diagnosis: "The baseline build could not be run: \(error)"
            )
        }

        let control = await BaselineControlSource.establish(configuration.execution, from: artifact, workspaces: workspaces, test: test)

        let testStarted = Date()
        let run: TestRunResult
        do {
            run = try await test.runBaseline(
                artifact,
                in: sandbox,
                timeoutSeconds: timeouts.baselineLimitSeconds
            )
        } catch {
            await control?.teardown()
            return .failed(
                record: unusableBaseline(startedAt: startedAt, buildCommand: artifact.command),
                diagnosis: "The baseline test run could not be completed: \(error)"
            )
        }

        // The mutant limit scales the *test* duration, not build-plus-test: it is
        // handed to the test adapter, and a build that dominates the wall clock
        // would inflate every mutant's limit into uselessness.
        //
        // Measured wall clock, never the reported test duration. The limit bounds
        // a process, so it has to be derived from what that process actually
        // costs. A result bundle reports how long the assertions took — about a
        // tenth of a second for a small suite — while the command around them
        // spends half a minute booting, installing and launching a simulator.
        // Budgeting from the former gave killed mutants less time than the run
        // needs, so under load they were reported `timedOut` and dropped from the
        // score, and the same plan produced different numbers on consecutive runs.
        let testDuration = Date().timeIntervalSince(testStarted)

        let record = BaselineRecord(
            passed: run.status == .passed,
            testSummary: run.summary,
            durationSeconds: Date().timeIntervalSince(startedAt),
            buildProductHash: artifact.productHash,
            buildCommand: artifact.command,
            testCommand: run.command,
            buildDurationSeconds: testStarted.timeIntervalSince(startedAt),
            testDurationSeconds: testDuration
        )

        guard run.status == .passed else {
            await control?.teardown()
            return .failed(
                record: record,
                diagnosis: """
                The unmutated suite did not pass (\(run.status.rawValue)): \(run.diagnosis) Every \
                mutant is measured against this run, so nothing can be concluded until it is green.
                """
            )
        }

        // Coverage is read *before* the sandbox is destroyed — the codecov
        // files (or, for xcodebuild, the result bundle) live inside it. The
        // config flags are the source of truth: an adapter that *can*
        // measure coverage but was not asked to should not produce a map,
        // because the user has not been told the baseline would be
        // instrumented. A failed or partial read yields `nil`, which means
        // every mutant will be built and tested rather than guessed at.
        //
        // `selectCoveringTests` is tried first and, when it succeeds, its
        // union *is* the whole-suite coverage map — reading a separate
        // whole-run report would be a second, redundant read of the same
        // fact. `measureCoverage` on its own remains the lighter-weight
        // option: the `.noCoverage` fast path without paying for per-test
        // attribution.
        //
        // The per-test attribution pass is the most expensive thing the
        // baseline does on a real project (~85 minutes on the project this
        // tool was benchmarked against), and it is also the most stable:
        // it only changes when the source tree, test suite, toolchain, or
        // coverage configuration changes. So a `CoverageProfileCache` with
        // a context digest key is consulted *before* the adapter is asked
        // to re-measure. A hit skips the measurement entirely; a miss
        // measures as usual and stores the result back for the next run.
        // The baseline build and test above have already run either way —
        // the suite-must-pass gate and the timeout calibration cannot be
        // served from a cache.
        let measured = await BaselineCoverageMeasurement(
            configuration: configuration, cache: coverageCache, cacheKey: coverageCacheKey,
            operationalIssues: operationalIssues
        ).measure(
            with: test, against: artifact, in: sandbox, projectRoot: projectRoot,
            timeoutSeconds: timeouts.baselineLimitSeconds
        )
        let perTestCoverage = measured.perTestCoverage
        let coverage = measured.coverage

        // `record` above already carries everything but `profilingDurationSeconds`
        // — needed for the failure-path `guard` above, before coverage
        // measurement has happened at all. This second record is identical
        // except for that one field, built only once the baseline is known to
        // have passed and coverage measurement has been attempted.
        let recordWithProfiling = BaselineRecord(
            passed: record.passed,
            testSummary: record.testSummary,
            durationSeconds: record.durationSeconds,
            buildProductHash: record.buildProductHash,
            buildCommand: record.buildCommand,
            testCommand: record.testCommand,
            buildDurationSeconds: record.buildDurationSeconds,
            testDurationSeconds: record.testDurationSeconds,
            profilingDurationSeconds: measured.profilingDurationSeconds
        )

        return .established(BaselineContext(
            record: recordWithProfiling,
            productHash: artifact.productHash,
            timeouts: timeouts.recordingBaseline(durationSeconds: testDuration),
            coverage: coverage,
            perTestCoverage: perTestCoverage,
            control: control
        ))
    }

    /// Converts a `SharedBaselineEstablisher` result into this runner's own
    /// `BaselineAttempt` shape — the `preEstablishedBaseline` short-circuit
    /// in `establishBaseline()`'s only caller. `static`, not an instance
    /// method: it touches no runner state beyond `configuration` (passed
    /// explicitly), matching `BaselineContext`'s own construction in the
    /// non-injected path exactly (`timeouts.recordingBaseline`,
    /// `coverage`/`perTestCoverage` verbatim) so a mutant scored against an
    /// injected baseline is measured identically to one scored against a
    /// baseline this runner established itself.
    private static func baselineAttempt(
        from outcome: SharedBaselineEstablisher.Outcome, configuration: Configuration
    ) -> BaselineAttempt {
        switch outcome {
        case let .failed(record, diagnosis):
            return .failed(record: record, diagnosis: diagnosis)
        case let .established(shared):
            return .established(BaselineContext(
                record: shared.record,
                productHash: shared.record.buildProductHash,
                timeouts: TimeoutController(settings: configuration.timeouts)
                    .recordingBaseline(durationSeconds: shared.testDurationSeconds),
                coverage: shared.coverage,
                perTestCoverage: shared.perTestCoverage,
                control: shared.control
            ))
        }
    }

    private func unusableBaseline(startedAt: Date, buildCommand: CommandRecord? = nil) -> BaselineRecord {
        BaselineRecord(
            passed: false,
            // A baseline that never ran has no counts. Zeroes here would claim it
            // ran a suite of no tests, which is a different — and much less
            // alarming — statement than "we never got a baseline at all".
            testSummary: nil,
            durationSeconds: Date().timeIntervalSince(startedAt),
            buildProductHash: nil,
            buildCommand: buildCommand,
            testCommand: nil
        )
    }

    /// The report for a run that never legitimately started.
    ///
    /// Reconciling against the plan here would bury the one fact that matters
    /// under a `plannedMutationWithoutResult` for every mutation in the file. The
    /// baseline failed; nothing else was attempted, and the report says exactly
    /// that. `RunReport` withholds the score on its own once integrity fails.
    func failClosedReport(startedAt: Date, baseline: BaselineRecord, diagnosis: String) -> RunReport {
        RunReport(
            planID: plan.planID,
            startedAt: startedAt,
            finishedAt: Date(),
            projectRoot: projectRoot.path,
            toolchain: toolchain,
            baseline: baseline,
            ledger: ResultLedger<MutationResult>(),
            integrity: IntegrityReport(
                discovered: plan.discoveredCount,
                planned: plan.mutations.count,
                sourceApplied: 0,
                buildObserved: 0,
                buildFailures: 0,
                executed: 0,
                classified: 0,
                reported: 0,
                explicitlySkipped: plan.skipped.count,
                skippedByReason: SkipReasonCount.tally(plan.skipped),
                violations: [IntegrityViolation(kind: .baselineMismatch, detail: diagnosis)]
            )
        )
    }

    // MARK: - One mutant
}
