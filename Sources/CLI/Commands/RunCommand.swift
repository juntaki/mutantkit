import AppleBuildAdapters
import ArgumentParser
import Foundation
import MutationExecution
import MutationModel
import Reporting

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Execute a Mutation Plan and report the results."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var overrides: OverrideOptions

    @Option(name: .long, help: "The plan to execute.")
    var plan = "plan.json"

    @Option(name: [.customLong("output"), .customShort("o")], help: "Where to write the JSON report.")
    var output: String?

    @Option(name: .long, help: "Report formats. Overrides the config file.")
    var report: [String] = []

    // Additive counterpart to `--report`: report formats *belong* to the
    // project's `mutantkit.yml` (see `--report`'s own help text above), so a
    // caller that only wants to make sure a couple of extra formats are
    // produced — CI orchestration wiring `github-actions`/`ci-summary`
    // reports on top of whatever a project already configures, say — should
    // not have to first read that config file just to avoid clobbering it.
    // `--report` keeps its existing override semantics unchanged; this is a
    // second, independent flag, not a mode switch on the first one.
    @Option(name: .long, help: "Additional report formats, appended to (and deduped against) --report/the config's reports.")
    var alsoReport: [String] = []

    @Flag(name: .long, help: "Exit non-zero if any mutant survives.")
    var failOnSurvivors = false

    @Flag(name: .long, help: "Ignore any checkpoint and re-run every mutant.")
    var noResume = false

    @Flag(name: .long, help: "Fail closed if host resource pressure (memory, load, competing simulators) looks unsafe.")
    var requireHealthyHost = false

    // Off by default so a plain, unsharded `mutantkit run` keeps recording to
    // `.mutantkit/history` exactly as it always has. Meant for one shard of a
    // sharded plan (see `mutantkit shard`/`mutantkit merge`): a shard's score
    // is a partial slice of the project, never the whole thing, and recording
    // it under the same history that `mutantkit history` shows by default
    // would misrepresent it as a whole-project result. `mutantkit merge`
    // records the real, combined number instead — see MergeCommand.
    @Flag(name: .long, help: "Skip recording this run to `.mutantkit/history`. Use for each shard of a sharded plan — the shard's score is partial; `mutantkit merge`'s combined result is the one that reflects the whole project.")
    var noHistory = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        var settings = try ConfigurationLoader.load(explicitPath: common.configPath, projectRoot: root)
        try overrides.apply(to: &settings)

        try ConfigurationPreflight.run(settings)

        settings.reports = try Self.resolvedFinalReports(configured: settings.reports, report: report, alsoReport: alsoReport)

        let planURL = URL(fileURLWithPath: plan)
        guard FileManager.default.fileExists(atPath: planURL.path) else {
            print("No plan at \(planURL.path). Run `mutantkit plan` first.")
            throw ExitCode(MutantKitExit.operationalError)
        }
        let loadedPlan = try MutationPlan.decode(from: Data(contentsOf: planURL))

        var resolution = try await AppleAdapterFactory.resolve(configuration: settings, in: root)
        print("Project: \(resolution.detection.kind.rawValue) — \(resolution.detection.reason)")

        let runDirectory = root.appendingPathComponent(".mutantkit")

        // The configuration exactly as loaded/overridden, before
        // `ExecutionProfileSupport.resolveProfile` (below) may turn
        // `execution.profile: optimized`/`experimental` into concrete
        // field values. `plan.json` was written from *this* shape (`plan`
        // never resolves a profile — see `ExecutionProfileResolver`'s own
        // doc comment), so `PlanCompatibilityValidator.check` compares
        // against this, not the resolved settings the run actually
        // executes with: comparing against the resolved settings would
        // report a spurious `plan.configurationHash` mismatch purely
        // because a profile was chosen, with the user's actual
        // `mutantkit.yml` completely unchanged between planning and
        // running.
        let settingsAsConfigured = settings

        // Independent MutantKit processes are not allowed to compete for the same
        // project/destination — see `Self.acquireRunLock`'s own doc comment for
        // why, and for the exact locking rule (pulled out of this already-large
        // function so it stays testable and under this project's own line-count
        // limits, not because the reasoning belongs anywhere else).
        let lockAcquisition = try Self.acquireRunLock(
            root: root, resolution: resolution, configuredDestination: settings.project.destination, runDirectory: runDirectory
        )
        let runLock = lockAcquisition.lock
        defer { runLock.release() }

        // See `ExecutionProfileSupport.resolveProfile`'s own doc comment
        // for why this now runs *after* lock acquisition, not before: a
        // run that is about to lose this lock race should fail here,
        // before doing any other work — including whatever a future
        // `ProjectExecutionCharacteristics` might need to probe — not only
        // before simulator preparation. Still runs before simulator
        // preparation and worker-pool provisioning, which its own doc
        // comment requires.
        if let statusLine = await ExecutionProfileSupport.resolveProfile(
            settings: &settings, plan: loadedPlan, resolution: resolution
        ) { print(statusLine) }

        // After the lock, not before: this run's own lock file is on disk by
        // now, so `runLockFilesPresent` counting one is "as expected, solo,"
        // not a false "nothing is locked" taken before this run committed to
        // anything.
        let resourceSnapshot = ResourceSnapshot.capture(lockRoot: lockAcquisition.lockRoot)

        // Memory/load only, and before simulator preparation: the same codex
        // review that moved the lock up front found this preflight ran only
        // *after* the simulator was already booted, so a host too low on
        // memory to safely run at all would still pay the cost of booting a
        // simulator before `--require-healthy-host` ever got a chance to
        // fail closed. Booted-simulator contention (necessarily a
        // post-preparation question — see `diagnoseSimulators` below) is
        // checked separately, once preparation has actually run.
        let hostOnlyItems = HostResourcePreflight.diagnoseHost(
            snapshot: resourceSnapshot,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            availableMemoryBytes: HostResourcePreflight.availableMemoryBytes()
        )
        for item in hostOnlyItems where item.status != .ok {
            print("! \(item.name): \(item.detail)")
            if let remedy = item.remedy { print("  └─ \(remedy)") }
        }
        if requireHealthyHost, hostOnlyItems.contains(where: { $0.status != .ok }) {
            print("Failing closed before the baseline: --require-healthy-host was set and the host does not look healthy.")
            throw ExitCode(MutantKitExit.operationalError)
        }

        // Best-effort, once per run: `SimulatorPool` boots the resolved
        // destination and waits for `simctl bootstatus` to report it truly
        // ready, so the first `xcodebuild` invocation does not pay the
        // cold-boot tax or hit the CoreSimulator race (SBMainWorkspace
        // refusing a launch as "Busy") a cold back-to-back install was
        // found to hit. No-op for non-simulator destinations.
        //
        // The outcome is recorded, not swallowed: MutantKit is fail-closed,
        // and a simulator that cannot pass `bootstatus` is a broken
        // environment that would otherwise surface mid-run as a stream of
        // `.infrastructureFailure` verdicts. Stopping before the baseline —
        // only when this run actually resolved to a simulator — keeps that
        // failure cheap and its cause obvious. Warm (`alreadyBooted`) and
        // cold (`prepared`) outcomes are logged and persisted to the
        // `RunManifest` for `--replay`.
        let simulatorPreparation = await resolution.adapter.prepareSimulatorForRun()
        switch simulatorPreparation.outcome {
        case .notApplicable:
            break
        case .alreadyBooted, .prepared:
            print("Simulator ready (\(simulatorPreparation.outcome.rawValue)): \(simulatorPreparation.name ?? "unknown device").")
        case .failed:
            print("Simulator \(simulatorPreparation.name ?? "(unknown)") did not pass bootstatus: \(simulatorPreparation.detail ?? "unknown failure").")
            print(
                "Failing closed before the baseline: a simulator that cannot be verified ready "
                    + "would surface as infrastructure failures mid-run."
            )
            throw ExitCode(MutantKitExit.operationalError)
        }

        // Warn-only by default — the same signal `doctor` reports, checked
        // again here because a machine that looked fine at `doctor` time can
        // have changed by the time a corpus run actually starts. Fails
        // closed only when explicitly opted into: the corpus runner is the
        // one caller that has already decided a bad reading here should
        // abort before hours of runtime are spent on results a bad host
        // would make indistinguishable from a real finding.
        let simulatorApplicable = simulatorPreparation.outcome != .notApplicable
        let simulatorItems = HostResourcePreflight.diagnoseSimulators(
            bootedSimulatorCount: simulatorApplicable ? await HostResourcePreflight.bootedSimulatorCount() : nil,
            simulatorApplicable: simulatorApplicable
        )
        for item in simulatorItems where item.status != .ok {
            print("! \(item.name): \(item.detail)")
            if let remedy = item.remedy { print("  └─ \(remedy)") }
        }
        if requireHealthyHost, simulatorItems.contains(where: { $0.status != .ok }) {
            print("Failing closed before the baseline: --require-healthy-host was set and the host does not look healthy.")
            throw ExitCode(MutantKitExit.operationalError)
        }

        // Phase C4 (competitive-parity program): one real simulator per
        // worker instead of every worker contending for the single
        // destination `simulatorPreparation` just verified. Provisioning
        // failure is never fail-closed here — this is a performance opt-in,
        // not a correctness requirement, so a failure prints a clear
        // message and the run proceeds with today's single-shared-device
        // behavior rather than aborting a run the user otherwise asked for.
        let poolProvision = await Self.provisionSimulatorWorkerPoolIfNeeded(
            resolution: resolution, configuration: settings, projectRoot: root
        )
        resolution = poolProvision.resolution
        // `do`/`catch` around the rest of this function, not a `defer`:
        // `DispatchSemaphore.wait()` is unavailable from an async context
        // (the compiler rejects exactly the sync/async bridge a `defer`
        // would otherwise need here), so cleanup must be an explicit
        // `await` on every exit path instead — one at the end of the `do`
        // block for the success path, one in `catch` for every thrown
        // error (the several early `throw ExitCode(...)` calls below
        // included, since they are ordinary thrown errors from this `do`
        // block's point of view).
        do {
            try await runAfterSimulatorPoolProvisioned(
                root: root, settings: RunConfiguration(resolved: settings, asConfigured: settingsAsConfigured),
                loadedPlan: loadedPlan, resolution: resolution,
                runDirectory: runDirectory, resourceSnapshot: resourceSnapshot, simulatorPreparation: simulatorPreparation
            )
            await poolProvision.cleanup()
        } catch {
            await poolProvision.cleanup()
            throw error
        }
    }

    /// Everything `run()` does from this point on, given a (possibly
    /// simulator-pool-provisioned) `resolution` — split out purely so the
    /// simulator-pool cleanup above can wrap it in a single `do`/`catch`
    /// without re-indenting the whole rest of an already-large function.
    /// An instance method, not `static`, so every bare `output`/`report`/
    /// `failOnSurvivors`/`noResume`/`noHistory`/`common`/`overrides`
    /// reference already inside this body keeps resolving as `self.x`
    /// exactly as it did before the extraction.
    private func runAfterSimulatorPoolProvisioned(
        root: URL,
        settings: RunConfiguration,
        loadedPlan: MutationPlan,
        resolution: AppleAdapterFactory.Resolution,
        runDirectory: URL,
        resourceSnapshot: ResourceSnapshot,
        simulatorPreparation: SimulatorPreparationRecord
    ) async throws {
        let scratch = runDirectory.appendingPathComponent("sandboxes")
        let artifacts = runDirectory.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)

        let priorityStoreURL = runDirectory.appendingPathComponent("test-priority.json")
        let (testAdapter, runnerPriorityStore) = Self.resolveTestAdapter(
            settings.resolved, base: resolution.adapter.test, priorityStoreURL: priorityStoreURL
        )

        try await Self.resolveDependenciesForConfirmationRetestIfNeeded(
            settings.resolved, testAdapter: testAdapter, root: root
        )

        let executionContext = await prepareRunExecutionContext(
            root: root, settings: settings, loadedPlan: loadedPlan, resolution: resolution, runDirectory: runDirectory, noResume: noResume
        )
        let toolchain = executionContext.toolchain
        let checkpoints = executionContext.checkpoints
        let coverageCache = executionContext.coverageCache
        let coverageCacheKey = executionContext.coverageCacheKey
        let resultCache = executionContext.resultCache
        let resultCacheDigest = executionContext.resultCacheDigest

        // Deliberately not `sources.exclude`: that governs which files are
        // *mutated*, not which files a sandbox needs to build. Copying build
        // state is actively harmful — SwiftPM records absolute paths in `.build`,
        // so a copy of it at a new path fails before it compiles anything.
        let workspaces = try WorkspaceManager(
            projectRoot: root, scratchRoot: scratch, cleanSubtreeCloning: settings.resolved.execution.cleanSubtreeCloning
        )
        if await workspaces.supportsAPFSClone() {
            print("Sandboxes: APFS clone (copy-on-write)")
        } else {
            print("Sandboxes: plain copy — this volume does not support cloning, so runs will be slower")
        }

        print("Running \(loadedPlan.mutations.count) mutant(s) with \(settings.resolved.execution.resolvedWorkerCount()) worker(s)…\n")

        // Written before the run starts, not after: a manifest is a record of
        // what this run is *about* to do, and a run that dies partway
        // through (a timeout on the outer process, a crash, `^C`) should
        // still leave behind an accurate account of the destination and
        // timeout it committed to, for `--replay` to use against whichever
        // mutants did get checkpointed. Best-effort — a manifest write
        // failure is not a reason to fail the run itself.
        let manifestURL = RunManifest.url(runDirectory: runDirectory, workUnitID: loadedPlan.workUnitID)
        let manifestContext = ManifestWriteContext(
            resolution: resolution, settings: settings.resolved, toolchain: toolchain,
            resourceSnapshot: resourceSnapshot, simulatorPreparation: simulatorPreparation
        )
        writeManifest(plan: loadedPlan, context: manifestContext, baselineDuration: 0, to: manifestURL)

        let report = try await Self.execute(
            strategy: settings.resolved.execution.strategy,
            context: SchemataRunOrchestration.Context(
                plan: loadedPlan, configuration: settings.resolved, projectRoot: root,
                adapter: resolution.adapter, testAdapter: testAdapter, toolchain: toolchain,
                // Deliberately the same two values passed to
                // `IsolatedRunOptions` below, not a second cache instance or
                // a second digest computation: whichever backend measures
                // the attribution first, the other one reuses it.
                coverageCache: coverageCache, coverageCacheKey: coverageCacheKey
            ),
            workspaces: workspaces, runDirectory: runDirectory,
            isolatedOptions: IsolatedRunOptions(
                checkpoints: checkpoints, artifactsRoot: artifacts, coverageCache: coverageCache, coverageCacheKey: coverageCacheKey,
                resultCache: resultCache, resultCacheDigest: resultCacheDigest, priorityStore: runnerPriorityStore,
                progress: ProgressReporter(total: loadedPlan.mutations.count)
            )
        )

        // Rewritten with the *measured* baseline-adaptive timeout once the
        // baseline has actually run — the pre-run write above used
        // `baselineDuration: 0` as a placeholder for a strategy that scales
        // with it, which is only ever right for `.fixed`. `--replay` needs
        // the number every mutant in this run was actually held to.
        if report.baseline.passed {
            writeManifest(plan: loadedPlan, context: manifestContext, baselineDuration: report.baseline.durationSeconds, to: manifestURL)
        }

        try emit(report, settings: settings.resolved, runDirectory: runDirectory)
        // Gate 3 diagnostic instrumentation only (see
        // `GateTimingRecorder`'s own doc comment) — every other run leaves
        // this env var unset and pays nothing beyond the spans' already-
        // negligible recording cost.
        if let timingOutputPath = ProcessInfo.processInfo.environment["MUTANTKIT_GATE3_TIMING_OUTPUT"] {
            try await GateTimingRecorder.shared.write(to: URL(fileURLWithPath: timingOutputPath))
            print("Wrote \(timingOutputPath) (Gate 3 timing spans)")
        }
        if !noHistory {
            Self.recordHistory(report, to: RunHistoryStore(root: runDirectory.appendingPathComponent("history")))
        }

        // Integrity outranks everything: a run whose invariants did not reconcile
        // has no score to threshold against, so there is nothing to compare and
        // reporting a survivor count from it would be a claim we cannot back.
        guard report.integrity.passed else {
            throw ExitCode(MutantKitExit.integrityFailure)
        }
        if failOnSurvivors, (report.score?.survived ?? 0) > 0 {
            throw ExitCode(MutantKitExit.survivorsFound)
        }
    }

    /// Dispatches to the existing, unmodified `MutationRunner` for
    /// `.isolated` or to `SchemataRunOrchestration` for `.schemata` —
    /// pulled out of `run()` itself so that already-large function's own
    /// complexity does not keep growing every time a new execution
    /// strategy is added.
    private static func execute(
        strategy: ExecutionMode, context: SchemataRunOrchestration.Context, workspaces: WorkspaceManager,
        runDirectory: URL, isolatedOptions: IsolatedRunOptions
    ) async throws -> RunReport {
        switch strategy {
        case .isolated:
            return try await MutationRunner(
                plan: context.plan,
                configuration: context.configuration,
                projectRoot: context.projectRoot,
                build: context.adapter.build,
                test: context.testAdapter,
                workspaces: workspaces,
                checkpoints: isolatedOptions.checkpoints,
                artifactsRoot: isolatedOptions.artifactsRoot,
                toolchain: context.toolchain,
                coverageCache: isolatedOptions.coverageCache,
                coverageCacheKey: isolatedOptions.coverageCacheKey,
                resultCache: isolatedOptions.resultCache,
                resultCacheDigest: isolatedOptions.resultCacheDigest,
                priorityStore: isolatedOptions.priorityStore,
                progress: isolatedOptions.progress
            ).run()
        case .schemata:
            // A separate scratch subdirectory from the isolated-fallback
            // pass's `workspaces` so the two passes' sandboxes never
            // collide mid-run.
            let schemataScratch = runDirectory.appendingPathComponent("schemata-sandboxes")
            let schemataWorkspaces = try WorkspaceManager(
                projectRoot: context.projectRoot,
                scratchRoot: schemataScratch,
                cleanSubtreeCloning: context.configuration.execution.cleanSubtreeCloning
            )
            // No timeout argument: this call site used to pass
            // `timeouts.baselineSeconds` as the *only* limit, which
            // `SchemataMutationRunner` then applied to every per-mutant token
            // run as well as to the baseline — giving a hanging schemata
            // mutant the whole suite's budget (600 s by default) where
            // isolated mode correctly spends `timeouts.mutant`. The runner
            // now reads `context.configuration.timeouts` itself and resolves
            // each limit separately.
            return try await SchemataRunOrchestration.run(
                context: context, workspaces: workspaces, schemataWorkspaces: schemataWorkspaces
            )
        }
    }

    private func emit(_ report: RunReport, settings: Configuration, runDirectory: URL) throws {
        var rendered = try ReporterRegistry.renderAll(
            report,
            kinds: settings.reports.filter { $0 != .strykerJSON }
        )

        // Built here rather than through the registry because only the CLI knows
        // where the sources are. Without a provider the export carries no source,
        // and the Stryker viewer has nothing to highlight — which is most of the
        // reason to export in that format at all.
        if settings.reports.contains(.strykerJSON) {
            let root = common.resolvedProjectRoot
            rendered[.strykerJSON] = try StrykerReporter(
                sourceProvider: { relativePath in
                    try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
                }
            ).render(report)
        }

        if let console = rendered[.console] {
            print(console)
        }
        if let xcode = rendered[.xcode], !xcode.isEmpty {
            print(xcode)
        }
        if let githubActions = rendered[.githubActions], !githubActions.isEmpty {
            print(githubActions)
        }

        for (kind, contents) in rendered.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let filename = filename(for: kind) else { continue }
            let url = kind == .json && output != nil
                ? URL(fileURLWithPath: output!)
                : runDirectory.appendingPathComponent(filename)
            try Data(contents.utf8).write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    /// Console, Xcode, and GitHub Actions output go to the terminal, not to a
    /// file — writing them too would leave stray artifacts nobody asked for,
    /// and GitHub's own runner only recognizes `::warning::`/`::error::`
    /// workflow commands when they appear in a step's live stdout, never in
    /// a file it would have to be told to go read.
    private func filename(for kind: ReportKind) -> String? {
        switch kind {
        case .console, .xcode, .githubActions: nil
        case .json: "report.json"
        case .strykerJSON: "stryker-report.json"
        case .html: "report.html"
        case .ciSummary: "summary.md"
        case .sonar: "sonar-issues.json"
        case .sarif: "mutantkit.sarif.json"
        }
    }

    /// Records `report` to `store` — best-effort, like the checkpoint write
    /// inside `MutationRunner.finalize` (score integrity never depends on
    /// history), but a silently discarded failure would quietly break
    /// `mutantkit history` with nobody noticing until they went looking for a
    /// run that never showed up. A failure is written to `stderr` the same
    /// way `MutationRunner.finalize` surfaces a checkpoint write failure —
    /// `try?` alone would swallow it.
    ///
    /// Pulled out of `run()`, on the same terms as `resolveTestAdapter`/
    /// `lockIdentity` below, so the surfacing behavior itself is directly
    /// testable without a real project or adapter. `stderr` is injectable for
    /// exactly that reason; production always uses the real
    /// `FileHandle.standardError`.
    ///
    /// Returns the diagnosis written on failure, `nil` on success — mostly
    /// useful to a caller (a test) that wants to assert a failure was
    /// actually surfaced rather than just that some output happened.
    /// Pulled out of `run()` so this bad-input check is directly testable —
    /// the same reason `recordHistory`/`resolveTestAdapter`/`lockIdentity`
    /// below are their own functions rather than inlined. Bad input, not a
    /// usage-syntax error: every other bad-input case in this command
    /// already throws `MutantKitExit.operationalError` explicitly rather
    /// than `ArgumentParser`'s own `ValidationError` (exit 64), and this one
    /// should be no different (see `MutantKitExit`'s own exit-code
    /// contract).
    static func resolvedReports(from raw: [String]) throws -> [ReportKind] {
        try raw.map { value in
            guard let kind = ReportKind(rawValue: value) else {
                print("Unknown report '\(value)'. Expected one of: \(ReportKind.allCases.map(\.rawValue).joined(separator: ", ")).")
                throw ExitCode(MutantKitExit.operationalError)
            }
            return kind
        }
    }

    @discardableResult
    static func recordHistory(
        _ report: RunReport,
        to store: RunHistoryStore,
        stderr: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) -> String? {
        do {
            try store.record(report)
            return nil
        } catch {
            let diagnosis = "history write failed for \(report.planID): \(error)"
            stderr("warning: \(diagnosis)\n")
            return diagnosis
        }
    }

    /// Stryker-style early abort: selected tests run in historical
    /// kill-priority order, stopping after the first trustworthy detection.
    /// Two modes:
    ///
    /// 1. With `testBatchSize`, *and* an adapter that actually supports
    ///    batching: wave-based early kill — each wave batch-tests one
    ///    prioritised test per surviving mutant. The priority store is
    ///    handed to `MutationRunner` directly, which runs the wave loop
    ///    internally (see `MutationRunner.testInWaves`). No adapter
    ///    wrapping needed.
    ///
    /// 2. Otherwise (no `testBatchSize`, or an adapter — e.g. a plain
    ///    SwiftPM package's — that does not conform to `BatchTestable`):
    ///    per-invocation `PrioritizingTestAdapter` wrapping, which runs one
    ///    test per xcodebuild call. `testBatchSize` being configured is not
    ///    enough on its own to pick wave mode: `MutationRunner` only enters
    ///    the wave loop when its test adapter is genuinely `BatchTestable`,
    ///  and handing it a priority store the runner will never consult
    ///    would silently discard `earlyAbortSelectedTests` instead of
    ///    falling back here.
    static func resolveTestAdapter(
        _ settings: Configuration, base: any TestAdapter, priorityStoreURL: URL
    ) -> (testAdapter: any TestAdapter, runnerPriorityStore: TestPriorityStore?) {
        guard settings.execution.selectCoveringTests, settings.execution.earlyAbortSelectedTests else {
            return (base, nil)
        }
        guard PrioritizingTestAdapter.wouldWrap(settings, base: base) else {
            return (base, TestPriorityStore(url: priorityStoreURL))
        }
        return (PrioritizingTestAdapter(base: base, priorityStore: TestPriorityStore(url: priorityStoreURL)), nil)
    }

    /// The `RunIsolationLock`'s key: prefers the destination as actually
    /// *resolved* (`ResolvedDestination.destinationArgument` — a device UDID
    /// once one has been pinned) over the raw, as-configured destination
    /// string, so two runs whose `mutantkit.yml`s spell the same simulator
    /// differently still collide on the same lock key instead of sailing
    /// past each other onto the same device.
    ///
    /// Falls back to the raw configured string (`settings.project.destination
    /// ?? "auto"`) when there is genuinely nothing more specific to key on:
    /// a non-Xcode adapter (a plain SwiftPM macOS package has no destination
    /// concept at all), or an Xcode destination that never resolved to a
    /// concrete device (`ResolvedDestination.device == nil` — a generic
    /// placeholder like `generic/platform=iOS`, or a macOS/physical-device
    /// destination `DestinationResolver` never touches `simctl` for).
    static func lockIdentity(for adapter: any ProjectAdapter, configuredDestination: String?) -> String {
        if let resolvedDestination = (adapter as? XcodeBuildProjectAdapter)?.resolvedDestination,
           resolvedDestination.device != nil {
            return resolvedDestination.destinationArgument
        }
        return configuredDestination ?? "auto"
    }
}

/// `--report`/`--also-report` resolution, split out of the main struct body
/// (a `type_body_length`-baselined file already at its cap) rather than
/// inlined in `run()` — same motive as `resolveTestAdapter`/`lockIdentity`
/// above: directly testable without a real project, and it keeps `run()`
/// itself down to one line for this whole concern instead of two `if`s.
extension RunCommand {
    /// `report` (if given) replaces the config's own `reports:` outright,
    /// exactly as it always has; `alsoReport` (if given) is then folded on
    /// top *additively* — see `mergedReports` below. Called unconditionally
    /// from `run()`; both being empty is the plain "just use the config"
    /// case and returns `configured` untouched.
    static func resolvedFinalReports(configured: [ReportKind], report: [String], alsoReport: [String]) throws -> [ReportKind] {
        var reports = configured
        if !report.isEmpty {
            reports = try resolvedReports(from: report)
        }
        if !alsoReport.isEmpty {
            reports = mergedReports(base: reports, additional: try resolvedReports(from: alsoReport))
        }
        return reports
    }

    /// `--also-report`'s entire effect: `base` with `additional` appended in
    /// the order given, skipping any kind already present in `base` or
    /// already added earlier in `additional` — so a CI wrapper that always
    /// passes the same fixed list of kinds can never duplicate one the
    /// project's own config already requested.
    static func mergedReports(base: [ReportKind], additional: [ReportKind]) -> [ReportKind] {
        var seen = Set(base)
        var merged = base
        for kind in additional where !seen.contains(kind) {
            seen.insert(kind)
            merged.append(kind)
        }
        return merged
    }
}

/// Split from `RunCommand`'s primary body purely to stay under this
/// project's `function_body_length`/`type_body_length` SwiftLint limits, not
/// because any of this belongs to a different feature — the toolchain
/// fingerprint/checkpoint/cache setup every run needs before it can start
/// executing mutants, and the simulator-worker-pool provisioning step.
private extension RunCommand {
    /// `settings.execution` alongside the configuration exactly as
    /// loaded/overridden before `ExecutionProfileSupport.resolveProfile`
    /// may have resolved `execution.profile` into concrete field values —
    /// bundled into one parameter (rather than adding a second bare
    /// `Configuration` parameter to `runAfterSimulatorPoolProvisioned`/
    /// `prepareRunExecutionContext`, which would push both past this
    /// project's `function_parameter_count` lint threshold) so
    /// `PlanCompatibilityValidator.check` — the one caller that needs the
    /// pre-resolution shape — can reach it without every other caller
    /// having to thread through a value it never uses. See
    /// `settingsAsConfigured`'s own comment in `run()` for why the
    /// distinction matters. Declared in this extension, not `run()`'s own
    /// enclosing struct body, purely to leave that body's own line count
    /// alone — `private` on a type still reaches every extension of the
    /// same enclosing type in this file, so `run()` and
    /// `prepareRunExecutionContext` (in their own, different scopes) see
    /// this exactly as if it were declared alongside them.
    struct RunConfiguration {
        let resolved: Configuration
        let asConfigured: Configuration
    }

    /// Acquires `RunIsolationLock` for this run and returns the lock root
    /// `run()` also needs for `ResourceSnapshot.capture(lockRoot:)` right
    /// afterward — pulled out of `run()` itself purely to keep that
    /// already-large function's own body under this project's
    /// `function_body_length` limit, in this extension rather than
    /// `run()`'s enclosing struct body for the identical reason
    /// `RunConfiguration` above is.
    ///
    /// Independent MutantKit processes are not allowed to compete for the
    /// same project/destination. Real-project validation demonstrated that
    /// severe resource contention and shared simulator pressure can change
    /// a mutant's observable failure mode (crash vs timeout), which
    /// changes scoring if the two processes are allowed to interfere.
    /// Internal workers remain allowed: they share this one owning process
    /// and therefore this one lock.
    ///
    /// Acquired before simulator preparation, not after: a codex review
    /// found the original ordering booted/prepared the simulator *before*
    /// this lock, so two independent processes racing for the same
    /// destination could both boot/prepare it concurrently — CoreSimulator
    /// contention, one process's environment changes bleeding into the
    /// other's — before either noticed the collision. Lock first means a
    /// losing process fails here, before it has touched the simulator at
    /// all.
    ///
    /// Keyed on the *resolved* destination, not the raw config string: two
    /// `mutantkit.yml`s that spell the same physical simulator differently
    /// — destination unset (implicit "auto") in one, an explicit
    /// `platform=iOS Simulator,name=iPhone 17 Pro` in the other, both
    /// resolving to the same booted device — would otherwise take
    /// different lock keys and race that one simulator concurrently,
    /// exactly what this lock exists to prevent. `resolvedDestination`
    /// already pins that answer once, before `run()` calls this (see
    /// `AppleAdapterFactory.resolve`); reusing it here means "same device"
    /// and "same lock key" are the same fact, not two facts that can drift
    /// apart.
    static func acquireRunLock(
        root: URL, resolution: AppleAdapterFactory.Resolution, configuredDestination: String?, runDirectory: URL
    ) throws -> (lock: RunIsolationLock, lockRoot: URL) {
        let destinationIdentity = Self.lockIdentity(for: resolution.adapter, configuredDestination: configuredDestination)
        let lockRoot = runDirectory.appendingPathComponent("run-locks")
        let lock = try RunIsolationLock.acquire(projectRoot: root, lockRoot: lockRoot, destination: destinationIdentity)
        return (lock, lockRoot)
    }

    /// The outcome of `provisionSimulatorWorkerPoolIfNeeded`: a
    /// (possibly-unchanged) `Resolution` to use for the rest of the run,
    /// and the cleanup to run when it ends, whichever way it ends.
    /// `cleanup` is always safe to call — a no-op when nothing was ever
    /// provisioned.
    struct SimulatorWorkerPoolProvision {
        let resolution: AppleAdapterFactory.Resolution
        let cleanup: @Sendable () async -> Void
    }

    /// Provisions one real simulator per worker — `execution.simulatorPool:
    /// true`'s whole effect — or leaves `resolution` untouched when the
    /// feature is off, inapplicable to this run's configuration, or fails.
    ///
    /// Deliberately narrow eligibility (see `ExecutionSettings
    /// .simulatorPool`'s own doc comment for the full reasoning): only an
    /// `XcodeBuildProjectAdapter` with a resolved simulator device, only
    /// `incrementalBuild: true` with `testBatchSize` unset (the one
    /// execution shape this has actually been benchmarked against —
    /// per-worker persistent sandboxes give a stable identity to key a
    /// device assignment on; batched/pipelined execution's single shared
    /// test lane does not), only `resolvedWorkerCount() > 1` (nothing to
    /// parallelize otherwise).
    static func provisionSimulatorWorkerPoolIfNeeded(
        resolution: AppleAdapterFactory.Resolution,
        configuration: Configuration,
        projectRoot: URL
    ) async -> SimulatorWorkerPoolProvision {
        let workers = configuration.execution.resolvedWorkerCount()
        guard configuration.execution.simulatorPool,
              configuration.execution.strategy == .isolated,
              configuration.execution.incrementalBuild,
              configuration.execution.testBatchSize == nil,
              workers > 1,
              let projectAdapter = resolution.adapter as? XcodeBuildProjectAdapter,
              let baseDevice = projectAdapter.resolvedDestination?.device
        else {
            return SimulatorWorkerPoolProvision(resolution: resolution, cleanup: {})
        }

        // A fresh pool instance is fine here even though `projectAdapter`
        // owns its own, separate one internally: provisioning only ever
        // lists/clones/boots/deletes real `simctl` devices, which is
        // global machine state every `SimulatorPool` instance observes
        // identically — the exclusive-*leasing* invariant `SimulatorPool`
        // otherwise guarantees is a property of one actor instance's own
        // in-memory bookkeeping, not something provisioning needs at all
        // (nothing here is leased).
        let provisioningPool = SimulatorPool(workingDirectory: projectRoot)
        let orphans = await provisioningPool.cleanupOrphanClones()
        if !orphans.isEmpty {
            print("Simulator pool: cleaned up \(orphans.count) orphaned clone(s) left by a previous interrupted run.")
        }

        let devices: [SimulatorDevice]
        do {
            devices = try await provisioningPool.provisionWorkerPool(base: baseDevice, count: workers)
        } catch {
            print(
                "Simulator pool: could not provision \(workers) worker slot(s) (\(error)) — "
                    + "falling back to a single shared simulator for this run."
            )
            return SimulatorWorkerPoolProvision(resolution: resolution, cleanup: {})
        }

        let cloneCount = devices.count - 1
        print(
            cloneCount > 0
                ? "Simulator pool: \(devices.count) worker slot(s) ready (\(cloneCount) clone(s) of \(baseDevice.name))."
                : "Simulator pool: only 1 slot available; running with a single shared simulator."
        )

        var devicesByWorkspace: [String: SimulatorDevice] = [:]
        for (index, device) in devices.enumerated() {
            devicesByWorkspace[WorkspaceManager.directoryName(for: "incr-worker-\(index)")] = device
        }

        let newAdapter = AppleAdapterFactory.adapter(
            for: resolution.detection,
            configuration: configuration,
            projectRoot: projectRoot,
            resolvedDestination: projectAdapter.resolvedDestination,
            workerDevicesByWorkspace: devicesByWorkspace
        )

        return SimulatorWorkerPoolProvision(
            resolution: AppleAdapterFactory.Resolution(adapter: newAdapter, detection: resolution.detection),
            cleanup: {
                let failures = await provisioningPool.releaseWorkerPool(devices, base: baseDevice)
                if !failures.isEmpty {
                    FileHandle.standardError.write(Data(
                        "warning: could not delete simulator clone(s): \(failures.joined(separator: ", "))\n".utf8
                    ))
                }
            }
        )
    }
}

extension RunCommand {
    /// The isolated-mode-only pieces `execute` threads into `MutationRunner`
    /// — none of these participate in schemata mode v1 (no checkpoint,
    /// coverage cache, or cross-run result cache; see the schemata
    /// production-integration plan's explicitly-out-of-scope list) —
    /// bundled so `execute` itself stays within SwiftLint's parameter-count
    /// threshold. Declared in this extension rather than in the primary
    /// struct body, on the same terms as `RunExecutionContext`/
    /// `ManifestWriteContext` below: a `private` nested type declared in an
    /// extension of `RunCommand` in this same file is exactly as visible to
    /// `execute`/`run()` as one declared inline would be, and moving it out
    /// keeps the primary struct body under SwiftLint's `type_body_length`
    /// limit.
    private struct IsolatedRunOptions {
        let checkpoints: CheckpointStore
        let artifactsRoot: URL
        let coverageCache: CoverageProfileCache
        let coverageCacheKey: CoverageProfileCache.Key?
        let resultCache: MutationResultCache?
        let resultCacheDigest: String?
        let priorityStore: TestPriorityStore?
        let progress: ProgressReporter?
    }

    /// Everything `runAfterSimulatorPoolProvisioned` needs from the
    /// toolchain/checkpoint/cache setup below, bundled so the caller reads
    /// one destructuring assignment instead of the setup's own six local
    /// `let`s inline.
    private struct RunExecutionContext {
        let toolchain: ToolchainFingerprint
        let checkpoints: CheckpointStore
        let coverageCache: CoverageProfileCache
        let coverageCacheKey: CoverageProfileCache.Key?
        let resultCache: MutationResultCache?
        let resultCacheDigest: String?
    }

    /// Computed once, up front, so both the checkpoint file name and the run
    /// itself see the identical toolchain — a probe taken after some mutants
    /// had already built would date the run by whichever mutant happened to
    /// be in flight when it ran.
    private func prepareRunExecutionContext(
        root: URL, settings: RunConfiguration, loadedPlan: MutationPlan,
        resolution: AppleAdapterFactory.Resolution, runDirectory: URL, noResume: Bool
    ) async -> RunExecutionContext {
        let toolchainProbe = await ToolchainProbe.fingerprint(
            workingDirectory: root, resolvedDestination: (resolution.adapter as? XcodeBuildProjectAdapter)?.resolvedDestination
        )
        let toolchain = toolchainProbe.fingerprint

        // Against `settings.asConfigured`, not `.resolved`: `plan.json`'s
        // own `configurationHash` was written from the configuration
        // exactly as `mutantkit plan` loaded it, which never resolves
        // `execution.profile` (see `ExecutionProfileResolver`'s own doc
        // comment) — comparing against the resolved settings here would
        // report a spurious mismatch purely because a profile was chosen,
        // with the user's actual `mutantkit.yml` unchanged between
        // planning and running.
        for issue in PlanCompatibilityValidator.check(loadedPlan, against: settings.asConfigured, toolchain: toolchain) {
            print(issue.description)
        }
        let settings = settings.resolved

        // Keyed by work unit and by everything the checkpoint's cached
        // results depend on, not by work unit alone: a checkpoint exists to
        // survive an interruption *within* one attempt at a run, not to
        // survive the source, the test suite, a fixture, or the toolchain
        // changing since it was written. Folding the fingerprint into the
        // file name means a changed context is never even found, rather
        // than found and then having to be distrusted — see
        // `RunContextFingerprint`'s doc comment for why that distinction
        // mattered in practice.
        let fingerprint: RunContextFingerprint?
        do {
            fingerprint = try await RunContextProbe.compute(
                projectRoot: root,
                configuration: settings,
                toolchain: toolchain,
                workUnitID: loadedPlan.workUnitID,
                toolchainCacheIdentityComplete: toolchainProbe.identityEvidenceComplete
            )
        } catch {
            print("\(error)")
            fingerprint = nil
        }

        let checkpointURL = fingerprint.map {
            runDirectory.appendingPathComponent("checkpoint-\(loadedPlan.workUnitID)-\($0.shortDigest).jsonl")
        } ?? runDirectory.appendingPathComponent("checkpoint-\(loadedPlan.workUnitID)-unfingerprinted.jsonl")
        if noResume || fingerprint == nil {
            try? FileManager.default.removeItem(at: checkpointURL)
        }
        let verificationPolicy = MutationVerdictVerifier.VerdictVerificationPolicy(
            retestKilledMutants: settings.execution.retestKilledMutants,
            confirmCrashKills: settings.execution.confirmCrashKills,
            confirmTimedOutMutants: settings.execution.confirmTimedOutMutants
        )
        let checkpoints = CheckpointStore(url: checkpointURL, policy: verificationPolicy)
        let alreadyDone = (try? await checkpoints.completedIDs(plan: loadedPlan).count) ?? 0
        if alreadyDone > 0 {
            print("Resuming: \(alreadyDone) of \(loadedPlan.mutations.count) mutants already recorded.")
        }

        // Per-test coverage attribution is the single most expensive baseline
        // cost on a real project and also the most stable across iterations:
        // it depends on the source tree and test suite, not on which mutants
        // are planned. The cache persists the measured attribution keyed by a
        // digest of those inputs (see `RunContextProbe.computeContextDigest`),
        // so the second run of an unchanged project skips the profiling pass
        // entirely. Like the checkpoint, the cache is best-effort — a digest
        // computation failure means coverage is re-measured, not a failed run.
        let coverageCacheRoot = runDirectory.appendingPathComponent("coverage-cache")
        let coverageCache = CoverageProfileCache(root: coverageCacheRoot)
        let coverageCacheKey: CoverageProfileCache.Key?
        do {
            let digest = try await RunContextProbe.computeContextDigest(
                projectRoot: root, configuration: settings, toolchain: toolchain, purpose: "coverageProfileCache",
                toolchainCacheIdentityComplete: toolchainProbe.identityEvidenceComplete
            )
            coverageCacheKey = CoverageProfileCache.Key(contextDigest: digest)
        } catch {
            // Printed, not swallowed: "no cache this run" is a real slowdown
            // (the per-test coverage pass is the most expensive thing a
            // baseline does), and a user staring at an unexpectedly slow run
            // deserves the reason rather than having to guess at it. The run
            // itself continues — recomputing is always correct, just slower.
            print("\(error)")
            coverageCacheKey = nil
        }

        // Cross-run result cache: a mutant whose MutationID was already
        // evaluated against an identical execution context (same source,
        // tests, toolchain, configuration) is reused without rebuilding or
        // retesting. The cache's purpose is iteration speed — a developer
        // who re-plans and re-runs pays only for the mutants that changed,
        // not the entire plan. The digest deliberately excludes the plan's
        // workUnitID so overlapping mutants across different plans hit.
        // Best-effort, like the checkpoint: a digest failure means no
        // caching, not a failed run.
        //
        // `--no-resume`'s help text promises every mutant is re-run, which a
        // user typically reaches for specifically to get a measurement that
        // is not served from anything stale — e.g. suspecting flakiness or
        // environment drift the cache's digest doesn't model. Mirroring the
        // checkpoint's own `noResume` handling above, the cache is simply
        // not constructed for this run: neither read from nor written to.
        // The on-disk cache is left alone — only this run's use of it is
        // disabled, the same way clearing the checkpoint file above never
        // touches the result cache directory.
        let resultCache: MutationResultCache?
        let resultCacheDigest: String?
        if noResume {
            resultCache = nil
            resultCacheDigest = nil
        } else {
            let resultCacheRoot = runDirectory.appendingPathComponent("result-cache")
            resultCache = MutationResultCache(root: resultCacheRoot, policy: verificationPolicy)
            // "resultCache2", not "resultCache": a codex review found that
            // stored MutationResults from before ResultClassifier required
            // proven activation for a scorable outcome (see
            // `unprovenActivation` in ResultClassifier.swift) could be
            // loaded from an on-disk cache written by an older build and
            // re-enter a score unexamined — the cache's own store-time gate
            // only checks `outcome.isCacheableResult`/`isReportable`, never
            // `activationEvidence`. Bumping the purpose tag changes the
            // digest, which misses on every pre-existing cache entry and
            // forces a fresh, correctly-gated classification instead of
            // trusting whatever an older classifier once wrote. Any future
            // change to what makes a `MutationResult` trustworthy enough to
            // cache must bump this tag again the same way, precisely
            // because the cache has no other way to know which classifier
            // version produced an entry it is being asked to reuse.
            do {
                resultCacheDigest = try await RunContextProbe.computeContextDigest(
                    projectRoot: root,
                    configuration: settings,
                    toolchain: toolchain,
                    purpose: "resultCache2",
                    toolchainCacheIdentityComplete: toolchainProbe.identityEvidenceComplete
                )
            } catch {
                // Deliberately not printed a second time. This digest and the
                // coverage one above differ only in their `purpose` tag, and
                // nothing that can fail here depends on it — the failure is
                // always the same git/filesystem problem, already reported
                // once above with the same wording. The coverage block runs
                // unconditionally, so the reason is never lost.
                resultCacheDigest = nil
            }
        }

        return RunExecutionContext(
            toolchain: toolchain, checkpoints: checkpoints, coverageCache: coverageCache,
            coverageCacheKey: coverageCacheKey, resultCache: resultCache, resultCacheDigest: resultCacheDigest
        )
    }

    /// Everything `writeManifest` needs that stays identical across
    /// `runAfterSimulatorPoolProvisioned`'s two calls to it — bundled so
    /// that function stays under this project's `function_parameter_count`
    /// limit, and so the two call sites cannot accidentally pass slightly
    /// different values for one of these by hand.
    private struct ManifestWriteContext {
        let resolution: AppleAdapterFactory.Resolution
        let settings: Configuration
        let toolchain: ToolchainFingerprint
        let resourceSnapshot: ResourceSnapshot
        let simulatorPreparation: SimulatorPreparationRecord
    }

    /// Shared by `runAfterSimulatorPoolProvisioned`'s two manifest writes —
    /// before the run starts (`baselineDuration: 0`, the only value correct
    /// for a `.fixed` timeout strategy) and again once the baseline has
    /// actually measured a real duration a `.adaptive` strategy needs. Every
    /// field except `mutantTimeoutSeconds`/`startedAt` is identical between
    /// the two calls, so duplicating this inline a second time would only
    /// ever drift the two writes apart by accident, not by design.
    private func writeManifest(plan: MutationPlan, context: ManifestWriteContext, baselineDuration: Double, to url: URL) {
        try? RunManifest(
            planID: plan.planID,
            workUnitID: plan.workUnitID,
            startedAt: Date(),
            resolvedDestination: (context.resolution.adapter as? XcodeBuildProjectAdapter)?.resolvedDestination,
            scheme: context.settings.project.scheme,
            testTargets: context.settings.tests.targets,
            extraTestArguments: context.settings.tests.extraArguments,
            mutantTimeoutSeconds: context.settings.timeouts.mutant.resolve(baselineDuration: baselineDuration),
            baselineTimeoutSeconds: context.settings.timeouts.baselineSeconds,
            toolchain: context.toolchain,
            configurationHash: context.settings.configurationHash,
            resourceSnapshot: context.resourceSnapshot,
            simulatorPreparation: context.simulatorPreparation
        ).write(to: url)
    }
}
