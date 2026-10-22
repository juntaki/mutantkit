import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend

// MARK: - Schemata build

extension XcodeBuildAdapter: SchemataBuildable {
    public func buildSchemataChunk(loweredSources: [SchemataSourceFile], in workspace: URL) async throws -> BuildArtifact {
        for source in loweredSources {
            try SchemataSourceWriter.write(source, in: workspace)
        }

        let target = destination()
        guard let platform = SchemataRuntimePlatform.resolve(destination: target) else {
            throw SchemataRuntimeLibraryLocator.LocatorError.unsupportedDestination(target)
        }
        let located = try SchemataRuntimeLibraryLocator.locate(for: platform)
        let linkerArguments = XcodeLinkerInjector.extraArguments(archivePath: located.archivePath)
        let buildStart = GateTimingRecorder.shared.now()
        let artifact = try await build(in: workspace, extraArguments: linkerArguments)
        await GateTimingRecorder.shared.record("chunk.build", chunkID: workspace.lastPathComponent, start: buildStart)
        return artifact
    }

    public func resolveSchemataBuildReceipt(
        for units: [SchemataCompilationUnitTargetRequest],
        artifact: BuildArtifact,
        in workspace: URL,
        context: SchemataBuildReceiptContext
    ) async throws -> SchemataBuildReceipt {
        let receiptStart = GateTimingRecorder.shared.now()
        defer {
            Task { await GateTimingRecorder.shared.record("receipt.resolve", chunkID: context.chunkID, start: receiptStart) }
        }
        // Deliberately not `destination()`: reading back where this chunk's
        // product was written must not depend on the run's device still
        // existing — see `DestinationResolver.buildSettingsDestination(for:)`.
        let buildSettingsContext = XcodeCompilationUnitImageResolver.BuildSettingsContext(
            projectArguments: projectArguments(in: workspace), scheme: try await resolveScheme(in: workspace),
            destination: DestinationResolver.buildSettingsDestination(for: destination()),
            derivedDataPath: derivedDataPath(in: workspace), workspace: workspace, timeoutSeconds: configuration.timeouts.baselineSeconds
        )
        let targetsByName = Dictionary(grouping: units, by: \.buildTarget.targetName)

        var imagesByTarget: [BuildTargetIdentity: BuiltImageReceipt] = [:]
        for (targetName, requests) in targetsByName {
            let buildTarget = requests[0].buildTarget
            let resolved = try await XcodeCompilationUnitImageResolver.resolveArtifactPath(
                target: targetName, projectIdentity: buildTarget.projectIdentity, context: buildSettingsContext
            )
            let discovered = try SchemataBuiltImageInspection.inspectSingle(at: resolved.path, bundleName: resolved.bundleName)
            imagesByTarget[buildTarget] = try BuiltImageReceipt(
                buildTarget: buildTarget, binaryPath: discovered.binaryPath, contentHash: discovered.contentHash, slices: discovered.slices
            )
        }

        let compilationUnits = units.map {
            CompilationUnitReceipt(
                compilationUnitID: $0.compilationUnitID, sourceEmbeddingID: $0.sourceEmbeddingID, buildTarget: $0.buildTarget
            )
        }

        return try SchemataBuildReceipt(
            planID: context.planID, workUnitID: context.workUnitID, chunkID: context.chunkID,
            toolchainHash: context.toolchainHash, buildArgumentsHash: context.buildArgumentsHash,
            runtimeABIVersion: UInt32(BoolLiteralSchemataLowerer.runtimeABIVersion),
            images: Array(imagesByTarget.values), compilationUnits: compilationUnits
        )
    }
}

// MARK: - Schemata test

extension XcodeBuildAdapter: SchemataTestable {
    /// Runs the already-built schemata chunk once for one requested token,
    /// without rebuilding — the Xcode analogue of `SwiftPackageMacOSAdapter
    /// .runSchemataToken`. Simulator leasing mirrors `runTests`/
    /// `leaseAndRunTests` exactly (only the test phase leases a device; a
    /// build never does).
    public func runSchemataToken(
        _ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String],
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        // Same empty-means-nil normalisation `TestSelecting.runMutant` uses
        // above: an empty selection is never sent to `-only-testing:`, which
        // would run nothing. Falls back to the full configured list, same as
        // `selectedTests == nil`.
        let filters = selectedTests.flatMap { $0.isEmpty ? nil : $0.map(\.onlyTestingArgument) }
        guard destinationNeedsSimulatorLease else {
            return try await runSchemataTokenOnDestination(
                destination(), artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, environment: environment,
                testFilters: filters
            )
        }

        do {
            return try await leaseAndRunSchemataToken(
                artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, environment: environment, testFilters: filters
            )
        } catch let error as SimulatorPoolError {
            return TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "No simulator could be leased for this schemata token run: \(error.description)"
            )
        }
    }

    /// The schemata-path counterpart to `runTestsAfterUninstall` — same
    /// reason it exists as a directly-testable, `internal` seam: proving
    /// the fail-closed uninstall contract holds for the schemata launch path too, without
    /// needing a real `SimulatorPool` lease to reach it.
    func runSchemataTokenAfterUninstall(
        lease: SimulatorLease, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double,
        environment: [String: String], testFilters: [String]?
    ) async throws -> TestRunResult {
        let uninstallStart = GateTimingRecorder.shared.now()
        let uninstallOutcome = await uninstallStaleApp(artifact: artifact, from: lease)
        await GateTimingRecorder.shared.record("token.uninstall", start: uninstallStart)
        if case let .failed(bundleID, detail) = uninstallOutcome {
            return Self.uninstallFailureResult(bundleID: bundleID, udid: lease.device.udid, detail: detail, command: artifact.command)
        }
        return try await runSchemataTokenOnDestination(
            lease.destination, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, environment: environment,
            testFilters: testFilters
        )
    }

    private func leaseAndRunSchemataToken(
        artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String], testFilters: [String]?
    ) async throws -> TestRunResult {
        @Sendable func run(_ lease: SimulatorLease) async throws -> TestRunResult {
            try await runSchemataTokenAfterUninstall(
                lease: lease, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds,
                environment: environment, testFilters: testFilters
            )
        }

        // `token.leaseAndRun.total` must keep wrapping exactly this span —
        // device selection through lease acquisition through `run`'s own
        // body — unchanged by moving the device-selection logic itself into
        // `leaseCoordinator` (plan §5.4/§8: a mark's placement must move
        // with its sub-step, never separate from it).
        let leaseAndRunStart = GateTimingRecorder.shared.now()
        defer {
            Task { await GateTimingRecorder.shared.record("token.leaseAndRun.total", start: leaseAndRunStart) }
        }
        // `preferredDevice: nil` — the schemata path never honors
        // `workerDevicesByWorkspace` (plan §5.1); see
        // `SimulatorLeaseCoordinator`'s own doc comment.
        return try await leaseCoordinator.withLease(preferredDevice: nil, rawDestination: destination(), run: run)
    }

    /// `SchemataXcodeRuntimeAcceptanceTests` already proved by hand: setting
    /// `Process.environment` on the `xcodebuild test-without-building`
    /// invocation itself does not reliably reach the actual `xctest`
    /// process Xcode's own tooling launches — env vars must be injected
    /// into the `.xctestrun` plist's `EnvironmentVariables` dictionary
    /// instead, the same mechanism a scheme's own "Environment Variables"
    /// editor pane ultimately writes to. This writes a fresh variant of
    /// `artifact`'s own `.xctestrun` with `environment` merged in, per
    /// mutant, rather than mutating the one shared file every mutant's
    /// build produced (which concurrent mutants running against the same
    /// chunk build would otherwise race on).
    /// Delegates the shared launch/timeout shape to `invocationService` (v2
    /// Step 4 §7 Step 3 — see `XCTestInvocationService`'s own doc comment).
    /// What stays here: resolving `artifact.xctestrunPath`, writing the
    /// env-merged `.xctestrun` variant (`token.xctestrunVariant`, unchanged),
    /// and classifying with the schemata path's own `token.xcresultClassify`
    /// `GateTimingRecorder` wrap — a mark the isolated path does not have
    /// (plan §5.4) — so it stays here, bracketing only the classify call, not
    /// moved into the shared service.
    private func runSchemataTokenOnDestination(
        _ destination: String, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String],
        testFilters: [String]? = nil
    ) async throws -> TestRunResult {
        guard let baseXCTestRun = artifact.xctestrunPath else {
            return TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "The build produced no .xctestrun, so there is nothing for test-without-building to run."
            )
        }

        let variantXCTestRun: URL
        let variantStart = GateTimingRecorder.shared.now()
        do {
            variantXCTestRun = try XCTestRunLocator.writingVariant(mergingEnvironment: environment, into: baseXCTestRun)
        } catch {
            return TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "Could not write a schemata .xctestrun variant: \(error)"
            )
        }
        await GateTimingRecorder.shared.record("token.xctestrunVariant", start: variantStart)

        let resultBundle = resultBundlePath(in: workspace, label: "schemata-\(UUID().uuidString)")
        let arguments = Self.testWithoutBuildingArguments(
            xctestrunPath: variantXCTestRun.path, destination: destination, resultBundlePath: resultBundle.path,
            targets: testFilters ?? configuration.tests.targets, extraArguments: configuration.tests.extraArguments
        )

        return await invocationService.runSingle(
            arguments: arguments,
            resultBundle: resultBundle,
            timeoutSeconds: timeoutSeconds,
            timeoutDiagnosis: """
            The schemata test run exceeded its \(String(format: "%.0f", timeoutSeconds))s limit \
            and was terminated.
            """,
            in: workspace
        ) {
            let classifyStart = GateTimingRecorder.shared.now()
            let outcome = await resultReader.classify(resultBundle: resultBundle, workingDirectory: workspace)
            await GateTimingRecorder.shared.record("token.xcresultClassify", start: classifyStart)
            return outcome
        }
    }
}
