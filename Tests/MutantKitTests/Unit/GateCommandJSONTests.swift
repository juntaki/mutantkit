import ArgumentParser
@testable import CLI
import Foundation
import MutationModel
import Testing

/// P11: `mutantkit gate --json`. `QualityGateResult` is already fully
/// computed before either output path renders it (`GateCommand.run()` only
/// branches on `result.passed`/iterates `result.violations` — see that
/// file's own doc comment), so `--json` just serializes it, with the
/// `schemaVersion` `QualityGateResult` now carries.
///
/// These tests avoid capturing `GateCommand.run()`'s own stdout: Swift
/// Testing runs suites concurrently by default, and this repo has no
/// existing precedent for a shared-fd stdout-capture helper (unlike
/// `InspectCommand`/`OperatorCatalogCommand`, whose own `--json` tests
/// exercise the pure, non-printing values that feed `JSONOutput.emit`
/// directly). Coverage instead comes from two angles: the exact JSON shape
/// `--json` emits (via the same `QualityGateResult` + `JSONOutput` pair
/// `GateCommand.run()` calls), and — driving `GateCommand.parse(...).run()`
/// itself, exactly as `ExitCodeConsistencyTests` does — that the flag
/// doesn't disturb the command's exit-code contract in either direction.
@Suite("GateCommand: --json")
struct GateCommandJSONTests {
    // MARK: - JSON shape

    @Test("--json's JSON is schema-versioned and structurally valid for a passing gate")
    func passingGateJSONShape() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let result = QualityGate.evaluate(
            report: makeReport(plan: makePlan(mutations: [point]), results: [makeResult(point: point, outcome: .killedByAssertion)]),
            thresholds: QualityGateThresholds(maximumSurvivors: 0)
        )
        #expect(result.passed)

        let data = try MutationPlan.encoder().encode(result)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["schemaVersion"] as? Int == SchemaVersion.qualityGateResult)
        #expect(json["passed"] as? Bool == true)
        let violations = try #require(json["violations"] as? [[String: Any]])
        #expect(violations.isEmpty)

        let decoded = try MutationPlan.decoder().decode(QualityGateResult.self, from: data)
        #expect(decoded == result)
    }

    @Test("--json's JSON is schema-versioned and names every violation for a failing gate")
    func failingGateJSONShape() throws {
        let point = try makeAnchoredPoint(file: "Sources/B.swift")
        let result = QualityGate.evaluate(
            report: makeReport(plan: makePlan(mutations: [point]), results: [makeResult(point: point, outcome: .survived)]),
            thresholds: QualityGateThresholds(maximumSurvivors: 0)
        )
        #expect(!result.passed)

        let data = try MutationPlan.encoder().encode(result)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let violations = try #require(json["violations"] as? [[String: Any]])

        #expect(json["schemaVersion"] as? Int == SchemaVersion.qualityGateResult)
        #expect(json["passed"] as? Bool == false)
        #expect(violations.count == 1)
        #expect(violations.first?["kind"] as? String == "survivorCount")
        #expect((violations.first?["detail"] as? String)?.contains("survived") == true)

        let decoded = try MutationPlan.decoder().decode(QualityGateResult.self, from: data)
        #expect(decoded == result)
    }

    // MARK: - Exit codes still hold with --json

    @Test("gate --json against a passing report exits 0, same as the text path")
    func passingGateJSONDoesNotThrow() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion)])
        let reportPath = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: reportPath, options: .atomic)

        let command = try GateCommand.parse([
            "--report", reportPath.path, "--maximum-survivors", "0", "--json", "--project-root", dir.path
        ])
        try command.run()
    }

    @Test("gate --json against a failing report still exits MutantKitExit.qualityGateFailure")
    func failingGateJSONStillThrowsQualityGateFailure() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let point = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .survived)])
        let reportPath = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: reportPath, options: .atomic)

        let command = try GateCommand.parse([
            "--report", reportPath.path, "--maximum-survivors", "0", "--json", "--project-root", dir.path
        ])

        #expect(throws: ExitCode(MutantKitExit.qualityGateFailure)) {
            try command.run()
        }
    }

    // MARK: - Adversarial: --json must still emit valid JSON when the report can't be decoded

    /// `JSONOutput`'s own contract ("every command emits exactly one JSON
    /// document, including on error paths") did not actually hold for
    /// `gate` before this fix: `decode(reportPath:role:)` threw straight
    /// out of `run()` before the `--json` branch was ever reached, so a
    /// missing or malformed report produced a prose `Error: ...` line on
    /// stderr and no JSON at all — exactly the failure path an agent
    /// parsing `--json` output most needs structured output on. These run
    /// the real `mutantkit` binary (like `Acceptance.run`, but not gated
    /// behind `MUTANTKIT_ACCEPTANCE` — `gate` builds nothing, so there is no
    /// slow-suite reason to skip it) specifically so the assertion is on the
    /// real bytes written to stdout, not on a value `JSONOutput.emit` was
    /// merely handed.
    @Test("gate --json against a missing report file emits a valid JSONErrorEnvelope, not prose")
    func missingReportJSONEmitsErrorEnvelope() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missingPath = dir.appendingPathComponent("does-not-exist.json").path

        let (exitCode, output) = try Acceptance.run(
            ["gate", "--report", missingPath, "--json", "--project-root", dir.path],
            in: dir
        )

        #expect(exitCode == MutantKitExit.operationalError)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], "stdout was not valid JSON: \(output)")
        #expect(json["schemaVersion"] as? Int == SchemaVersion.commandError)
        #expect(json["ok"] as? Bool == false)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "reportUnreadable")
        #expect((error["message"] as? String)?.contains(missingPath) == true)
        #expect(error["remedy"] is String)
    }

    @Test("gate --json against a malformed (non-JSON) report file emits a valid JSONErrorEnvelope, not prose")
    func malformedReportJSONEmitsErrorEnvelope() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reportPath = dir.appendingPathComponent("report.json")
        try Data("{ this is not valid JSON".utf8).write(to: reportPath)

        let (exitCode, output) = try Acceptance.run(
            ["gate", "--report", reportPath.path, "--json", "--project-root", dir.path],
            in: dir
        )

        #expect(exitCode == MutantKitExit.operationalError)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], "stdout was not valid JSON: \(output)")
        #expect(json["schemaVersion"] as? Int == SchemaVersion.commandError)
        #expect(json["ok"] as? Bool == false)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "reportMalformed")
        #expect((error["message"] as? String)?.contains(reportPath.path) == true)
    }

    @Test("gate --json against a malformed --baseline report also emits a valid JSONErrorEnvelope")
    func malformedBaselineReportJSONEmitsErrorEnvelope() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion)])
        let reportPath = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: reportPath, options: .atomic)
        let baselinePath = dir.appendingPathComponent("baseline.json")
        try Data("not json at all".utf8).write(to: baselinePath)

        let (exitCode, output) = try Acceptance.run(
            ["gate", "--report", reportPath.path, "--baseline", baselinePath.path, "--json", "--project-root", dir.path],
            in: dir
        )

        #expect(exitCode == MutantKitExit.operationalError)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], "stdout was not valid JSON: \(output)")
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "reportMalformed")
        #expect((error["message"] as? String)?.contains("baseline") == true)
    }

    // MARK: - Helpers

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GateCommandJSONTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
