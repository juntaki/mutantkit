import Foundation
import MutationModel
import Testing

/// Proves the README's documented "golden path" — the exact sequence a
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
    /// `mutantkit setup` orchestrates `init` + `doctor` in one step and is
    /// the command the README's golden path now leads with. It is exercised
    /// here exactly as documented — no flags beyond what a first-time user
    /// would type — rather than falling back to `init`+`doctor` directly:
    /// `setup` is finished and this is precisely the scenario (a configless
    /// SwiftPM project with unambiguous detection) it targets.
    @Test("setup -> dry-run -> config -> doctor -> plan -> run walks a fresh project to a trustworthy report")
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

        // 2. `mutantkit dry-run`, exactly as README's golden path puts it —
        // right after `setup`, before `plan` — builds and tests the
        // unmutated baseline once against the config `setup` just wrote.
        // This is the one command this suite's own stated purpose requires
        // and used to be missing entirely: the sequence below used to skip
        // straight to `config`/`doctor`, so a real dry-run regression could
        // pass this suite while the README's actual documented path was
        // broken.
        let dryRun = try Acceptance.run(["dry-run"], in: dir)
        #expect(dryRun.exitCode == 0, "\(dryRun.output)")
        #expect(dryRun.output.contains("Dry run passed"), "\(dryRun.output)")

        // 3. The config `setup` wrote is not just present, it is valid: the
        // same validation `mutantkit run` would refuse to proceed without.
        let config = try Acceptance.run(["config"], in: dir)
        #expect(config.exitCode == 0, "\(config.output)")
        #expect(config.output.contains("Configuration is valid."), "\(config.output)")

        // 4. `doctor`, run fresh against exactly the state `setup` left
        // behind (not reusing setup's own internal readiness check),
        // confirms the environment is independently sound: real toolchain,
        // real trial build, real trial test run.
        let doctor = try Acceptance.run(["doctor"], in: dir)
        #expect(doctor.exitCode == 0, "\(doctor.output)")

        // 5. `plan`, bounded via the documented `--max-mutants` override
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

        // 6. A small, bounded `run` against that plan produces a report
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

    /// A custom `--config` must survive into `setup`'s own suggested next
    /// commands, not just into the write path. `setup --config custom.yml`
    /// writes to `custom.yml` instead of the default `mutantkit.yml` — but
    /// every command it tells you to run next (`dry-run`, `doctor`, `plan`,
    /// ...) defaults to looking for `<projectRoot>/mutantkit.yml` when
    /// `--config` is omitted, so a suggestion that dropped the flag would
    /// send a working `setup --config custom.yml` straight into a next
    /// command that silently looks in the wrong place. This drives the
    /// literal commands `setup` prints, through the real binary, end to end
    /// — proving they actually work when followed as written, not just that
    /// the printed text happens to contain the substring `--config`.
    @Test("setup --config custom.yml's own suggested next commands work when followed literally")
    func customConfigSuggestedCommandsWorkEndToEnd() throws {
        let dir = try Acceptance.stageFixture("SwiftPackageMacOS")
        defer { try? FileManager.default.removeItem(at: dir) }

        let configName = "custom.yml"
        let configPath = dir.appendingPathComponent(configName)
        #expect(
            !FileManager.default.fileExists(atPath: configPath.path),
            "fixture must start without the custom config, or this test proves nothing"
        )

        // 1. `mutantkit setup --config custom.yml` — the destination the
        // config gets written to, and every next-step message it prints,
        // must both honor the custom path.
        //
        // The "Wrote ..." line is matched by directory-name + filename
        // rather than the full absolute path: `setup` resolves a relative
        // `--config` through the process's real (symlink-resolved) cwd,
        // e.g. `/private/var/...`, while `dir` here is built from
        // `FileManager.default.temporaryDirectory`'s un-resolved `/var/...`
        // spelling — the same macOS `/private` aliasing `standardizedFileURL`
        // elsewhere collapses back, and orthogonal to what this test checks.
        let setup = try Acceptance.run(["setup", "--config", configName], in: dir)
        #expect(setup.exitCode == 0, "\(setup.output)")
        #expect(setup.output.contains("Wrote"), "\(setup.output)")
        #expect(setup.output.contains("\(dir.lastPathComponent)/\(configName)"), "\(setup.output)")
        #expect(setup.output.contains("Ready."), "\(setup.output)")
        #expect(setup.output.contains("--config \(configName)"), "\(setup.output)")
        #expect(
            FileManager.default.fileExists(atPath: configPath.path),
            "setup reported success but wrote no \(configName)"
        )
        #expect(
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent("mutantkit.yml").path),
            "a custom --config must not also leave a default mutantkit.yml behind"
        )

        // 2. `mutantkit dry-run --config custom.yml`, typed exactly as
        // `setup` just suggested. Before the fix, `dry-run` (with no
        // `--config` of its own) would default to the missing
        // `mutantkit.yml` and fail — this is the failure this test exists
        // to catch.
        let dryRun = try Acceptance.run(["dry-run", "--config", configName], in: dir)
        #expect(dryRun.exitCode == 0, "\(dryRun.output)")
        #expect(dryRun.output.contains("Dry run passed"), "\(dryRun.output)")

        // 3. `mutantkit doctor --config custom.yml`, likewise.
        let doctor = try Acceptance.run(["doctor", "--config", configName], in: dir)
        #expect(doctor.exitCode == 0, "\(doctor.output)")

        // 4. `mutantkit plan --config custom.yml`, likewise — proves the
        // whole suggested chain works, not just its first hop.
        let plan = try Acceptance.run(
            ["plan", "--config", configName, "--output", "plan.json", "--max-mutants", "3"], in: dir
        )
        #expect(plan.exitCode == 0, "\(plan.output)")

        let planData = try Data(contentsOf: dir.appendingPathComponent("plan.json"))
        let decodedPlan = try MutationPlan.decode(from: planData)
        #expect(!decodedPlan.mutations.isEmpty, "a real, parseable plan.json needs at least one mutation point")
    }
}
