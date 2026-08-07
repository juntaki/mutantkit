import AppleBuildAdapters
import ArgumentParser
import Foundation
import MutationExecution
import MutationModel
import SwiftFrontend

/// Rebuilds one mutant, alone, in a sandbox you can keep.
///
/// A surviving mutant is a claim about your tests. This is how that claim is
/// checked by hand: the same plan, the same anchor, one mutation, a directory
/// left on disk to poke at.
struct ReproduceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reproduce",
        abstract: "Apply one mutation to a sandbox so it can be investigated by hand."
    )

    @OptionGroup var common: CommonOptions
    @OptionGroup var overrides: OverrideOptions

    @Argument(help: "The mutation ID to reproduce.")
    var mutationID: String

    @Option(name: .long, help: "The plan containing the mutation.")
    var plan = "plan.json"

    @Flag(name: .long, help: "Also build and run the tests against the mutant.")
    var run = false

    @Flag(name: .long, help: """
    Build and test against the exact destination and timeout the original \
    `mutantkit run` recorded (see `RunManifest`), instead of re-resolving and \
    re-measuring them now. Implies --run.
    """)
    var replay = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        var settings = try ConfigurationLoader.load(explicitPath: common.configPath, projectRoot: root)
        try overrides.apply(to: &settings)

        try ConfigurationPreflight.run(settings)

        let loadedPlan = try MutationPlan.decode(from: Data(contentsOf: URL(fileURLWithPath: plan)))
        let id = MutationID(rawValue: mutationID)

        guard let point = loadedPlan.mutations.first(where: { $0.id == id }) else {
            print("No mutation \(id) in \(plan).")
            throw ExitCode(MutantKitExit.operationalError)
        }

        // Deliberately outside `.mutantkit/sandboxes`: the runner destroys those,
        // and the whole point of this command is a directory that survives.
        let sandboxRoot = root.appendingPathComponent(".mutantkit/reproduce")
        let workspaces = try WorkspaceManager(projectRoot: root, scratchRoot: sandboxRoot)

        // `WorkspaceManager.createSandbox` is intentionally incremental: it may
        // keep destination files whose size and mtime match, which is useful for
        // normal mutation throughput but wrong for an independent reproduction.
        // A previous reproduce attempt may contain mutated source, DerivedData,
        // generated files or test artifacts that no longer correspond to the
        // current tree. Reproduction therefore always starts by deleting the
        // deterministic sandbox path before repopulating it.
        let expectedSandbox = sandboxRoot.appendingPathComponent(
            WorkspaceManager.directoryName(for: point.id.rawValue)
        )
        if FileManager.default.fileExists(atPath: expectedSandbox.path) {
            try await workspaces.destroySandbox(at: expectedSandbox)
        }

        let sandbox = try await workspaces.createSandbox(id: point.id.rawValue)
        print("Sandbox: \(sandbox.path) (fresh)")

        let target = sandbox.appendingPathComponent(point.file)
        let applied: AppliedMutation
        do {
            applied = try MutationApplication.applyInPlace(point, fileAt: target)
        } catch let error as ApplicationError {
            print("\nCould not apply the mutation: \(error.description)")
            if error.verification != nil {
                print("""

                The anchor no longer matches, so nothing was written. The mutation is not \
                relocated to a nearby offset — that is how a tool ends up mutating the wrong \
                expression. Re-run `mutantkit plan` against the current source.
                """)
            }
            throw ExitCode(MutantKitExit.integrityFailure)
        }

        print("""

        Applied \(point.id) to \(point.file)

        \(applied.evidence.sourceDiff)
        """)

        guard run || replay else {
            print("""
            The sandbox is intact. Investigate it directly, or re-run with --run to build \
            and test the mutant here, or --replay to reproduce the original run's exact \
            destination and timeout.
            """)
            return
        }

        let resolution: AppleAdapterFactory.Resolution
        let mutantTimeoutSeconds: Double
        if replay {
            let runDirectory = root.appendingPathComponent(".mutantkit")
            let manifestURL = RunManifest.url(runDirectory: runDirectory, workUnitID: loadedPlan.workUnitID)
            let manifest: RunManifest
            do {
                manifest = try RunManifest.read(from: manifestURL)
            } catch {
                print("""

                No run manifest at \(manifestURL.path): \(error)
                --replay reproduces a specific `mutantkit run`'s exact conditions, so it needs \
                that run's manifest. Run `mutantkit run` for this plan first, or use --run to \
                build and test against the current environment's own resolution instead.
                """)
                throw ExitCode(MutantKitExit.operationalError)
            }
            print("""

            Replaying \(manifest.workUnitID)'s run from \(manifest.startedAt): \
            \(manifest.resolvedDestination?.destinationArgument ?? "(no destination to pin)"), \
            \(String(format: "%.0f", manifest.mutantTimeoutSeconds))s timeout.
            """)
            if let resolvedDestination = manifest.resolvedDestination {
                resolution = try await AppleAdapterFactory.resolve(
                    configuration: settings, in: root, replaying: resolvedDestination
                )
            } else {
                resolution = try await AppleAdapterFactory.resolve(configuration: settings, in: root)
            }
            mutantTimeoutSeconds = manifest.mutantTimeoutSeconds
        } else {
            resolution = try await AppleAdapterFactory.resolve(configuration: settings, in: root)
            mutantTimeoutSeconds = TimeoutController(settings: settings.timeouts).mutantLimitSeconds
        }

        // `reproduce`/`--replay` are standalone investigations, not part of a
        // `mutantkit run`'s lifecycle, so they have no manifest of their own to
        // carry a snapshot in — but a surprising result found here is at
        // least as likely to need "what was the machine doing" evidence as
        // one found during a full run. Printed rather than written to a
        // file: nothing here claims to be reproducible evidence the way a
        // `RunManifest` does, only a record of what this one attempt saw.
        let snapshot = ResourceSnapshot.capture(lockRoot: root.appendingPathComponent(".mutantkit/run-locks"))
        print("""

        \(snapshot.loadAverage1Minute.formatted(.number.precision(.fractionLength(2))))/\
        \(snapshot.loadAverage5Minute.formatted(.number.precision(.fractionLength(2))))/\
        \(snapshot.loadAverage15Minute.formatted(.number.precision(.fractionLength(2)))) load, \
        \(snapshot.freeMemoryBytes.map { "\($0 / 1_048_576) MB free" } ?? "memory unknown"), \
        \(snapshot.runLockFilesPresent) run lock(s) present
        """)

        print("Building…")
        let artifact: BuildArtifact
        do {
            artifact = try await resolution.adapter.build.buildMutant(applied, in: sandbox)
        } catch let failure as BuildFailure {
            // Display-only, not a scored verdict — this command builds one
            // mutant in isolation with no baseline to compare it against
            // (see the comment below), so it never reaches
            // `MutationVerdictVerifier`; the outcome names here are just the
            // ones a real build failure of each kind would eventually earn.
            let outcome: MutationOutcome = switch failure.kind {
            case .compilationError: .unviable
            case .infrastructure, .timedOut: .infrastructureFailure
            }
            print("\nOutcome: \(outcome.displayName)\n\(failure.diagnosis)")
            return
        }

        print("Testing…")
        let result = try await resolution.adapter.test.runMutant(
            point,
            artifact: artifact,
            in: sandbox,
            timeoutSeconds: mutantTimeoutSeconds
        )

        // Reported as the raw test status, not as a scored outcome. Scoring
        // needs activation evidence, and activation evidence needs a baseline
        // build to compare against — which this command deliberately does not
        // do. Synthesizing one here would mean printing a verdict backed by a
        // comparison that never happened, which is exactly the habit this tool
        // exists to break. `mutantkit run` is what produces scores.
        let counts = result.summary.map { summary in
            " — \(summary.passed) passed, \(summary.failed) failed of \(summary.total)"
        } ?? " — counts unavailable"

        print("""

        Tests: \(result.status.rawValue)\(counts)
        \(result.diagnosis)
        """)

        if let failing = result.summary?.failingTests, !failing.isEmpty {
            print("\nFailing tests")
            for test in failing.prefix(10) {
                print("  \(test)")
            }
        }

        print("""

        Build: \(artifact.command.displayString)
        Test:  \(result.command.displayString)

        Sandbox kept at \(sandbox.path)
        """)
    }
}
