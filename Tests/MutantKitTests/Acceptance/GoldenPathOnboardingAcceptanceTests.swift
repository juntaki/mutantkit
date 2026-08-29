import Foundation
import MutationModel
import Testing

/// P9: proves the README's documented "golden path" — the exact sequence a
/// brand-new user or agent is told to type — actually works end to end
/// against a real, configless project, through the real `mutantkit` binary.
///
/// This is deliberately not a speed benchmark and not a unit test of any one
/// command's internals (those are covered elsewhere: `ProjectDetectionPlanTests`,
/// `SetupCommandNextStepTests`, `CLICommandsAcceptanceTests`'s per-command
/// suites). Its entire job is to catch the failure mode none of those can: the
/// individual commands each working in isolation while the *sequence* the
/// README actually tells a user to run — starting from nothing, with no
/// hand-written config and no hidden state left over from a previous run —
/// does not.
///
/// Uses `SwiftPackageMacOS`: the smallest/fastest fixture with real, uneven
/// test coverage (see `SwiftPackageMacOSAcceptanceTests`), so this suite
/// exercises a genuine build+test loop without paying a simulator's cost.
@Suite("Acceptance: clean-room golden-path onboarding", .enabled(if: Acceptance.isEnabled))
struct GoldenPathOnboardingAcceptanceTests {
    /// `mutantkit setup` orchestrates `init` + `doctor` (P9 phase 1) and is
    /// the command the README's golden path now leads with. It is exercised
    /// here exactly as documented — no flags beyond what a first-time user
    /// would type — rather than falling back to `init`+`doctor` directly:
    /// `setup` is finished and this is precisely the scenario (a configless
    /// SwiftPM project with unambiguous detection) it targets.
    @Test("setup -> config -> doctor -> plan -> run walks a fresh project to a trustworthy report")
    func goldenPathProducesATrustworthyReport() throws {
        let dir = try Acceptance.stageFixture("SwiftPackageMacOS")
        defer { try? FileManager.default.removeItem(at: dir) }

        let configPath = dir.appendingPathComponent("mutantkit.yml")
        #expect(
            !FileManager.default.fileExists(atPath: configPath.path),
            "fixture must start configless, or this test proves nothing about onboarding"
        )

        // 1. `mutantkit setup`, typed exactly as the README's golden path
        // does: no flags, no pre-existing state. This is the one step where
        // the documented path is allowed to differ from "just run the
        // binary" — everything after it is a plain, undecorated command.
        let setup = try Acceptance.run(["setup"], in: dir)
        #expect(setup.exitCode == 0, "\(setup.output)")
        #expect(setup.output.contains("Wrote \(configPath.path)"), "\(setup.output)")
        // `SwiftPackageMacOS` detects cleanly (single package, real test
        // targets, no scheme to disambiguate) — `setup` must say so and
        // point at the next command, not leave a human to guess.
        #expect(setup.output.contains("Ready."), "\(setup.output)")
        #expect(setup.output.contains("mutantkit dry-run"), "\(setup.output)")
        #expect(
            FileManager.default.fileExists(atPath: configPath.path),
            "setup reported success but wrote no mutantkit.yml"
        )

        // 2. The config `setup` wrote is not just present, it is valid: the
        // same validation `mutantkit run` would refuse to proceed without.
        let config = try Acceptance.run(["config"], in: dir)
        #expect(config.exitCode == 0, "\(config.output)")
        #expect(config.output.contains("Configuration is valid."), "\(config.output)")

        // 3. `doctor`, run fresh against exactly the state `setup` left
        // behind (not reusing setup's own internal readiness check),
        // confirms the environment is independently sound: real toolchain,
        // real trial build, real trial test run.
        let doctor = try Acceptance.run(["doctor"], in: dir)
        #expect(doctor.exitCode == 0, "\(doctor.output)")

        // 4. `plan`, bounded via the documented `--max-mutants` override
        // (not a benchmark shortcut invented for this test — it is
        // `OverrideOptions.maxMutants`, the same flag a user reaches for to
        // keep a first run small) so this proves the golden path at product
        // scale, not that seven mutations happen to be fast.
        let planPath = "plan.json"
        let plan = try Acceptance.run(["plan", "--output", planPath, "--max-mutants", "3"], in: dir)
        #expect(plan.exitCode == 0, "\(plan.output)")

        let planData = try Data(contentsOf: dir.appendingPathComponent(planPath))
        let decodedPlan = try MutationPlan.decode(from: planData)
        #expect(!decodedPlan.mutations.isEmpty, "a real, parseable plan.json needs at least one mutation point")
        #expect(decodedPlan.mutations.count <= 3, "--max-mutants 3 must actually bound the plan")
        // The budget narrowed a real, larger candidate set — proving `plan`
        // discovered the fixture's actual mutations rather than the bound
        // coincidentally matching what little there was to find.
        #expect(decodedPlan.discoveredCount > decodedPlan.mutations.count, "\(decodedPlan.discoveredCount)")

        // 5. A small, bounded `run` against that plan produces a report
        // whose own integrity mechanism — not a check this test invents —
        // reconciles: every planned mutation was applied, built, classified
        // and reported, with zero violations.
        let reportPath = ".mutantkit/report.json"
        let run = try Acceptance.run(["run", "--plan", planPath, "--report", "json"], in: dir)
        #expect(run.exitCode == 0, "\(run.output)")

        let reportData = try Data(contentsOf: dir.appendingPathComponent(reportPath))
        let report = try MutationPlan.decoder().decode(RunReport.self, from: reportData)

        #expect(report.baseline.passed, "the baseline must pass before any mutant verdict can be trusted")

        let integrity = report.integrity
        #expect(integrity.passed, "\(integrity.violations.map(\.detail))")
        #expect(integrity.planned == decodedPlan.mutations.count)
        #expect(integrity.sourceApplied == integrity.planned)
        #expect(integrity.buildObserved == integrity.planned)
        #expect(integrity.classified == integrity.planned)
        #expect(integrity.reported == integrity.planned)

        // A trustworthy report is a scored one: `MutationResult` only
        // computes `score` when `integrity.passed`, so this is the same
        // gate the product itself uses, not a separate check invented here.
        #expect(report.score != nil, "integrity passed but no score was computed")
    }
}
