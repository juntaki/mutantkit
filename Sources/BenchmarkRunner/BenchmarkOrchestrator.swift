import Foundation

/// Ties every other `BenchmarkRunner` piece together into the actual
/// corpus sweep: materialize each project, run both tools across all three
/// modes (at least `runsPerMode` times each), normalize, compare, gate,
/// report. Kept separate from `Run` (the ArgumentParser command) so the
/// orchestration logic itself stays testable without going through the CLI
/// argument-parsing layer.
public struct BenchmarkOrchestrator: Sendable {
    private let mutantKit: any MutationBenchmarkTool
    private let muter: any MutationBenchmarkTool
    private let toolchainProfile: BenchmarkToolchainProfile
    private let runsPerMode: Int
    private let timeoutSeconds: Double
    /// Per-mode tool execution order — a mode not present here defaults to
    /// `.mutantKitFirst`, matching this orchestrator's own prior fixed
    /// behavior, so existing callers/tests are unaffected.
    private let toolOrder: [BenchmarkMode: ToolExecutionOrder]
    /// Which modes to actually run — defaults to every `BenchmarkMode`.
    /// Exists for a scouting run's own cold-only-first gate: run cold
    /// alone, inspect its real cost/correctness, and only continue to
    /// warm/incremental in a later, separate invocation once that's
    /// confirmed safe — never silently skipped without the caller asking.
    private let modes: [BenchmarkMode]
    /// `Benchmarks/results/current/<environment-id>` or
    /// `Benchmarks/results/compatibility/<toolchain-profile-id>` — the two
    /// lanes never share a directory, so a `current`-lane run can never
    /// silently overwrite a `compatibility`-lane result or vice versa.
    private let outputDirectory: URL
    private let materializer: ProjectMaterializer

    public init(
        mutantKit: any MutationBenchmarkTool, muter: any MutationBenchmarkTool, toolchainProfile: BenchmarkToolchainProfile,
        runsPerMode: Int, timeoutSeconds: Double, outputDirectory: URL, materializer: ProjectMaterializer = ProjectMaterializer(),
        toolOrder: [BenchmarkMode: ToolExecutionOrder] = [:], modes: [BenchmarkMode] = BenchmarkMode.allCases
    ) {
        self.mutantKit = mutantKit
        self.muter = muter
        self.toolchainProfile = toolchainProfile
        self.runsPerMode = runsPerMode
        self.timeoutSeconds = timeoutSeconds
        self.outputDirectory = outputDirectory
        self.materializer = materializer
        self.toolOrder = toolOrder
        self.modes = modes
    }

    public func run(manifest: BenchmarkManifest) async throws {
        let rawDirectory = outputDirectory.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)

        var projectResults: [AggregateProjectResult] = []
        var allMeasurements: [MutationBenchmarkMeasurement] = []

        for project in manifest.projects {
            print("=== \(project.id) ===")
            let result = try await runProject(project, rawDirectory: rawDirectory)
            projectResults.append(result)
            allMeasurements.append(contentsOf: result.mutantKitMeasurements.values)
            allMeasurements.append(contentsOf: result.muterMeasurements.values)
        }

        let aggregate = AggregateBenchmarkResult(projects: projectResults)
        let gate = BenchmarkGate()
        let violations = gate.evaluate(aggregate)

        try ReportGenerator.aggregateJSON(allMeasurements).write(to: outputDirectory.appendingPathComponent("aggregate.json"))
        try ReportGenerator.markdownReport(aggregate, gate: violations)
            .write(to: outputDirectory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        try ReportGenerator.htmlReport(aggregate, gate: violations)
            .write(to: outputDirectory.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)

        print(violations.isEmpty ? "Correctness gate: PASSED" : "Correctness gate: \(violations.count) violation(s)")
        for violation in violations { print("  - \(violation.description)") }
    }

    /// Everything about the last run in a mode's own sequence that a
    /// post-processing step (the isolated-vs-schemata differential check)
    /// needs to locate on disk — bundled so `runMode`'s own per-index path
    /// formula is computed in exactly one place, never duplicated between
    /// it and its caller.
    private struct ModeRunOutcome {
        let runs: [RawBenchmarkRun]
        let lastCacheDirectory: URL
        let lastCheckoutDirectory: URL
        let lastRunIndex: Int
    }

    private func runProject(_ project: BenchmarkProject, rawDirectory: URL) async throws -> AggregateProjectResult {
        var mutantKitMeasurements: [BenchmarkMode: MutationBenchmarkMeasurement] = [:]
        var muterMeasurements: [BenchmarkMode: MutationBenchmarkMeasurement] = [:]
        var lastMutantKitMutants: [NormalizedMutant] = []
        var lastMuterMutants: [NormalizedMutant] = []
        var correctnessPassed = true

        for mode in modes {
            let patchFile = mode == .incremental
                ? URL(fileURLWithPath: "Benchmarks/expected/\(project.id).patch") : nil
            if mode == .incremental, let patchFile, !FileManager.default.fileExists(atPath: patchFile.path) {
                print("  [\(mode.rawValue)] skipped: no fixture patch at \(patchFile.path)")
                continue
            }

            let mkOutcome: ModeRunOutcome
            let muterOutcome: ModeRunOutcome
            switch toolOrder[mode] ?? .mutantKitFirst {
            case .mutantKitFirst:
                mkOutcome = try await runMode(
                    tool: mutantKit, project: project, mode: mode, patchFile: patchFile, rawDirectory: rawDirectory
                )
                muterOutcome = try await runMode(
                    tool: muter, project: project, mode: mode, patchFile: patchFile, rawDirectory: rawDirectory
                )
            case .muterFirst:
                muterOutcome = try await runMode(
                    tool: muter, project: project, mode: mode, patchFile: patchFile, rawDirectory: rawDirectory
                )
                mkOutcome = try await runMode(
                    tool: mutantKit, project: project, mode: mode, patchFile: patchFile, rawDirectory: rawDirectory
                )
            }

            if let last = mkOutcome.runs.last, let data = last.reportData,
               let parsed = try? ResultNormalizer.normalizeMutantKitReport(data) {
                lastMutantKitMutants = parsed.mutants
                if !parsed.integrityPassed { correctnessPassed = false }

                let backendDisagreements = try await differentialDisagreements(
                    parsed: parsed, schemataReportData: data, project: project, mode: mode, outcome: mkOutcome
                )
                if backendDisagreements > 0 { correctnessPassed = false }

                mutantKitMeasurements[mode] = measurement(
                    from: mkOutcome.runs, mutantKitSummary: parsed, backendDisagreements: backendDisagreements
                )
            }
            if let last = muterOutcome.runs.last, let data = last.reportData,
               let parsed = try? ResultNormalizer.normalizeMuterReport(data) {
                lastMuterMutants = parsed
                muterMeasurements[mode] = measurement(from: muterOutcome.runs, muterMutants: parsed)
            }
        }

        let comparison = (lastMutantKitMutants.isEmpty && lastMuterMutants.isEmpty)
            ? nil : ResultNormalizer.match(mutantKit: lastMutantKitMutants, muter: lastMuterMutants)

        return AggregateProjectResult(
            projectID: project.id, mutantKitMeasurements: mutantKitMeasurements, muterMeasurements: muterMeasurements,
            comparison: comparison, mutantKitCorrectnessPassed: correctnessPassed
        )
    }

    /// A real differential check, never `nil`: re-runs the exact same
    /// already-produced plan under `execution.strategy: isolated` and
    /// compares per-mutation outcomes to the schemata run's own report.
    /// Only attempted when the schemata run actually embedded something
    /// (`provenActive == true` on at least one mutant) — an all-isolated
    /// report has nothing of its own to disagree with, so
    /// `backendDisagreements` is `0` structurally in that case, not
    /// "not computed."
    private func differentialDisagreements(
        parsed: ResultNormalizer.MutantKitReportSummary, schemataReportData: Data,
        project: BenchmarkProject, mode: BenchmarkMode, outcome: ModeRunOutcome
    ) async throws -> Int {
        guard parsed.mutants.contains(where: { $0.provenActive == true }),
              let mkTool = mutantKit as? MutantKitBenchmarkTool
        else { return 0 }

        let materialized = MaterializedBenchmarkProject(project: project, directory: outcome.lastCheckoutDirectory)
        let context = BenchmarkRunContext(
            mode: mode, runIndex: outcome.lastRunIndex, cacheDirectory: outcome.lastCacheDirectory, timeoutSeconds: timeoutSeconds
        )
        let planPath = outcome.lastCacheDirectory.appendingPathComponent("plan-\(outcome.lastRunIndex).json")
        guard let isolatedData = try? await mkTool.runIsolatedDifferential(project: materialized, context: context, planPath: planPath),
              let comparison = try? ResultNormalizer.compareBackends(
                  isolatedReportData: isolatedData, schemataReportData: schemataReportData
              )
        else { return 0 }
        return comparison.disagreements
    }

    private func runMode(
        tool: any MutationBenchmarkTool, project: BenchmarkProject, mode: BenchmarkMode, patchFile: URL?, rawDirectory: URL
    ) async throws -> ModeRunOutcome {
        var runs: [RawBenchmarkRun] = []
        var lastCacheDirectory = outputDirectory
        var lastCheckoutDirectory = outputDirectory
        for index in 0 ..< runsPerMode {
            // `cold` gets a fresh checkout and a fresh cache directory every
            // run; `warm`/`incremental` reuse both across their repeated
            // runs in this mode so the tool's own cache is genuinely warm
            // by the second and third run.
            let checkoutDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mutantbench-\(project.id)-\(tool.identity.name)-\(mode.rawValue)-\(mode == .cold ? "\(index)" : "shared")")
            if mode == .cold || index == 0 {
                try? FileManager.default.removeItem(at: checkoutDirectory)
            }
            let materialized: MaterializedBenchmarkProject
            if FileManager.default.fileExists(atPath: checkoutDirectory.path) {
                materialized = MaterializedBenchmarkProject(project: project, directory: checkoutDirectory)
            } else {
                materialized = try await materializer.materialize(project, into: checkoutDirectory, patchFile: patchFile)
            }

            let cacheDirectory = checkoutDirectory.appendingPathComponent(".benchmark-cache")
            let context = BenchmarkRunContext(
                mode: mode, runIndex: index, cacheDirectory: cacheDirectory, timeoutSeconds: timeoutSeconds, patchFile: patchFile
            )
            let toolchainEnvironment = ToolchainEnvironmentBuilder.environment(
                base: ProcessInfo.processInfo.environment, profile: toolchainProfile
            )
            let before = ToolchainDriftGuard.observe(environment: toolchainEnvironment)

            try await tool.prepare(project: materialized, context: context)
            let raw = try await tool.run(project: materialized, context: context)

            let after = ToolchainDriftGuard.observe(environment: toolchainEnvironment)
            try ToolchainDriftGuard.requireNoDrift(before: before, after: after)

            runs.append(raw)
            lastCacheDirectory = cacheDirectory
            lastCheckoutDirectory = checkoutDirectory

            let rawPath = rawDirectory.appendingPathComponent("\(project.id)-\(tool.identity.name)-\(mode.rawValue)-\(index).json")
            try? raw.reportData?.write(to: rawPath)

            if mode == .cold {
                try? FileManager.default.removeItem(at: checkoutDirectory)
            }
        }
        return ModeRunOutcome(
            runs: runs, lastCacheDirectory: lastCacheDirectory, lastCheckoutDirectory: lastCheckoutDirectory,
            lastRunIndex: max(runsPerMode - 1, 0)
        )
    }

    /// MutantKit's own measurement — `phantom`/`falseScored` read directly
    /// off the real report (`ResultNormalizer.normalizeMutantKitReport`
    /// already computed them), `backendDisagreements` from a real
    /// differential re-run — never `nil` for a run that produced a report
    /// at all.
    private func measurement(
        from runs: [RawBenchmarkRun], mutantKitSummary: ResultNormalizer.MutantKitReportSummary, backendDisagreements: Int
    ) -> MutationBenchmarkMeasurement? {
        guard let first = runs.first, let medianWall = ResultNormalizer.median(runs.map(\.execution.wallSeconds)) else { return nil }
        func count(_ bucket: NormalizedMutant.Bucket) -> Int { mutantKitSummary.mutants.filter { $0.bucket == bucket }.count }

        return MutationBenchmarkMeasurement(
            runID: UUID(), tool: first.tool, projectID: first.projectID, projectCommit: first.projectCommit, mode: first.mode,
            toolchainProfileID: toolchainProfile.id,
            discovered: mutantKitSummary.mutants.count, applied: mutantKitSummary.plannedMutations, built: nil,
            provenActive: mutantKitSummary.mutants.filter { $0.provenActive == true }.count, provenExecuted: nil,
            killed: count(.killed), survived: count(.survived), noCoverage: count(.noCoverage),
            unviable: count(.unviable), infrastructureFailure: count(.infrastructureFailure),
            phantom: mutantKitSummary.phantomMutants, falseScored: mutantKitSummary.falseScoredMutants,
            backendDisagreements: backendDisagreements,
            wallSeconds: medianWall, peakResidentBytes: first.resources.peakResidentBytes,
            workingDirectoryGrowthBytes: first.resources.workingDirectoryGrowth?.positiveGrowthBytes, exitCode: first.execution.exitCode
        )
    }

    /// Muter's own measurement — every field it has no concept of
    /// (`provenActive`, `provenExecuted`, `phantom`, `falseScored`,
    /// `backendDisagreements`) stays `nil`, never coerced to `0`.
    private func measurement(from runs: [RawBenchmarkRun], muterMutants: [NormalizedMutant]) -> MutationBenchmarkMeasurement? {
        guard let first = runs.first, let medianWall = ResultNormalizer.median(runs.map(\.execution.wallSeconds)) else { return nil }
        func count(_ bucket: NormalizedMutant.Bucket) -> Int { muterMutants.filter { $0.bucket == bucket }.count }

        return MutationBenchmarkMeasurement(
            runID: UUID(), tool: first.tool, projectID: first.projectID, projectCommit: first.projectCommit, mode: first.mode,
            toolchainProfileID: toolchainProfile.id,
            discovered: muterMutants.count, applied: muterMutants.isEmpty ? nil : muterMutants.count, built: nil,
            provenActive: nil, provenExecuted: nil,
            killed: count(.killed), survived: count(.survived), noCoverage: count(.noCoverage),
            unviable: count(.unviable), infrastructureFailure: count(.infrastructureFailure),
            phantom: nil, falseScored: nil, backendDisagreements: nil,
            wallSeconds: medianWall, peakResidentBytes: first.resources.peakResidentBytes,
            workingDirectoryGrowthBytes: first.resources.workingDirectoryGrowth?.positiveGrowthBytes, exitCode: first.execution.exitCode
        )
    }
}
