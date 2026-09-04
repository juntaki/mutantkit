import ArgumentParser
@testable import CLI
import Foundation
import MutationModel
import Reporting
import Testing

/// `fix-plan`/`next --format agent`: one JSON object per line (NDJSON), not
/// the earlier unquoted `key=value` line format it replaced. A mutant's own
/// `original`/`replacement` text is lifted verbatim from the mutated source
/// and can contain a space or the format's own delimiter (a ternary's own
/// text always has spaces — `flag ? 1 : 2`) — exactly the shape that made
/// the earlier format ambiguous to machine-parse. These run the real
/// `mutantkit` binary (mirroring `TrustCommandJSONTests`' own adversarial
/// cases), so the assertion is on the real bytes written to stdout, not on a
/// value `JSONOutput.compactLine` was merely handed. Not gated behind
/// `MUTANTKIT_ACCEPTANCE` — neither command builds or tests a project, same
/// as `trust`/`gate`.
@Suite("fix-plan/next --format agent: NDJSON, not delimited text")
struct AgentFormatNDJSONTests {
    @Test("fix-plan --format agent prints one JSON object per line, even for a mutant whose text has spaces")
    func fixPlanAgentFormatIsNDJSON() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let points = try discover(
            "struct Example { func pick(flag: Bool) -> Int { flag ? 1 : 2 } }", using: Operators.ternaryBranchSwap
        )
        let report = makeReport(plan: makePlan(mutations: points), results: [makeResult(point: points[0], outcome: .survived)])
        let reportPath = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: reportPath, options: .atomic)

        let (exitCode, output) = try Acceptance.run(["fix-plan", "--report", reportPath.path, "--format", "agent"], in: dir)
        #expect(exitCode == 0, "stderr/stdout: \(output)")

        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1, "one line per entry, even though the entry's own text has embedded spaces: \(output)")
        let line = try #require(lines.first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "not valid JSON: \(line)")

        // Round-trips exactly, spaces and all -- an unquoted `key=value`
        // format could not have told "original=flag ? 1 : 2 replacement=..."
        // apart from its own field boundaries.
        #expect(json["id"] as? String == points[0].id.rawValue)
        #expect(json["operator"] as? String == "swift.core.ternary-branch-swap")
        #expect(json["original"] as? String == "flag ? 1 : 2")
        #expect(json["replacement"] as? String == "flag ? 2 : 1")
        #expect(json["kind"] as? String == "ternaryBranchObservation")
        #expect(json["confidence"] as? String == "medium")
        #expect((json["reproduce"] as? String)?.contains(points[0].id.rawValue) == true)
    }

    @Test("next --format agent prints exactly one JSON object, even for a mutant whose text has spaces")
    func nextAgentFormatIsNDJSON() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let points = try discover(
            "struct Example { func pick(flag: Bool) -> Int { flag ? 1 : 2 } }", using: Operators.ternaryBranchSwap
        )
        let report = makeReport(plan: makePlan(mutations: points), results: [makeResult(point: points[0], outcome: .survived)])
        let reportPath = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: reportPath, options: .atomic)

        let (exitCode, output) = try Acceptance.run(["next", "--report", reportPath.path, "--format", "agent"], in: dir)
        #expect(exitCode == 0, "stderr/stdout: \(output)")

        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1, "one line for the single recommendation: \(output)")
        let line = try #require(lines.first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "not valid JSON: \(line)")

        #expect(json["id"] as? String == points[0].id.rawValue)
        #expect(json["original"] as? String == "flag ? 1 : 2")
        #expect(json["replacement"] as? String == "flag ? 2 : 1")
        #expect(json["candidates"] as? Int == 1)
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentFormatNDJSONTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
