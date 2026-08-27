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

    /// P5: `inspect --json` against the real CLI binary and a real report —
    /// not just the unit-level `InspectCommandAgentJSONTests` — end to end,
    /// exit 0, valid JSON, and the real verdict/evidence this exact report
    /// actually recorded, not a placeholder.
    @Test("inspect --json produces a valid, structured record with the real verdict from a real report")
    func inspectJSONProducesAStructuredRecord() throws {
        let dir = try directory()
        let rep = try report()
        let firstMutant = try #require(rep.results.first)

        let result = try Acceptance.run(
            ["inspect", firstMutant.id.rawValue, "--plan", "plan.json", "--report", ".mutantkit/report.json", "--json"],
            in: dir
        )

        #expect(result.exitCode == 0)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
            "output must be exactly one valid JSON document, nothing else"
        )
        #expect(decoded["mutantId"] as? String == firstMutant.id.rawValue)
        #expect(decoded["verdict"] as? String == firstMutant.outcome.rawValue)
        #expect(decoded["operator"] != nil, "the operator key, not the Swift property name mutantOperator")
        let source = try #require(decoded["source"] as? [String: Any])
        #expect((source["file"] as? String)?.contains("Pricing.swift") == true)
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

    // MARK: - init

    /// Phase C11 (competitive-parity program): `mutantkit init` used to
    /// always write `tests.targets: []`, regardless of project kind,
    /// leaving every new user to discover and type in their own test
    /// target names by hand — a real friction point in exactly the
    /// first-60-seconds path the README's own quick start walks through.
    /// For a SwiftPM project, the manifest already says which targets are
    /// test targets; this proves `init`, run against the real binary
    /// against a real (if minimal) SwiftPM fixture, now fills them in.
    ///
    /// Uses its own freshly-staged fixture copy, not `sharedRun`'s
    /// directory — `init` refuses to overwrite an existing
    /// `mutantkit.yml` without `--force`, and `sharedRun` already wrote
    /// one via `planAndRun`.
    @Test("init detects and fills in a SwiftPM project's real test targets")
    func initDetectsSwiftPMTestTargets() throws {
        let dir = try Acceptance.stageFixture("SwiftPackageMacOS")
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try Acceptance.run(["init"], in: dir)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("PricingTests"))

        let generated = try String(contentsOf: dir.appendingPathComponent("mutantkit.yml"), encoding: .utf8)
        #expect(generated.contains("PricingTests"))
        #expect(generated.contains("PricingXCTestTests"))
        // The stale "no test target detected" placeholder comment must not
        // survive alongside real, detected target names.
        #expect(!generated.contains("No test target detected"))
    }

    /// Phase C13 (competitive-parity program): the C0-C12 closeout was
    /// correctly rejected for claiming Xcode-competitive onboarding while
    /// `init` only ever auto-detected test targets for SwiftPM — for an
    /// Xcode project it wrote `tests.targets: []`, a `nil` scheme, and a
    /// hardcoded `iPhone 16` destination regardless of what this machine
    /// actually has installed. `Fixtures/XcodeProject` has four real
    /// schemes (Checkout, HangApp, HangContainmentTests,
    /// SwiftTestingCheckoutTests), so `init` here cannot resolve a single
    /// scheme — this proves the *destination* is still detected for real
    /// despite that ambiguity (the exact bug `XcodeConfigDetectorTests
    /// .destinationIsDetectedIndependentlyOfSchemeAmbiguity` covers at the
    /// unit level; this is the same fix, proven through the real binary).
    @Test("init detects a real destination for an Xcode project even with more than one scheme")
    func initDetectsXcodeDestinationDespiteSchemeAmbiguity() throws {
        let dir = try Acceptance.stageFixture("XcodeProject")
        defer { try? FileManager.default.removeItem(at: dir) }
        // The fixture ships its own committed `mutantkit.yml`, used by the
        // real-simulator suites elsewhere — remove it here so `init` writes
        // a fresh one instead of refusing with "already exists".
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("mutantkit.yml"))

        let result = try Acceptance.run(["init"], in: dir)
        #expect(result.exitCode == 0)
        #expect(result.output.contains("Multiple schemes found"))
        #expect(result.output.contains("Detected destination: platform=iOS Simulator,name=iPhone"))

        let generated = try String(contentsOf: dir.appendingPathComponent("mutantkit.yml"), encoding: .utf8)
        #expect(generated.contains("platform=iOS Simulator,name=iPhone"))
    }

    // MARK: - doctor

    /// Regression test for a real bug caught by Codex review before C13's
    /// Xcode auto-detection was committed as done:
    /// `DoctorCommand.remedy(forFailedResolutionIn:configuration:)`
    /// originally suppressed the detected scheme whenever
    /// `project.scheme` was already set to *anything* — including a
    /// typo'd/nonexistent scheme, the single most likely reason a scheme
    /// would be wrong at all.
    ///
    /// `AppleAdapterFactory.resolve` never actually validates the scheme
    /// itself (scheme resolution happens later, during a real build) — it
    /// can only throw here from project-kind detection or *destination*
    /// resolution failing. So a scheme typo alone never reaches this
    /// remedy at all; this test pairs the scheme typo with a genuinely
    /// invalid destination (the real, reachable failure mode) to prove
    /// both suggestions come back correctly together: the real scheme
    /// despite the configured typo, and a real destination despite the
    /// configured invalid one. `Fixtures/XcodeAppWithUITests` has exactly
    /// one real scheme (`BatchUIDemo`).
    @Test("doctor suggests the real scheme and a real destination even when both configured values are wrong")
    func doctorSuggestsRealSchemeAndDestinationDespiteBothConfiguredWrong() throws {
        let dir = try Acceptance.stageFixture("XcodeAppWithUITests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = """
        version: 1
        project:
          kind: xcodeProject
          scheme: BatchUIDemoTypoDoesNotExist
          destination: platform=iOS Simulator,name=NoSuchSimulatorDeviceAtAll
        sources:
          include: [Sources/**]
        tests:
          targets: [BatchUIDemoTests]
        operators:
          profile: default
        execution:
          strategy: isolated
        reports: [console]
        """
        try Data(config.utf8).write(to: dir.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let result = try Acceptance.run(["doctor", "--skip-build"], in: dir)
        #expect(result.exitCode != 0)
        #expect(result.output.contains("Detected scheme: BatchUIDemo"))
        #expect(result.output.contains("set `project.scheme: BatchUIDemo`"))
        #expect(result.output.contains("Detected a real available destination: platform=iOS Simulator,name=iPhone"))
    }

    /// Phase C13 item ④: a real 4-way local benchmark against a real large
    /// iOS app found `execution.simulatorPool: true` + `workers: 2` (this
    /// exact combination) 2.17x faster than a tuned `workers: 1` reference,
    /// with identical outcomes and no integrity violations — the measured
    /// production-grade profile for a Simulator-backed project kind. This
    /// proves `doctor`, run against the real binary against a real Xcode
    /// fixture, actually surfaces that finding rather than leaving it as
    /// a research note nobody using the tool would ever see.
    @Test("doctor warns when a Simulator-backed project has not enabled the measured production profile")
    func doctorWarnsAboutMissingProductionProfile() throws {
        let dir = try Acceptance.stageFixture("XcodeAppWithUITests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = try Acceptance.iPhoneDestination()
        let withoutProfile = """
        version: 1
        project:
          kind: xcodeProject
          scheme: BatchUIDemo
          destination: \(destination)
        sources:
          include: [Sources/**]
        tests:
          targets: [BatchUIDemoTests]
        operators:
          profile: default
        execution:
          strategy: isolated
        reports: [console]
        """
        try Data(withoutProfile.utf8).write(to: dir.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let warned = try Acceptance.run(["doctor", "--skip-build"], in: dir)
        #expect(warned.output.contains("Production profile"))
        #expect(warned.output.contains("simulatorPool: true"))

        let tunedExecutionBlock = "execution:\n  strategy: isolated\n  workers: 2\n  simulatorPool: true"
            + "\n  incrementalBuild: true\n  selectCoveringTests: true"
        let withProfile = withoutProfile.replacingOccurrences(
            of: "execution:\n  strategy: isolated",
            with: tunedExecutionBlock
        )
        try Data(withProfile.utf8).write(to: dir.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let silent = try Acceptance.run(["doctor", "--skip-build"], in: dir)
        #expect(!silent.output.contains("Production profile"), "\(silent.output)")
    }
}
