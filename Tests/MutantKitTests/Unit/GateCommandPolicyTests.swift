import ArgumentParser
@testable import CLI
import Foundation
import MutationModel
import Testing

/// The gate must never turn an unresolvable quality policy into "no policy".
/// A report that violates configured thresholds must not pass because the
/// config path was mistyped, unreadable, or the merged values are nonsense.
@Suite("GateCommand: policy resolution")
struct GateCommandPolicyTests {
    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GateCommandPolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFailingReport(in dir: URL) throws -> URL {
        let point = try makeAnchoredPoint(file: "Sources/B.swift")
        let report = makeReport(plan: makePlan(mutations: [point]), results: [makeResult(point: point, outcome: .survived)])
        let path = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: path, options: .atomic)
        return path
    }

    @Test("an explicit --config that does not exist is an operational error, not an empty policy")
    func explicitMissingConfigFails() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reportPath = try writeFailingReport(in: dir)
        let command = try GateCommand.parse([
            "--report", reportPath.path, "--config", dir.appendingPathComponent("typo.yml").path,
            "--project-root", dir.path
        ])
        #expect(throws: ExitCode(MutantKitExit.operationalError)) { try command.run() }
    }

    @Test("no config at all still works flag-only and enforces the flags")
    func noConfigFlagOnlyStillEnforces() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reportPath = try writeFailingReport(in: dir)
        let command = try GateCommand.parse([
            "--report", reportPath.path, "--maximum-survivors", "0", "--project-root", dir.path
        ])
        #expect(throws: ExitCode(MutantKitExit.qualityGateFailure)) { try command.run() }
    }

    @Test("a default mutantkit.yml that cannot be parsed is an operational error (regression guard)")
    func invalidDefaultConfigFails() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reportPath = try writeFailingReport(in: dir)
        try "qualityGate: [not, a, mapping".write(
            to: dir.appendingPathComponent("mutantkit.yml"), atomically: true, encoding: .utf8
        )
        let command = try GateCommand.parse(["--report", reportPath.path, "--project-root", dir.path])
        #expect(throws: ExitCode(MutantKitExit.operationalError)) { try command.run() }
    }

    @Test("out-of-range or negative merged thresholds are rejected")
    func invalidThresholdsRejected() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reportPath = try writeFailingReport(in: dir)
        for flags in [["--minimum-tested=800"], ["--minimum-effective=-5"], ["--minimum-tested=nan"],
                      ["--maximum-survivors=-1"], ["--new-survivors-maximum=-2"], ["--regression-maximum-drop=inf"]] {
            let command = try GateCommand.parse(["--report", reportPath.path, "--project-root", dir.path] + flags)
            #expect(throws: ExitCode(MutantKitExit.operationalError), "\(flags)") { try command.run() }
        }
    }

    @Test("threshold validation accepts boundaries and rejects bad values")
    func validateBoundaries() throws {
        try QualityGateThresholds(
            minimumTested: 0, minimumEffective: 1, maximumSurvivors: 0,
            regressionMaximumDrop: 0.5, newSurvivorsMaximum: 0
        ).validate()
        #expect(throws: QualityGateThresholdError.self) { try QualityGateThresholds(minimumTested: 1.01).validate() }
        #expect(throws: QualityGateThresholdError.self) { try QualityGateThresholds(minimumEffective: .nan).validate() }
        #expect(throws: QualityGateThresholdError.self) { try QualityGateThresholds(maximumSurvivors: -1).validate() }
    }

    @Test("gate --json with an explicit missing --config emits a policy error envelope")
    func explicitMissingConfigJSONEnvelope() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reportPath = try writeFailingReport(in: dir)
        let (exitCode, output) = try Acceptance.run(
            ["gate", "--report", reportPath.path, "--config", dir.appendingPathComponent("typo.yml").path,
             "--json", "--project-root", dir.path],
            in: dir
        )
        #expect(exitCode == MutantKitExit.operationalError)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], "stdout was not valid JSON: \(output)")
        #expect(json["ok"] as? Bool == false)
        #expect((json["error"] as? [String: Any])?["code"] as? String == "policyUnavailable")
    }
}
