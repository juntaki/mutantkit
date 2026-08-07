import AppleBuildAdapters
import ArgumentParser
import Foundation
import MutationExecution
import MutationModel

/// Builds and tests the unmutated project exactly once using the same adapters,
/// destination resolution and timeout configuration a mutation run will use.
/// This is Stryker-style dry-run validation: fail before planning hundreds of
/// mutants when the baseline environment itself is not runnable.
struct DryRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dry-run",
        abstract: "Build and test the unmutated baseline once without executing mutants."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var overrides: OverrideOptions

    func run() async throws {
        let root = common.resolvedProjectRoot
        var settings = try ConfigurationLoader.load(explicitPath: common.configPath, projectRoot: root)
        try overrides.apply(to: &settings)

        try ConfigurationPreflight.run(settings)

        let resolution = try await AppleAdapterFactory.resolve(configuration: settings, in: root)
        print("Project: \(resolution.detection.kind.rawValue) — \(resolution.detection.reason)")

        // Same preflight `run` performs before its baseline, and for the same
        // reasons: a simulator that cannot pass `bootstatus` should fail here,
        // cheaply and with an obvious cause, rather than surface as a confusing
        // build/test failure below. See RunCommand for the fuller rationale.
        let simulatorPreparation = await resolution.adapter.prepareSimulatorForRun()
        switch simulatorPreparation.outcome {
        case .notApplicable:
            break
        case .alreadyBooted, .prepared:
            print("Simulator ready (\(simulatorPreparation.outcome.rawValue)): \(simulatorPreparation.name ?? "unknown device").")
        case .failed:
            print("Simulator \(simulatorPreparation.name ?? "(unknown)") did not pass bootstatus: \(simulatorPreparation.detail ?? "unknown failure").")
            throw ExitCode(MutantKitExit.operationalError)
        }

        let runDirectory = root.appendingPathComponent(".mutantkit")
        let lockRoot = runDirectory.appendingPathComponent("run-locks")
        // Same lock namespace `run` uses: a dry run against a destination a
        // real `mutantkit run` already owns is exactly the same resource
        // contention the lock exists to prevent, not a different case.
        let runLock = try RunIsolationLock.acquire(
            projectRoot: root,
            lockRoot: lockRoot,
            destination: settings.project.destination ?? "auto"
        )
        defer { runLock.release() }
        let resourceSnapshot = ResourceSnapshot.capture(lockRoot: lockRoot)
        print("""
        \(resourceSnapshot.loadAverage1Minute.formatted(.number.precision(.fractionLength(2))))/\
        \(resourceSnapshot.loadAverage5Minute.formatted(.number.precision(.fractionLength(2))))/\
        \(resourceSnapshot.loadAverage15Minute.formatted(.number.precision(.fractionLength(2)))) load, \
        \(resourceSnapshot.freeMemoryBytes.map { "\($0 / 1_048_576) MB free" } ?? "memory unknown")
        """)

        let scratch = root.appendingPathComponent(".mutantkit/dry-run")
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: scratch)
        let id = "dry-run-baseline"
        let expected = scratch.appendingPathComponent(WorkspaceManager.directoryName(for: id))
        if FileManager.default.fileExists(atPath: expected.path) {
            try await workspaces.destroySandbox(at: expected)
        }
        let sandbox = try await workspaces.createSandbox(id: id)

        do {
            print("Building baseline…")
            let artifact: BuildArtifact
            do {
                artifact = try await resolution.adapter.build.buildBaseline(in: sandbox)
            } catch let failure as BuildFailure {
                print("Dry run build failed: \(failure.diagnosis)")
                print(failure.command.displayString)
                throw ExitCode(MutantKitExit.operationalError)
            }

            print("Testing baseline…")
            let result = try await resolution.adapter.test.runBaseline(
                artifact,
                in: sandbox,
                timeoutSeconds: settings.timeouts.baselineSeconds
            )

            guard result.status == .passed else {
                print("Dry run failed: \(result.status.rawValue) — \(result.diagnosis)")
                print(result.command.displayString)
                throw ExitCode(MutantKitExit.operationalError)
            }

            let counts = result.summary.map { "\($0.passed) passed, \($0.failed) failed of \($0.total)" }
                ?? "test counts unavailable"
            print("Dry run passed (\(counts)).")
            print("Build: \(artifact.command.displayString)")
            print("Test:  \(result.command.displayString)")
            try? await workspaces.destroySandbox(at: sandbox)
        } catch {
            try? await workspaces.destroySandbox(at: sandbox)
            throw error
        }
    }
}
