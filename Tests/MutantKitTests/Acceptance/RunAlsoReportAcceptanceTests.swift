import Foundation
import Testing

/// P13 (First-party CI Action): the prototype Action forced `mutantkit run
/// --report json --report github-actions --report html --report ci-summary`,
/// which — per `RunCommand.run`'s own `--report`-overrides-the-config
/// behavior — silently discarded whatever reports the project's own
/// `mutantkit.yml` actually asked for; a config of `reports: [sonar,
/// stryker-json]` would lose both the moment the Action ran. This is the
/// end-to-end proof, against the real binary and a real fixture, that
/// `--also-report` (`RunCommand.resolvedFinalReports`/`mergedReports`) does
/// not have that problem: the config's own `sonar`/`stryker-json` outputs
/// are still written, and the CI-required kinds are written alongside them.
///
/// A standalone suite/file rather than folded into
/// `CLICommandsAcceptanceTests` purely to keep that already-large struct
/// under this project's `type_body_length` limit — no other reason to split
/// it out.
@Suite("Acceptance: run --also-report is additive, not another override", .enabled(if: Acceptance.isEnabled))
struct RunAlsoReportAcceptanceTests {
    @Test("run --also-report adds CI-required reports without discarding the project's own configured reports")
    func alsoReportPreservesConfiguredReportsAndAddsRequiredOnes() throws {
        let dir = try Acceptance.stageFixture("SwiftPackageMacOS")
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = """
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
        reports: [sonar, stryker-json]
        """
        try Data(config.utf8).write(to: dir.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let plan = try Acceptance.run(["plan", "--output", "plan.json"], in: dir)
        #expect(plan.exitCode == 0, "\(plan.output)")

        // No `--report` at all: everything reported here comes either from
        // the config above (`sonar`, `stryker-json`) or additively from
        // `--also-report` (`json`, `html`, `ci-summary`) — the exact shape
        // `action.yml`'s own CI-mode `mutantkit run` step uses. This
        // fixture's own acceptance suite (`SwiftPackageMacOSAcceptanceTests`)
        // documents 3 killed / 4 survived mutants under this exact
        // configuration — not a full kill — which is irrelevant here: this
        // test only asserts which *files* got written, never the score.
        let execution = try Acceptance.run(
            ["run", "--plan", "plan.json", "--also-report", "json", "--also-report", "html", "--also-report", "ci-summary"],
            in: dir
        )
        #expect(execution.exitCode == 0, "\(execution.output)")

        for relativePath in [
            ".mutantkit/report.json", ".mutantkit/report.html", ".mutantkit/summary.md",
            ".mutantkit/sonar-issues.json", ".mutantkit/stryker-report.json"
        ] {
            let path = dir.appendingPathComponent(relativePath).path
            #expect(
                FileManager.default.fileExists(atPath: path),
                "expected \(relativePath) to exist — config's own reports must survive --also-report"
            )
        }
    }
}
