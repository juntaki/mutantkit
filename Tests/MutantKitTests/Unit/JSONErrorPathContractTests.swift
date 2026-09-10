@testable import CLI
import Foundation
import MutationModel
import Testing

/// v0.5 Stable Contracts, Agent B/C findings: three commands validated an
/// early input (an unrecognized `--format`, or an unrecognized operator ID)
/// with a bare `print(...)` before ever checking `--json`, so `--json`
/// silently leaked prose on exactly the path an agent driving these
/// commands is most likely to hit by typo. Pins that all three now emit a
/// `JSONErrorEnvelope` instead, matching every other `--json` command's
/// error-path discipline (`JSONOutput.swift`'s own stated contract).
@Suite("--json error paths no longer leak prose")
struct JSONErrorPathContractTests {
    private func envelope(from output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any], "stdout was not valid JSON: \(output)")
    }

    @Test("operator-catalog --json against an unknown operator ID emits a JSONErrorEnvelope, not prose")
    func operatorCatalogUnknownIDIsJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-jsonpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (exitCode, output) = try Acceptance.run(["operator-catalog", "bogus.operator.id", "--json"], in: dir)

        #expect(exitCode == MutantKitExit.operationalError)
        let json = try envelope(from: output)
        #expect(json["schemaVersion"] as? Int == SchemaVersion.commandError)
        #expect(json["ok"] as? Bool == false)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "unknownOperator")
        #expect((error["message"] as? String)?.contains("bogus.operator.id") == true)
    }

    @Test("next --json against an unknown --format emits a JSONErrorEnvelope, not prose")
    func nextUnknownFormatIsJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-jsonpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (exitCode, output) = try Acceptance.run(["next", "--json", "--format", "bogus"], in: dir)

        #expect(exitCode == MutantKitExit.operationalError)
        let json = try envelope(from: output)
        #expect(json["schemaVersion"] as? Int == SchemaVersion.commandError)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "unknownFormat")
    }

    @Test("fix-plan --json against an unknown --format emits a JSONErrorEnvelope, not prose")
    func fixPlanUnknownFormatIsJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-jsonpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (exitCode, output) = try Acceptance.run(["fix-plan", "--json", "--format", "bogus"], in: dir)

        #expect(exitCode == MutantKitExit.operationalError)
        let json = try envelope(from: output)
        #expect(json["schemaVersion"] as? Int == SchemaVersion.commandError)
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "unknownFormat")
    }

    /// v0.5 Stable Contracts, Agent C finding: `Scripts/action/
    /// preflight-capabilities.sh` greps `mutantkit gate --help`/`mutantkit
    /// run --help`'s rendered prose for the literal substrings `--json`/
    /// `--also-report` to decide whether an installed release is new enough
    /// for `mode: ci` — nothing enforced that those substrings survive a
    /// flag rename or an ArgumentParser help-text reformat, so this pins
    /// them as a fast, local regression instead of only failing in the
    /// public action-smoke-test workflow.
    @Test("gate --help and run --help still contain the substrings preflight-capabilities.sh greps for")
    func preflightCapabilitiesGrepTargetsSurvive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-jsonpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (gateExitCode, gateHelp) = try Acceptance.run(["gate", "--help"], in: dir)
        #expect(gateExitCode == 0)
        #expect(gateHelp.contains("--json"), "Scripts/action/preflight-capabilities.sh greps `mutantkit gate --help` for '--json'")

        let (runExitCode, runHelp) = try Acceptance.run(["run", "--help"], in: dir)
        #expect(runExitCode == 0)
        #expect(
            runHelp.contains("--also-report"),
            "Scripts/action/preflight-capabilities.sh greps `mutantkit run --help` for '--also-report'"
        )
    }

    /// v0.5 Stable Contracts, Agent C finding: `oss-public/.github/workflows/
    /// action-smoke-test.yml` greps `mutantkit doctor`'s raw diagnostic
    /// prose on an empty project for the literal substrings "No Swift
    /// project found" and "Not ready" -- chosen deliberately, since
    /// `doctor --json` doesn't exist on every pinned release the Action
    /// supports. Nothing else in this codebase pinned those exact strings,
    /// so a wording change would only ever be caught by the public smoke
    /// test, not locally or in this repo's own CI unit/acceptance suites.
    @Test("doctor on an empty project still says 'No Swift project found' and 'Not ready'")
    func doctorEmptyProjectStringsSurvive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-jsonpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (exitCode, output) = try Acceptance.run(["doctor"], in: dir)

        #expect(exitCode == MutantKitExit.operationalError)
        #expect(
            output.contains("No Swift project found"),
            "oss-public/.github/workflows/action-smoke-test.yml greps doctor's output for this substring"
        )
        #expect(output.contains("Not ready"), "oss-public/.github/workflows/action-smoke-test.yml greps doctor's output for this substring")
    }
}
