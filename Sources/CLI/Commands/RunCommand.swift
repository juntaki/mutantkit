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

    @Flag(name: .long, help: "Exit non-zero if any mutant survives.")
    var failOnSurvivors = false

    @Flag(name: .long, help: "Ignore any checkpoint and re-run every mutant.")
    var noResume = false

    @Flag(name: .long, help: "Fail closed if host resource pressure (memory, load, competing simulators) looks unsafe.")
    var requireHealthyHost = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        var settings = try ConfigurationLoader.load(explicitPath: common.configPath, projectRoot: root)
        try overrides.apply(to: &settings)

        try ConfigurationPreflight.run(settings)

        if !report.isEmpty {
            settings.reports = try report.map { raw in
                guard let kind = ReportKind(rawValue: raw) else {
                    throw ValidationError(
                        "Unknown report '\(raw)'. Expected one of: \(ReportKind.allCases.map(\.rawValue).joined(separator: ", "))."
                    )
                }
                return kind
            }
        }

        let planURL = URL(fileURLWithPath: plan)
        guard FileManager.default.fileExists(atPath: planURL.path) else {
            print("No plan at \(planURL.path). Run `mutantkit plan` first.")
            throw ExitCode(MutantKitExit.operationalError)
        }
        let loadedPlan = try MutationPlan.decode(from: Data(contentsOf: planURL))

        let resolution = try await AppleAdapterFactory.resolve(configuration: settings, in: root)
        print("Project: \(resolution.detection.kind.rawValue) — \(resolution.detection.reason)")

        let runDirectory = root.appendingPathComponent(".mutantkit")

        // Independent MutantKit processes are not allowed to compete for the same
        // project/destination. Real-project validation demonstrated that severe
        // resource contention and shared simulator pressure can change a mutant's
        // observable failure mode (crash vs timeout), which changes scoring if the
        // two processes are allowed to interfere. Internal workers remain allowed:
        // they share this one owning process and therefore this one lock.
        //
        // Acquired before simulator preparation, not after: a codex review
        // found the original ordering booted/prepared the simulator *before*
        // this lock, so two independent processes racing for the same
        // destination could both boot/prepare it concurrently — CoreSimulator
        // contention, one process's environment changes bleeding into the
        // other's — before either noticed the collision. Lock first means a
        // losing process fails here, before it has touched the simulator at
        // all.
        //
        // Keyed on the *resolved* destination, not the raw config string:
        // two `mutantkit.yml`s that spell the same physical simulator
        // differently — destination unset (implicit "auto") in one, an
        // explicit `platform=iOS Simulator,name=iPhone 17 Pro` in the other,
        // both resolving to the same booted device — would otherwise take
        // different lock keys and race that one simulator concurrently,
        // exactly what this lock exists to prevent. `resolvedDestination`
        // already pins that answer once, before this line runs (see
        // `AppleAdapterFactory.resolve` above); reusing it here means "same
        // device" and "same lock key" are the same fact, not two facts that
        // can drift apart.
        let destinationIdentity = Self.lockIdentity(for: resolution.adapter, configuredDestination: settings.project.destination)
        let lockRoot = runDirectory.appendingPathComponent("run-locks")
        let runLock = try RunIsolationLock.acquire(
            projectRoot: root,
            lockRoot: lockRoot,
            destination: destinationIdentity
        )
        defer { runLock.release() }

        // After the lock, not before: this run's own lock file is on disk by
        // now, so `runLockFilesPresent` counting one is "as expected, solo,"
        // not a false "nothing is locked" taken before this run committed to
        // anything.
        let resourceSnapshot = ResourceSnapshot.capture(lockRoot: lockRoot)

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

        let scratch = runDirectory.appendingPathComponent("sandboxes")
        let artifacts = runDirectory.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)

        let priorityStoreURL = runDirectory.appendingPathComponent("test-priority.json")
        let (testAdapter, runnerPriorityStore) = Self.resolveTestAdapter(
            settings, base: resolution.adapter.test, priorityStoreURL: priorityStoreURL
        )

        // Computed once, up front, so both the checkpoint file name and the
        // run itself see the identical toolchain — a probe taken after some
        // mutants had already built would date the run by whichever mutant
        // happened to be in flight when it ran.
        let toolchain = await ToolchainProbe.fingerprint(workingDirectory: root)

        for issue in PlanCompatibilityValidator.check(loadedPlan, against: settings, toolchain: toolchain) {
            print(issue.description)
        }

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
                workUnitID: loadedPlan.workUnitID
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
        if let digest = try? await RunContextProbe.computeContextDigest(
            projectRoot: root, configuration: settings, toolchain: toolchain, purpose: "coverageProfileCache"
        ) {
            coverageCacheKey = CoverageProfileCache.Key(contextDigest: digest)
        } else {
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
            resultCacheDigest = try? await RunContextProbe.computeContextDigest(
                projectRoot: root,
                configuration: settings,
                toolchain: toolchain,
                purpose: "resultCache2"
            )
        }

        // Deliberately not `sources.exclude`: that governs which files are
        // *mutated*, not which files a sandbox needs to build. Copying build
        // state is actively harmful — SwiftPM records absolute paths in `.build`,
        // so a copy of it at a new path fails before it compiles anything.
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratch)
        if await workspaces.supportsAPFSClone() {
            print("Sandboxes: APFS clone (copy-on-write)")
        } else {
            print("Sandboxes: plain copy — this volume does not support cloning, so runs will be slower")
        }

        print("Running \(loadedPlan.mutations.count) mutant(s) with \(settings.execution.resolvedWorkerCount()) worker(s)…\n")

        // Written before the run starts, not after: a manifest is a record of
        // what this run is *about* to do, and a run that dies partway
        // through (a timeout on the outer process, a crash, `^C`) should
        // still leave behind an accurate account of the destination and
        // timeout it committed to, for `--replay` to use against whichever
        // mutants did get checkpointed. Best-effort — a manifest write
        // failure is not a reason to fail the run itself.
        let manifestURL = RunManifest.url(runDirectory: runDirectory, workUnitID: loadedPlan.workUnitID)
        try? RunManifest(
            planID: loadedPlan.planID,
            workUnitID: loadedPlan.workUnitID,
            startedAt: Date(),
            resolvedDestination: (resolution.adapter as? XcodeBuildProjectAdapter)?.resolvedDestination,
            scheme: settings.project.scheme,
            testTargets: settings.tests.targets,
            extraTestArguments: settings.tests.extraArguments,
            mutantTimeoutSeconds: settings.timeouts.mutant.resolve(baselineDuration: 0),
            baselineTimeoutSeconds: settings.timeouts.baselineSeconds,
            toolchain: toolchain,
            configurationHash: settings.configurationHash,
            resourceSnapshot: resourceSnapshot,
            simulatorPreparation: simulatorPreparation
        ).write(to: manifestURL)

        let report = try await Self.execute(
            strategy: settings.execution.strategy,
            context: SchemataRunOrchestration.Context(
                plan: loadedPlan, configuration: settings, projectRoot: root,
                adapter: resolution.adapter, testAdapter: testAdapter, toolchain: toolchain
            ),
            workspaces: workspaces, runDirectory: runDirectory,
            isolatedOptions: IsolatedRunOptions(
                checkpoints: checkpoints, artifactsRoot: artifacts, coverageCache: coverageCache, coverageCacheKey: coverageCacheKey,
                resultCache: resultCache, resultCacheDigest: resultCacheDigest, priorityStore: runnerPriorityStore
            )
        )

        // Rewritten with the *measured* baseline-adaptive timeout once the
        // baseline has actually run — the pre-run write above used
        // `baselineDuration: 0` as a placeholder for a strategy that scales
        // with it, which is only ever right for `.fixed`. `--replay` needs
        // the number every mutant in this run was actually held to.
        if report.baseline.passed {
            let baselineDuration = report.baseline.durationSeconds
            try? RunManifest(
                planID: loadedPlan.planID,
                workUnitID: loadedPlan.workUnitID,
                startedAt: Date(),
                resolvedDestination: (resolution.adapter as? XcodeBuildProjectAdapter)?.resolvedDestination,
                scheme: settings.project.scheme,
                testTargets: settings.tests.targets,
                extraTestArguments: settings.tests.extraArguments,
                mutantTimeoutSeconds: settings.timeouts.mutant.resolve(baselineDuration: baselineDuration),
                baselineTimeoutSeconds: settings.timeouts.baselineSeconds,
                toolchain: toolchain,
                configurationHash: settings.configurationHash,
                resourceSnapshot: resourceSnapshot,
                simulatorPreparation: simulatorPreparation
            ).write(to: manifestURL)
        }

        try emit(report, settings: settings, runDirectory: runDirectory)
        try? RunHistoryStore(root: runDirectory.appendingPathComponent("history")).record(report)

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

    /// The isolated-mode-only pieces `execute` threads into `MutationRunner`
    /// — none of these participate in schemata mode v1 (no checkpoint,
    /// coverage cache, or cross-run result cache; see the schemata
    /// production-integration plan's explicitly-out-of-scope list) —
    /// bundled so `execute` itself stays within SwiftLint's parameter-count
    /// threshold.
    private struct IsolatedRunOptions {
        let checkpoints: CheckpointStore
        let artifactsRoot: URL
        let coverageCache: CoverageProfileCache
        let coverageCacheKey: CoverageProfileCache.Key?
        let resultCache: MutationResultCache?
        let resultCacheDigest: String?
        let priorityStore: TestPriorityStore?
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
                priorityStore: isolatedOptions.priorityStore
            ).run()
        case .schemata:
            // A separate scratch subdirectory from the isolated-fallback
            // pass's `workspaces` so the two passes' sandboxes never
            // collide mid-run.
            let schemataScratch = runDirectory.appendingPathComponent("schemata-sandboxes")
            let schemataWorkspaces = try WorkspaceManager(projectRoot: context.projectRoot, scratchRoot: schemataScratch)
            return try await SchemataRunOrchestration.run(
                context: context, workspaces: workspaces, schemataWorkspaces: schemataWorkspaces,
                timeoutSeconds: context.configuration.timeouts.baselineSeconds
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

        for (kind, contents) in rendered.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let filename = filename(for: kind) else { continue }
            let url = kind == .json && output != nil
                ? URL(fileURLWithPath: output!)
                : runDirectory.appendingPathComponent(filename)
            try Data(contents.utf8).write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    /// Console and Xcode output go to the terminal, not to a file — writing them
    /// too would leave stray artifacts nobody asked for.
    private func filename(for kind: ReportKind) -> String? {
        switch kind {
        case .console, .xcode: nil
        case .json: "report.json"
        case .strykerJSON: "stryker-report.json"
        case .html: "report.html"
        case .ciSummary: "summary.md"
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
        if settings.execution.testBatchSize != nil, base is any BatchTestable {
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
