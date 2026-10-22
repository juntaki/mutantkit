import Foundation
import MutationExecution
import MutationModel

// MARK: - Schemata batch testing

extension XcodeBuildAdapter: SchemataBatchTestable {
    /// Tests several already-embedded schemata tokens — all sharing the one
    /// `artifact` the chunk build produced — in a single `xcodebuild
    /// test-without-building` invocation, reusing `BatchXCTestRunBuilder`
    /// and the same private `runBatchTests`/`runBatchOnDestination` machinery
    /// `BatchTestable.runBatch` below already uses: both ultimately merge
    /// `TestConfigurations` into one `.xctestrun` and read results back via
    /// `XCResultAdapter.classifyBatch`, keyed by configuration name — the
    /// only difference is that every `BatchTestItem` here points at the
    /// *same* `xctestrunPath` instead of each mutant's own, with its own
    /// `environmentVariables` (token/runID/transcript path) standing in for
    /// what isolated mode's separate artifacts already give it for free.
    public func runSchemataTokenBatch(
        _ artifact: BuildArtifact, in workspace: URL, items: [SchemataBatchTokenItem], timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult] {
        guard let xctestrunPath = artifact.xctestrunPath else {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "The chunk build produced no .xctestrun, so there is nothing for a token batch to run."
            )
            return Dictionary(uniqueKeysWithValues: items.map { ($0.mutationID, failure) })
        }

        var batchable: [BatchTestItem] = []
        var configurationTestIdentifiers: [String: [String]] = [:]
        var idsByConfigurationName: [String: MutationID] = [:]
        // A caller-contract violation (`SchemataBatchTestable
        // .runSchemataTokenBatch`'s own doc comment: every item must
        // already have a known, non-empty selection), not a normal runtime
        // path — reported directly rather than silently dropped or, worse,
        // fed to `BatchXCTestRunBuilder.build` with an empty
        // `onlyTestingIdentifiers`, which would drop the target entirely
        // and throw `.selectionMatchesNoTarget`, failing every *other* item
        // in the same batch for one item's bad input.
        var results: [MutationID: TestRunResult] = [:]
        for item in items {
            let configurationName = item.mutationID.rawValue
            guard let selectedTests = item.selectedTests, !selectedTests.isEmpty else {
                results[item.mutationID] = TestRunResult(
                    status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                    diagnosis: "This token has no known test selection, so it cannot share a batch — it must run unbatched."
                )
                continue
            }
            batchable.append(BatchTestItem(
                configurationName: configurationName, xctestrunPath: xctestrunPath,
                onlyTestingIdentifiers: Array(selectedTests), environmentVariables: item.environment
            ))
            configurationTestIdentifiers[configurationName] = selectedTests.map(\.onlyTestingArgument)
            idsByConfigurationName[configurationName] = item.mutationID
        }

        func failAllBatchable(_ diagnosis: String) -> [MutationID: TestRunResult] {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil),
                resultArtifactPath: nil, diagnosis: diagnosis
            )
            for mutationID in idsByConfigurationName.values { results[mutationID] = failure }
            return results
        }

        guard !batchable.isEmpty else { return results }

        let batchData: Data
        do {
            batchData = try BatchXCTestRunBuilder.build(items: batchable)
        } catch {
            return failAllBatchable("The schemata token batch .xctestrun could not be constructed: \(error)")
        }

        let batchDirectory = workspace.appendingPathComponent(".mutantkit/SchemataBatches", isDirectory: true)
        let batchXCTestRunPath = batchDirectory.appendingPathComponent("schemata-batch-\(UUID().uuidString).xctestrun")
        do {
            try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
            try batchData.write(to: batchXCTestRunPath, options: .atomic)
        } catch {
            return failAllBatchable("The schemata token batch .xctestrun could not be written: \(error)")
        }

        let outcomes = await runBatchTests(
            xctestrunPath: batchXCTestRunPath, in: workspace, timeoutSeconds: timeoutSeconds,
            configurationTestIdentifiers: configurationTestIdentifiers,
            nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
        )

        for (configurationName, mutationID) in idsByConfigurationName {
            results[mutationID] = outcomes[configurationName] ?? TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil),
                resultArtifactPath: nil, diagnosis: "This token's outcome went unreported by the batch classifier."
            )
        }
        return results
    }
}

// MARK: - Batch testing

extension XcodeBuildAdapter: BatchTestable {
    public func runBatch(
        _ items: [BatchMutantItem],
        in workspace: URL,
        timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult] {
        var results: [MutationID: TestRunResult] = [:]
        var batchable: [BatchTestItem] = []
        // Only a narrowed selection can be told apart afterward: the batch
        // bundle's failures are attributed back to a configuration by
        // matching test identifiers, and a configuration left unnarrowed
        // (the full target list, `TestSelecting`'s safe fallback for an
        // unknown attribution) could legitimately run several tests —
        // there would be no way to tell whether a failure among them was a
        // plain assertion or a crash without a distinguishable identifier
        // to match. An item like that runs the ordinary, already-correct
        // unbatched way instead of joining the batch.
        var unbatched: [BatchMutantItem] = []
        // Keyed separately from `BatchTestItem.onlyTestingIdentifiers`
        // because the two serve different consumers of the same selection:
        // `BatchXCTestRunBuilder.build` needs each identifier's owning
        // target so it can narrow (or, when a bundle has none of its own
        // tests selected, drop) each `.xctestrun` target dict independently
        // — see its doc comment for why a target-qualified identifier must
        // never reach a bundle's own bare-`Class/method` `OnlyTestIdentifiers`
        // list. Failure attribution against `xcresulttool`'s batch-wide
        // `testFailures` instead needs the fully target-qualified
        // `TestIdentifier.onlyTestingArgument`, since that is the shape
        // `TestSummaryJSON.Failure.identifier` itself uses.
        var configurationTestIdentifiers: [String: [String]] = [:]

        for item in items {
            if let selectedTests = item.selectedTests, !selectedTests.isEmpty,
               let xctestrunPath = item.artifact.xctestrunPath {
                batchable.append(BatchTestItem(
                    configurationName: item.id.rawValue,
                    xctestrunPath: xctestrunPath,
                    onlyTestingIdentifiers: Array(selectedTests)
                ))
                configurationTestIdentifiers[item.id.rawValue] = selectedTests.map(\.onlyTestingArgument)
            } else {
                unbatched.append(item)
            }
        }

        results = await runUnbatched(unbatched, in: workspace, timeoutSeconds: timeoutSeconds)

        guard !batchable.isEmpty else { return results }

        let idsByConfigurationName = Dictionary(
            uniqueKeysWithValues: items.compactMap { item -> (String, MutationID)? in
                batchable.contains { $0.configurationName == item.id.rawValue } ? (item.id.rawValue, item.id) : nil
            }
        )

        func failAllBatchable(_ diagnosis: String) {
            for item in batchable {
                guard let id = idsByConfigurationName[item.configurationName] else { continue }
                results[id] = Self.batchInfrastructureFailure(in: workspace, diagnosis: diagnosis)
            }
        }

        let batchData: Data
        do {
            batchData = try BatchXCTestRunBuilder.build(items: batchable)
        } catch {
            failAllBatchable("The batch .xctestrun could not be constructed: \(error)")
            return results
        }

        let batchDirectory = workspace.appendingPathComponent(".mutantkit/Batches", isDirectory: true)
        let batchXCTestRunPath = batchDirectory.appendingPathComponent("batch-\(UUID().uuidString).xctestrun")
        do {
            try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
            try batchData.write(to: batchXCTestRunPath, options: .atomic)
        } catch {
            failAllBatchable("The batch .xctestrun could not be written: \(error)")
            return results
        }

        let outcomes = await runBatchTests(
            xctestrunPath: batchXCTestRunPath,
            in: workspace,
            timeoutSeconds: timeoutSeconds,
            configurationTestIdentifiers: configurationTestIdentifiers,
            nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
        )

        for item in batchable {
            guard let id = idsByConfigurationName[item.configurationName] else { continue }
            // Fail-closed even here: `outcomes` is keyed by every name this
            // call was asked about (see `XCResultAdapter.classifyBatch`), so
            // a missing entry only happens if that contract was violated —
            // still handled rather than trusted blindly.
            results[id] = outcomes[item.configurationName] ?? Self.batchInfrastructureFailure(
                in: workspace,
                diagnosis: "This configuration's outcome went unreported by the batch classifier."
            )
        }

        return results
    }

    /// Runs the items that could not join the batch one `xcodebuild` at a time,
    /// concurrently, the ordinary unbatched way.
    private func runUnbatched(
        _ unbatched: [BatchMutantItem],
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> [MutationID: TestRunResult] {
        var results: [MutationID: TestRunResult] = [:]
        await withTaskGroup(of: (MutationID, TestRunResult).self) { group in
            for item in unbatched {
                group.addTask {
                    let result = try? await self.runTests(
                        artifact: item.artifact, in: workspace, label: item.id.rawValue,
                        timeoutSeconds: timeoutSeconds
                    )
                    return (item.id, result ?? TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: item.artifact.command,
                        resultArtifactPath: nil, diagnosis: "The mutant's tests could not be run."
                    ))
                }
            }
            for await (id, result) in group {
                results[id] = result
            }
        }
        return results
    }

    /// A fail-closed result for a batch configuration that never produced an outcome.
    private static func batchInfrastructureFailure(in workspace: URL, diagnosis: String) -> TestRunResult {
        TestRunResult(
            status: .infrastructureFailure, summary: nil,
            command: CommandRecording.record(
                executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil
            ),
            resultArtifactPath: nil, diagnosis: diagnosis
        )
    }

    /// Leases a device (when the destination needs one) and runs the batch
    /// `.xctestrun`, the same shape `runTests`/`leaseAndRunTests` use for a
    /// single mutant.
    private func runBatchTests(
        xctestrunPath: URL,
        in workspace: URL,
        timeoutSeconds: Double,
        configurationTestIdentifiers: [String: [String]],
        nativeTimeoutAllowanceSeconds: Double? = nil
    ) async -> [String: TestRunResult] {
        @Sendable func run(destination: String) async -> [String: TestRunResult] {
            await runBatchOnDestination(
                destination, xctestrunPath: xctestrunPath, in: workspace,
                timeoutSeconds: timeoutSeconds, configurationTestIdentifiers: configurationTestIdentifiers,
                nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
            )
        }

        guard destinationNeedsSimulatorLease else {
            return await run(destination: destination())
        }

        do {
            // `preferredDevice: nil` — the batch path never honors
            // `workerDevicesByWorkspace` (plan §5.1); see
            // `SimulatorLeaseCoordinator`'s own doc comment.
            return try await leaseCoordinator.withLease(preferredDevice: nil, rawDestination: destination()) { lease in
                await run(destination: lease.destination)
            }
        } catch let error as SimulatorPoolError {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "No simulator could be leased for this batch: \(error.description)"
            )
            return Dictionary(uniqueKeysWithValues: configurationTestIdentifiers.keys.map { ($0, failure) })
        } catch {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "The batch could not be leased or run: \(error)"
            )
            return Dictionary(uniqueKeysWithValues: configurationTestIdentifiers.keys.map { ($0, failure) })
        }
    }

    /// Builds the batch invocation's own arguments (including the
    /// native-timeout-allowance injection, specific to this one call path —
    /// see `XCTestInvocationService`'s own doc comment for why there is no
    /// shared pure static for it, unlike `testWithoutBuildingArguments`) and
    /// delegates launch/timeout/classification to `invocationService` (v2
    /// Step 4 §7 Step 4). Deliberately does not remove any existing item at
    /// `resultBundle` first — unchanged from before this step: the path is
    /// already a fresh per-call UUID, so there is nothing stale at it to
    /// remove.
    private func runBatchOnDestination(
        _ destination: String,
        xctestrunPath: URL,
        in workspace: URL,
        timeoutSeconds: Double,
        configurationTestIdentifiers: [String: [String]],
        nativeTimeoutAllowanceSeconds: Double? = nil
    ) async -> [String: TestRunResult] {
        let resultBundle = workspace
            .appendingPathComponent(".mutantkit/Results", isDirectory: true)
            .appendingPathComponent("batch-\(UUID().uuidString).xcresult")
        try? FileManager.default.createDirectory(
            at: resultBundle.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        var arguments = [
            "test-without-building",
            "-xctestrun", xctestrunPath.path,
            "-destination", destination,
            "-resultBundlePath", resultBundle.path,
            "-collect-test-diagnostics", "never"
        ]
        // Containment, layered underneath `timeoutSeconds` (the outer,
        // aggregate fail-safe below, unchanged): confirmed empirically that
        // XCTest's own per-test allowance cuts a single hanging
        // configuration off — reported `.timedOut` by
        // `XCResultAdapter.classifyBatch`'s native-timeout branch — without
        // killing this `xcodebuild` invocation or losing its siblings'
        // results, so a batch no longer has to burn its *entire* combined
        // outer budget on one hang before anything is known. `nil` (every
        // caller except isolated wave batching's own multi-member batches,
        // for now) leaves `xcodebuild`'s own default (timeouts disabled)
        // untouched.
        //
        // An earlier version of this code layered a second,
        // `ProcessSupervisor`-level containment mechanism underneath this
        // one — an external, file-growth-based stall watchdog on
        // `-resultStreamPath` — for the case native per-test timeout does
        // not reliably catch (a CPU-bound, non-cooperative hang). Direct
        // content inspection of that stream on a real, long-running hang
        // batch found the hypothesis behind it was wrong: the periodic
        // writes it depended on distinguishing from "stall" turned out to
        // be genuine `testStarted`/timeout events for *additional* tests in
        // the same mutant's own covering-test list, not noise — so no
        // finite margin could ever have made file-growth a reliable "this
        // configuration is truly stuck" signal. Retired for that reason.
        // The real fix for the underlying problem (one mutant's own
        // multiple covering tests each independently hanging) turned out to
        // be a wave-based early-abort for isolated mode and a
        // single-test-only batching eligibility rule for schemata — neither
        // of which touches this function or `ProcessSupervisor`.
        if let nativeTimeoutAllowanceSeconds {
            let allowance = String(format: "%.0f", nativeTimeoutAllowanceSeconds)
            arguments.append(contentsOf: [
                "-test-timeouts-enabled", "YES",
                "-default-test-execution-time-allowance", allowance,
                "-maximum-test-execution-time-allowance", allowance
            ])
        }
        arguments.append(contentsOf: configuration.tests.extraArguments)

        return await invocationService.runBatch(
            arguments: arguments,
            resultBundle: resultBundle,
            timeoutSeconds: timeoutSeconds,
            configurationTestIdentifiers: configurationTestIdentifiers,
            in: workspace
        )
    }
}
