import ArgumentParser
@testable import CLI
import Foundation
import MutationModel
import Testing

/// Regression coverage for two real exit-code inconsistencies found while
/// auditing this tool's "exit codes are a stable machine API" claim
/// (`MutantKitExit`'s own doc comment):
///
/// 1. Three bad-input paths threw `ArgumentParser`'s own `ValidationError`
///    (exit 64, `EX_USAGE`) instead of `MutantKitExit.operationalError`
///    (exit 1) — bypassing this tool's own exit-code contract even though
///    every other bad-input case in the same commands already used it.
/// 2. `gate`/`merge`/`verify`/`reproduce` let a JSON decode failure or
///    other file I/O error propagate unmapped, landing on
///    `ArgumentParser`'s own default failure exit code (which happens to
///    equal `operationalError` numerically, but only by coincidence).
///
/// Each test below drives the exact call site the bug lived in, not just
/// the shared helper, so a regression in the wiring — not only in
/// `MutantKitExit.onFailure` itself — would fail these.
@Suite("Exit code consistency")
struct ExitCodeConsistencyTests {
    // MARK: - 1. ValidationError → MutantKitExit.operationalError

    @Test("An unknown --profile override exits with MutantKitExit.operationalError, not a ValidationError")
    func unknownProfileOverrideExitsOperationally() throws {
        let overrides = try OverrideOptions.parse(["--profile", "not-a-real-profile"])
        var configuration = Configuration()

        #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try overrides.apply(to: &configuration)
        }
    }

    @Test("Conflicting --diff-base/--since exits with MutantKitExit.operationalError, not a ValidationError")
    func conflictingDiffBaseAndSinceExitsOperationally() throws {
        #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try PlanCommand.validateDiffBaseAndSince(diffBase: "origin/main", since: "origin/develop")
        }
    }

    @Test("Matching --diff-base/--since (the alias case) does not throw")
    func matchingDiffBaseAndSinceDoesNotThrow() throws {
        try PlanCommand.validateDiffBaseAndSince(diffBase: "origin/main", since: "origin/main")
        try PlanCommand.validateDiffBaseAndSince(diffBase: "origin/main", since: nil)
        try PlanCommand.validateDiffBaseAndSince(diffBase: nil, since: nil)
    }

    @Test("An unknown --report kind exits with MutantKitExit.operationalError, not a ValidationError")
    func unknownReportKindExitsOperationally() throws {
        #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            _ = try RunCommand.resolvedReports(from: ["not-a-real-report-kind"])
        }
    }

    @Test("Known --report kinds resolve without throwing")
    func knownReportKindsResolve() throws {
        let resolved = try RunCommand.resolvedReports(from: ["console", "json"])
        #expect(resolved == [.console, .json])
    }

    // MARK: - --also-report: additive, not another override (P13 CI Action)

    @Test("mergedReports appends additional kinds after the config's own, in order")
    func mergedReportsAppendsInOrder() {
        let merged = RunCommand.mergedReports(base: [.console, .sonar], additional: [.json, .html])
        #expect(merged == [.console, .sonar, .json, .html])
    }

    @Test("mergedReports dedupes a kind already present in the config's own reports")
    func mergedReportsDedupesAgainstBase() {
        let merged = RunCommand.mergedReports(base: [.console, .json], additional: [.json, .html])
        #expect(merged == [.console, .json, .html])
    }

    @Test("mergedReports dedupes repeats within --also-report itself")
    func mergedReportsDedupesWithinAdditional() {
        let merged = RunCommand.mergedReports(base: [.console], additional: [.json, .json, .html])
        #expect(merged == [.console, .json, .html])
    }

    @Test("mergedReports with no additional kinds returns the config's own reports untouched")
    func mergedReportsNoAdditionalIsIdentity() {
        let merged = RunCommand.mergedReports(base: [.console, .json], additional: [])
        #expect(merged == [.console, .json])
    }

    @Test("An unknown --also-report kind exits with MutantKitExit.operationalError, not a ValidationError")
    func unknownAlsoReportKindExitsOperationally() throws {
        #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            _ = try RunCommand.resolvedReports(from: ["not-a-real-report-kind"])
        }
    }

    @Test("--also-report parses as a repeatable option distinct from --report")
    func alsoReportParsesAsRepeatableOption() throws {
        let command = try RunCommand.parse([
            "--report", "console",
            "--also-report", "json", "--also-report", "github-actions"
        ])
        #expect(command.report == ["console"])
        #expect(command.alsoReport == ["json", "github-actions"])
    }

    // MARK: - 2. Unwrapped decode failures → MutantKitExit.operationalError

    @Test("MutantKitExit.onFailure maps a plain thrown error to operationalError, explicitly")
    func onFailureMapsPlainErrorsToOperationalError() {
        struct DummyDecodeFailure: Error {}

        #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            _ = try MutantKitExit.onFailure { throw DummyDecodeFailure() }
        }
    }

    @Test("MutantKitExit.onFailure passes an already-deliberate ExitCode through unchanged")
    func onFailurePassesThroughDeliberateExitCodes() {
        #expect(throws: ExitCode(MutantKitExit.integrityFailure)) {
            _ = try MutantKitExit.onFailure { () -> Int in
                throw ExitCode(MutantKitExit.integrityFailure)
            }
        }
    }

    @Test("gate against a malformed report file exits with MutantKitExit.operationalError")
    func gateMalformedReportExitsOperationally() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reportPath = dir.appendingPathComponent("report.json")
        try Data("this is not json".utf8).write(to: reportPath)

        let command = try GateCommand.parse(["--report", reportPath.path, "--project-root", dir.path])

        #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try command.run()
        }
    }

    @Test("verify against a malformed plan file exits with MutantKitExit.operationalError")
    func verifyMalformedPlanExitsOperationally() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let planPath = dir.appendingPathComponent("plan.json")
        try Data("this is not json".utf8).write(to: planPath)

        let command = try VerifyCommand.parse(["--plan", planPath.path, "--project-root", dir.path])

        await #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try await command.run()
        }
    }

    @Test("reproduce against a malformed plan file exits with MutantKitExit.operationalError")
    func reproduceMalformedPlanExitsOperationally() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let planPath = dir.appendingPathComponent("plan.json")
        try Data("this is not json".utf8).write(to: planPath)
        try Data(Self.minimalConfiguration.utf8).write(to: dir.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let command = try ReproduceCommand.parse(["mut_nonexistent", "--plan", planPath.path, "--project-root", dir.path])

        await #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try await command.run()
        }
    }

    @Test("merge against a malformed plan file exits with MutantKitExit.operationalError")
    func mergeMalformedPlanExitsOperationally() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let planPath = dir.appendingPathComponent("plan.json")
        try Data("this is not json".utf8).write(to: planPath)

        // `reports` is a required positional argument, but `run()` decodes
        // the plan before touching it — a path that does not exist never
        // gets read.
        let command = try MergeCommand.parse([
            "unused-report.json", "--plan", planPath.path, "--project-root", dir.path
        ])

        await #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try await command.run()
        }
    }

    @Test("merge against a malformed shard report exits with MutantKitExit.operationalError")
    func mergeMalformedShardReportExitsOperationally() async throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = makePlan(mutations: [])
        let planPath = dir.appendingPathComponent("plan.json")
        try plan.encoded().write(to: planPath, options: .atomic)
        let shardPath = dir.appendingPathComponent("shard.json")
        try Data("this is not json".utf8).write(to: shardPath)

        let command = try MergeCommand.parse([
            shardPath.path, "--plan", planPath.path, "--project-root", dir.path
        ])

        await #expect(throws: ExitCode(MutantKitExit.operationalError)) {
            try await command.run()
        }
    }

    // MARK: - Helpers

    private static let minimalConfiguration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    """

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MutantKit-ExitCodeConsistencyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
