import Foundation
import MutationExecution
import MutationModel

//
// Extracted from `XcodeBuildAdapter.swift` as part of this project's
// internal execution-engine restructuring (see its own, private planning
// notes, not part of this public repo, for the full rationale). Collapses
// the shared "build
// `test-without-building` arguments, launch via `ProcessSupervisor.run`,
// handle launch-failure/timeout" shape `runTestsOnDestination`,
// `runSchemataTokenOnDestination` (Step 3, `runSingle`), and
// `runBatchOnDestination` (Step 4, `runBatch`) each carried a near-duplicate
// copy of.
//
// Classification (`XCResultAdapter.classify`) is deliberately NOT owned by
// `runSingle` — it is supplied by each caller as a `classify` closure. That is
// what lets the plan's §5.4 asymmetry survive unchanged: the schemata path
// wraps its own classify call in `GateTimingRecorder` marks
// (`token.xcresultClassify`), the isolated path has no such mark, and
// `expectedTestCount` is meaningful only to the isolated path's own
// `XCResultAdapter.classify` call. Moving classification inside this type
// would force one shared call shape onto two callers whose classify
// invocations already differ in exactly those two ways — this preserves both
// differences by construction, not by convention. `runBatch` is different:
// it has exactly one caller shape (`runBatchOnDestination`, itself the only
// caller of `runBatchTests`/`runSchemataTokenBatch`'s shared batch plumbing)
// with no per-caller classify variation and no `GateTimingRecorder` marks at
// all on the batch path (§5.4) — so `runBatch` owns its own `resultReader`
// and calls `classifyBatch` directly, rather than taking a closure it has
// only one real shape for.
//
// Uses `ProcessSupervisor.run` directly (not the injectable `processRunner`
// seam `XcodeSchemeResolver`/`StaleAppUninstaller` use) — see plan §5.2:
// every real `xcodebuild` invocation already used this seam, passing
// `terminationGracePeriodSeconds`, and switching seams here would be a real
// behavior change (losing grace-period control), not a pure move.
//
// No behavior change: every branch, diagnosis string, and argument below is
// identical to the code this replaced. No unit test reaches this type
// directly (plan §4's stated coverage gap) — verified by a manual
// side-by-side diff against the pre-extraction bodies of
// `runTestsOnDestination`/`runSchemataTokenOnDestination`/
// `runBatchOnDestination`, backed by `swift build --build-tests` and (for
// Step 3) the two `XcodeBuildAdapterUninstallFailureTests` launch-suppression
// tests, which prove the still-unmoved uninstall choke point never reaches
// this type at all on the `.failed` branch. `runBatch` (Step 4) has no fast
// test of its own — see plan §6.4's coverage-gap note — so it was kept the
// most literal possible cut-and-paste, per the plan's own recommendation for
// this step, rather than an opportunity for further cleanup.
//

/// The "launch `xcodebuild test-without-building`, handle a launch failure
/// or timeout" shape shared by the isolated and schemata-token test paths.
/// See the file's own header comment for why classification stays a
/// caller-supplied closure rather than a method on this type.
struct XCTestInvocationService: Sendable {
    /// How every `xcodebuild` invocation this type makes is spawned — see
    /// this file's own header comment for why this stays the direct
    /// `ProcessSupervisor.run` seam, not the injectable `processRunner`.
    let terminationGracePeriodSeconds: Double

    /// Only `runBatch` reads this — `runSingle`'s callers each classify with
    /// their own `XCResultAdapter` (the adapter's own `resultReader`
    /// property, unmoved), via the `classify` closure. A second, identically
    /// constructed (`XCResultAdapter()`, the same no-argument default the
    /// adapter itself uses) instance here is a value-type duplication with
    /// no observable difference from sharing one, since the type holds no
    /// stored state beyond its own fixed `xcresulttool` timeout.
    let resultReader: XCResultAdapter

    /// Runs one already-built `xcodebuild test-without-building` invocation
    /// (`arguments`, built by the caller via
    /// `XcodeBuildAdapter.testWithoutBuildingArguments` — kept a caller-side
    /// call, not a parameter of this method, purely to stay under this
    /// project's `function_parameter_count` ceiling), classifying the result
    /// via `classify` once the invocation itself neither failed to launch nor
    /// timed out.
    ///
    /// The caller is responsible for: resolving `xctestrunPath` (including
    /// the "no `.xctestrun` at all" early return — unchanged at each call
    /// site, see plan §6.3) before building `arguments`, and supplying
    /// `classify` with whatever `GateTimingRecorder` wrapping and
    /// `expectedTestCount` its own path needs. Clearing/creating
    /// `resultBundle`'s own directory beforehand is done here, since both
    /// callers did it identically.
    func runSingle(
        arguments: [String],
        resultBundle: URL,
        timeoutSeconds: Double,
        timeoutDiagnosis: String,
        in workspace: URL,
        classify: @Sendable () async -> XCResultAdapter.Outcome
    ) async -> TestRunResult {
        // xcodebuild refuses to overwrite an existing bundle, and a retry must not
        // fail for that reason alone.
        try? FileManager.default.removeItem(at: resultBundle)
        try? FileManager.default.createDirectory(
            at: resultBundle.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcodebuild,
                arguments: arguments,
                workingDirectory: workspace,
                timeoutSeconds: timeoutSeconds,
                terminationGracePeriodSeconds: terminationGracePeriodSeconds
            )
        } catch {
            return TestRunResult(
                status: .infrastructureFailure,
                summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild,
                    arguments: arguments,
                    workingDirectory: workspace,
                    result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "Could not launch xcodebuild: \(error)"
            )
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcodebuild,
            arguments: arguments,
            workingDirectory: workspace,
            result: result
        )

        // The timeout is the one outcome the bundle cannot describe: a killed run
        // leaves a partial bundle, or none. The supervisor's verdict is the fact.
        if result.timedOut {
            return TestRunResult(
                status: .timedOut,
                summary: nil,
                command: command,
                resultArtifactPath: FileManager.default.fileExists(atPath: resultBundle.path)
                    ? resultBundle : nil,
                diagnosis: timeoutDiagnosis
            )
        }

        // Everything else comes from the bundle, including success. xcodebuild's
        // exit code is deliberately not consulted: it reports 65 both for a failing
        // test and for a runner that never started, and only the bundle can tell
        // those apart.
        let outcome = await classify()

        return TestRunResult(
            status: outcome.status,
            summary: outcome.summary,
            command: command,
            resultArtifactPath: FileManager.default.fileExists(atPath: resultBundle.path)
                ? resultBundle : nil,
            diagnosis: outcome.diagnosis
        )
    }

    /// Runs one already-built batch `xcodebuild test-without-building`
    /// invocation (`arguments`, built by the caller — see this file's own
    /// header comment for why, unlike `runSingle`, there is no shared pure
    /// static to call for the batch shape: the native-timeout-allowance
    /// argument injection is specific to this one call path and was never
    /// shared with anything else) against every `configurationTestIdentifiers`
    /// key, classifying via `resultReader.classifyBatch` directly.
    ///
    /// Deliberately does **not** remove `resultBundle` before creating its
    /// parent directory — unlike `runSingle`. Preserved exactly: the
    /// original `runBatchOnDestination` never did either, since each batch's
    /// result bundle path is already a fresh, per-call UUID, so no stale
    /// bundle at that exact path could exist to collide with.
    func runBatch(
        arguments: [String],
        resultBundle: URL,
        timeoutSeconds: Double,
        configurationTestIdentifiers: [String: [String]],
        in workspace: URL
    ) async -> [String: TestRunResult] {
        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcodebuild,
                arguments: arguments,
                workingDirectory: workspace,
                timeoutSeconds: timeoutSeconds,
                terminationGracePeriodSeconds: terminationGracePeriodSeconds
            )
        } catch {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild, arguments: arguments, workingDirectory: workspace, result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "Could not launch xcodebuild for the batch: \(error)"
            )
            return Dictionary(uniqueKeysWithValues: configurationTestIdentifiers.keys.map { ($0, failure) })
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcodebuild, arguments: arguments, workingDirectory: workspace, result: result
        )

        // A batch-wide timeout means none of its configurations produced a
        // trustworthy result — the bundle, if any, reflects an arbitrary
        // subset that happened to finish before the kill, not a complete
        // record. Every configuration in the batch is reported timed out
        // rather than trusting a partial bundle to say which ones did.
        //
        // `isBatchAttributedTimeout` is only true when more than one
        // configuration actually shared this timeout budget: a "batch" of
        // exactly one (the final remainder chunk, or any batch that ends up
        // with a single member) has no attribution ambiguity at all — the
        // timeout unambiguously belongs to that one mutant, the same as a
        // non-batching adapter's timeout does, so `confirmTimeout` must
        // still treat a disagreeing confirmation as `.flaky` rather than
        // trusting it outright.
        if result.timedOut {
            let failure = TestRunResult(
                status: .timedOut, summary: nil, command: command,
                resultArtifactPath: FileManager.default.fileExists(atPath: resultBundle.path) ? resultBundle : nil,
                diagnosis: """
                The batch exceeded its \(String(format: "%.0f", timeoutSeconds))s limit and was \
                terminated before every configuration in it could be confirmed to finish.
                """,
                isBatchAttributedTimeout: configurationTestIdentifiers.count > 1
            )
            return Dictionary(uniqueKeysWithValues: configurationTestIdentifiers.keys.map { ($0, failure) })
        }

        var outcomes = await resultReader.classifyBatch(
            resultBundle: resultBundle, workingDirectory: workspace,
            configurationTestIdentifiers: configurationTestIdentifiers
        )

        // A batch where *every* configuration came back unaccounted for is
        // not "several unrelated bundle read failures" — it is almost
        // always one batch-wide problem (the invocation never really ran).
        // Exit code alone cannot gate this: a batch with genuine failures
        // or crashes in it also exits non-zero, which is why it is not
        // consulted above either. But once every configuration is already
        // unattributed, there is nothing left an exit code could wrongly
        // override, so it is safe to fold in here purely to make the
        // diagnosis legible instead of leaving every mutant blaming a
        // generic "no record" with no way to tell why.
        if !result.succeeded, outcomes.values.allSatisfy({ $0.status == .infrastructureFailure }) {
            let detail = OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 800)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            outcomes = outcomes.mapValues {
                XCResultAdapter.Outcome(
                    status: .infrastructureFailure,
                    summary: $0.summary,
                    diagnosis: "\($0.diagnosis) xcodebuild exited \(result.exitCode): \(detail)"
                )
            }
        }

        let bundleExists = FileManager.default.fileExists(atPath: resultBundle.path)
        return outcomes.mapValues { outcome in
            TestRunResult(
                status: outcome.status, summary: outcome.summary, command: command,
                resultArtifactPath: bundleExists ? resultBundle : nil, diagnosis: outcome.diagnosis
            )
        }
    }
}
