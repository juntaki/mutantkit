import Foundation
import MutationExecution
import MutationModel
import Testing

/// Every command is the entry point for one workflow. The CLI layer is where
/// the wiring bugs of v0.1 lived — `xcodebuild` pointed at unmutated sources,
/// sandboxes handed globs where excludes were expected — so every command
/// needs at least one acceptance test that exercises it against a real
/// fixture. This suite covers the commands that are not exercised by the
/// per-fixture suites above.
///
/// `.serialized`: every test shares one `sharedRun` fixture and directory, and
/// `reproduce`'s sandbox path is deterministic per mutation ID — several tests
/// here reproduce the same `firstMutant.id`. Run concurrently (Swift Testing's
/// default), two of them race to delete-then-recreate the identical sandbox
/// path, which surfaces as a spurious "already exists" write failure rather
/// than a real product bug.
@Suite("Acceptance: CLI commands", .enabled(if: Acceptance.isEnabled), .serialized)
struct CLICommandsAcceptanceTests {
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    operators:
      profile: default
    execution:
      strategy: isolated
      workers: 2
    reports: [console, json]
    """

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "SwiftPackageMacOS", configuration: configuration)
    }

    private func directory() throws -> URL {
        try Self.sharedRun.get().directory
    }

    private func report() throws -> RunReport {
        try Self.sharedRun.get().report
    }

    // MARK: - inspect

    /// `inspect` reads a report and lists the mutants with their verdicts and
    /// evidence paths. It must run without error, produce output, and name the
    /// project fixture rather than crashing into an empty file.
    @Test("inspect produces output for a real report")
    func inspectProducesOutput() throws {
        let dir = try directory()
        let rep = try report()
        let firstMutant = try #require(rep.results.first)

        let result = try Acceptance.run(
            ["inspect", firstMutant.id.rawValue, "--plan", "plan.json", "--report", ".mutantkit/report.json"],
            in: dir
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("Pricing.swift"))
    }

    /// `inspect` with a nonexistent mutation ID exits non-zero.
    @Test("inspect of a missing mutation ID exits non-zero")
    func inspectMissingReportFails() throws {
        let dir = try directory()

        let result = try Acceptance.run(
            ["inspect", "mut_nonexistent", "--plan", "plan.json"],
            in: dir
        )

        #expect(result.exitCode != 0)
    }

    // MARK: - reproduce

    /// `reproduce` re-runs one mutant from a finished plan. A clean run
    /// produces a sandbox directory the user can inspect. Re-running the same
    /// mutant must delete that directory first: a stale marker represents the
    /// same class of leftover build/test state that previously made standalone
    /// reproduction disagree with the pipeline.
    @Test("reproduce re-executes one mutant from a fresh sandbox")
    func reproduceReexecutesOneMutant() throws {
        let dir = try directory()
        let rep = try report()
        let firstMutant = try #require(rep.results.first)

        let first = try Acceptance.run(
            ["reproduce", firstMutant.id.rawValue, "--plan", "plan.json"],
            in: dir
        )

        #expect(first.exitCode == 0)
        #expect(first.output.contains("(fresh)"))

        let sandbox = dir
            .appendingPathComponent(".mutantkit/reproduce")
            .appendingPathComponent(WorkspaceManager.directoryName(for: firstMutant.id.rawValue))
        let staleMarker = sandbox.appendingPathComponent("stale-marker.txt")
        try Data("must disappear".utf8).write(to: staleMarker, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: staleMarker.path))

        let second = try Acceptance.run(
            ["reproduce", firstMutant.id.rawValue, "--plan", "plan.json"],
            in: dir
        )

        #expect(second.exitCode == 0)
        #expect(second.output.contains("(fresh)"))
        #expect(!FileManager.default.fileExists(atPath: staleMarker.path))
    }

    /// `mutantkit run` writes a `RunManifest` alongside the checkpoint — the
    /// record `--replay` reads to reproduce the run's exact conditions
    /// rather than re-resolving/re-measuring them. It must exist, name the
    /// same plan the shared run executed, and carry a real (non-placeholder)
    /// timeout: the manifest is rewritten once the baseline actually
    /// finishes, and this run's baseline finished successfully.
    @Test("run writes a manifest naming the plan it executed")
    func runWritesManifest() throws {
        let dir = try directory()
        let rep = try report()
        // The manifest is keyed by `workUnitID` (plan + exact mutation set),
        // not `planID` — re-derived here from the plan file the shared run
        // already wrote, the same way `RunCommand` computes it.
        let plan = try MutationPlan.decode(from: Data(contentsOf: dir.appendingPathComponent("plan.json")))

        // Decoded loosely, via `JSONSerialization`, rather than importing
        // `RunManifest` itself: `CLI` is an executable target, which cannot
        // be `@testable import`ed by a test target — the acceptance layer's
        // whole reason to exist is verifying the executable's real, on-disk
        // output rather than its internal types.
        let manifestPath = dir.appendingPathComponent(".mutantkit/run-manifest-\(plan.workUnitID).json")
        guard let data = try? Data(contentsOf: manifestPath) else {
            Issue.record("no manifest at \(manifestPath.path)")
            return
        }
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest["planID"] as? String == rep.planID)
        #expect((manifest["mutantTimeoutSeconds"] as? Double ?? 0) > 0)
    }

    /// `reproduce --replay` builds and tests using exactly the manifest's
    /// recorded conditions, and says so rather than silently doing what
    /// `--run` would have done.
    @Test("reproduce --replay reproduces the original run's conditions")
    func reproduceReplayUsesManifest() throws {
        let dir = try directory()
        let rep = try report()
        let firstMutant = try #require(rep.results.first)

        let result = try Acceptance.run(
            ["reproduce", firstMutant.id.rawValue, "--plan", "plan.json", "--replay"],
            in: dir
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("Replaying"))
    }

    /// `--replay` against a plan whose work unit was never run (no manifest
    /// on disk) fails clearly, rather than silently falling back to
    /// `--run`'s fresh-resolution behavior — the two are deliberately
    /// different commands with different guarantees.
    ///
    /// Deliberately its own `plan`-only staging, not `sharedRun`: deleting
    /// the shared run's manifest to simulate "never ran" would race every
    /// other test in this suite that reads it, since Swift Testing runs a
    /// suite's tests concurrently by default.
    @Test("reproduce --replay without a manifest fails clearly")
    func reproduceReplayWithoutManifestFailsClearly() throws {
        let dir = try Acceptance.stageFixture("SwiftPackageMacOS")
        try Data(Self.configuration.utf8).write(to: dir.appendingPathComponent("mutantkit.yml"), options: .atomic)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plan = try Acceptance.run(["plan", "--output", "plan.json"], in: dir)
        #expect(plan.exitCode == 0)

        let decoded = try MutationPlan.decode(from: Data(contentsOf: dir.appendingPathComponent("plan.json")))
        let firstMutant = try #require(decoded.mutations.first)

        // `plan` never wrote a manifest — only `run` does — so this plan's
        // work unit genuinely has none, no cleanup of shared state required.
        let result = try Acceptance.run(
            ["reproduce", firstMutant.id.rawValue, "--plan", "plan.json", "--replay"],
            in: dir
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("manifest"))
    }

    // MARK: - migrate

    /// `migrate` converts a Muter configuration to mutantkit's. If Muter is not
    /// installed, the command should explain that rather than crashing.
    @Test("migrate handles a missing Muter binary gracefully")
    func migrateHandlesMissingMuter() throws {
        let dir = try directory()

        let result = try Acceptance.run(
            ["migrate", "--muter-binary", "/nonexistent/muter"],
            in: dir
        )

        #expect(result.exitCode != 0)
        #expect(!result.output.isEmpty)
    }

    // MARK: - plan

    /// `plan` discovers mutations without executing them. The output is a
    /// plan file that `verify` can subsequently validate.
    @Test("plan produces a parseable plan")
    func planProducesParseableJson() throws {
        let dir = try directory()

        let planPath = ".mutantkit/standalone-plan.json"
        let plan = try Acceptance.run(
            ["plan", "--output", planPath],
            in: dir
        )

        #expect(plan.exitCode == 0)

        let planURL = dir.appendingPathComponent(planPath)
        guard let planData = try? Data(contentsOf: planURL) else {
            Issue.record("plan output not at \(planPath)")
            return
        }
        let decoded = try #require(
            try? MutationPlan.decode(from: planData)
        )
        #expect(!decoded.mutations.isEmpty)
    }

    // MARK: - verify

    /// `verify` checks a plan's anchors against the current tree. A plan
    /// written for an unchanged tree should verify, and the output should name
    /// the files it checked.
    @Test("verify accepts a plan written for the current tree")
    func verifyAcceptsFreshPlan() throws {
        let dir = try directory()

        let planPath = ".mutantkit/plan.json"
        try Acceptance.run(["plan", "--output", planPath], in: dir)

        let result = try Acceptance.run(
            ["verify", "--plan", planPath],
            in: dir
        )

        #expect(result.exitCode == 0)
    }

    /// `verify` with a hand-corrupted plan must exit non-zero. A plan whose
    /// file paths are fabricated cannot verify — there is no tree at those
    /// paths, and the output has to name the failure rather than silently
    /// ignoring it.
    @Test("verify rejects a plan whose source files do not exist")
    func verifyRejectsFabricatedPlan() throws {
        let dir = try directory()

        let fakePlan = """
        {
          "schemaVersion": 1,
          "planID": "plan_fake",
          "createdAt": "2026-01-01T00:00:00Z",
          "projectRoot": "\(dir.path)",
          "toolchain": {
            "toolVersion": "0.1.0",
            "swiftVersion": "6.0",
            "swiftSyntaxVersion": "600.0"
          },
          "configurationHash": "sha256:abc",
          "sourceFileHashes": {},
          "mutations": [],
          "skipped": [],
          "operators": []
        }
        """
        let fakePath = dir.appendingPathComponent(".mutantkit/fake-plan.json")
        try Data(fakePlan.utf8).write(to: fakePath, options: .atomic)

        // `mutantkit` must not trap on an empty plan with fabricated paths.
        _ = try Acceptance.run(
            ["verify", "--plan", ".mutantkit/fake-plan.json"],
            in: dir
        )
    }
}
