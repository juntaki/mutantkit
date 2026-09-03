import ArgumentParser
@testable import CLI
import Foundation
import MutationModel
import Reporting
import Testing

/// `mutantkit trust --json`. Same shape as `GateCommandJSONTests`: `TrustReport`
/// is already fully computed before either output path renders it
/// (`TrustCommand.run()` only branches on `json`/`trust.trustworthy`), so
/// `--json` just serializes it — and the exit-code contract (`0` for a
/// trustworthy report, `MutantKitExit.integrityFailure` otherwise) must hold
/// identically whether or not `--json` was passed.
@Suite("TrustCommand: --json and exit codes")
struct TrustCommandJSONTests {
    // MARK: - JSON shape

    @Test("--json's JSON is schema-versioned and structurally valid for a trustworthy report")
    func trustworthyReportJSONShape() throws {
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let report = makeReport(plan: makePlan(mutations: [point]), results: [makeResult(point: point, outcome: .killedByAssertion)])
        let trust = TrustReport.build(from: report)
        #expect(trust.trustworthy)

        let data = try MutationPlan.encoder().encode(trust)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["schemaVersion"] as? Int == SchemaVersion.trustReport)
        #expect(json["trustworthy"] as? Bool == true)
        #expect(json["phantomMutantCount"] as? Int == 0)

        let decoded = try MutationPlan.decoder().decode(TrustReport.self, from: data)
        #expect(decoded == trust)
    }

    @Test("--json's JSON names the phantom-mutant violation for an untrustworthy report")
    func untrustworthyReportJSONShape() throws {
        let honest = try makeAnchoredPoint(file: "Sources/A.swift")
        let phantom = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [honest, phantom])
        let report = makeReport(plan: plan, results: [
            makeResult(point: honest, outcome: .killedByAssertion),
            makeResult(point: phantom, outcome: .notApplied, evidence: nil, testSummary: nil)
        ])
        let trust = TrustReport.build(from: report)
        #expect(!trust.trustworthy)

        let data = try MutationPlan.encoder().encode(trust)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["trustworthy"] as? Bool == false)
        #expect(json["phantomMutantCount"] as? Int == 1)
        #expect(json["score"] == nil || json["score"] is NSNull)
    }

    // MARK: - Exit codes still hold with --json

    @Test("trust --json against a trustworthy report exits 0, same as the text path")
    func trustworthyReportJSONDoesNotThrow() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let report = makeReport(plan: makePlan(mutations: [point]), results: [makeResult(point: point, outcome: .killedByAssertion)])
        let reportPath = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: reportPath, options: .atomic)

        let command = try TrustCommand.parse(["--report", reportPath.path, "--json", "--project-root", dir.path])
        try command.run()
    }

    @Test("trust against a trustworthy report exits 0 on the text path too")
    func trustworthyReportTextDoesNotThrow() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let report = makeReport(plan: makePlan(mutations: [point]), results: [makeResult(point: point, outcome: .killedByAssertion)])
        let reportPath = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: reportPath, options: .atomic)

        let command = try TrustCommand.parse(["--report", reportPath.path, "--project-root", dir.path])
        try command.run()
    }

    @Test("trust --json against an untrustworthy report still exits MutantKitExit.integrityFailure")
    func untrustworthyReportJSONStillThrowsIntegrityFailure() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let honest = try makeAnchoredPoint(file: "Sources/A.swift")
        let phantom = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [honest, phantom])
        let report = makeReport(plan: plan, results: [
            makeResult(point: honest, outcome: .killedByAssertion),
            makeResult(point: phantom, outcome: .notApplied, evidence: nil, testSummary: nil)
        ])
        let reportPath = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: reportPath, options: .atomic)

        let command = try TrustCommand.parse(["--report", reportPath.path, "--json", "--project-root", dir.path])
        #expect(throws: ExitCode(MutantKitExit.integrityFailure)) {
            try command.run()
        }
    }

    @Test("trust against an untrustworthy report exits MutantKitExit.integrityFailure on the text path too")
    func untrustworthyReportTextStillThrowsIntegrityFailure() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let honest = try makeAnchoredPoint(file: "Sources/A.swift")
        let phantom = try makeAnchoredPoint(file: "Sources/B.swift")
        let plan = makePlan(mutations: [honest, phantom])
        let report = makeReport(plan: plan, results: [
            makeResult(point: honest, outcome: .killedByAssertion),
            makeResult(point: phantom, outcome: .notApplied, evidence: nil, testSummary: nil)
        ])
        let reportPath = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: reportPath, options: .atomic)

        let command = try TrustCommand.parse(["--report", reportPath.path, "--project-root", dir.path])
        #expect(throws: ExitCode(MutantKitExit.integrityFailure)) {
            try command.run()
        }
    }

    // MARK: - Adversarial: --json must still emit valid JSON when the report can't be decoded

    /// Mirrors `GateCommandJSONTests.missingReportJSONEmitsErrorEnvelope`: these
    /// run the real `mutantkit` binary so the assertion is on the real bytes
    /// written to stdout, not on a value `JSONOutput.emit` was merely handed.
    /// Not gated behind `MUTANTKIT_ACCEPTANCE` — `trust` builds nothing, same
    /// as `gate`.
    @Test("trust --json against a missing report file emits a valid JSONErrorEnvelope, not prose")
    func missingReportJSONEmitsErrorEnvelope() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missingPath = dir.appendingPathComponent("does-not-exist.json").path

        let (exitCode, output) = try Acceptance.run(
            ["trust", "--report", missingPath, "--json", "--project-root", dir.path],
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

    @Test("trust --json against a malformed (non-JSON) report file emits a valid JSONErrorEnvelope, not prose")
    func malformedReportJSONEmitsErrorEnvelope() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reportPath = dir.appendingPathComponent("report.json")
        try Data("{ this is not valid JSON".utf8).write(to: reportPath)

        let (exitCode, output) = try Acceptance.run(
            ["trust", "--report", reportPath.path, "--json", "--project-root", dir.path],
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

    // MARK: - Helpers

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TrustCommandJSONTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
