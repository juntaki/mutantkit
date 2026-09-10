import ArgumentParser
@testable import CLI
import Foundation
import MutationModel
import Testing

/// v0.5 Stable Contracts (Agent D): a baseline referencing a mutation whose
/// operator ID has since been removed or renamed does not fail loudly — the
/// mutation simply cannot reappear in a fresh report, so `newSurvivorViolations`
/// (`QualityGate.swift`) never sees it again and it reads as "fixed" rather
/// than "not re-verified." `GateCommand.warnIfBaselineReferencesUnknownOperators`
/// closes the silent half of that gap with a stderr warning, cross-checked
/// against `MutationRegistry`'s own known operator IDs — additive only, the
/// gate's pass/fail behavior is unchanged either way.
///
/// These drive the real `mutantkit` binary (like `GateCommandJSONTests`'s own
/// adversarial cases) so the assertion is on the real bytes the process
/// writes, not on a value a pure function was merely handed. `--json` is
/// deliberately not used here: `Acceptance.run` merges stdout and stderr into
/// one stream, which would interleave the stderr warning with `--json`'s
/// single stdout JSON document and make it invalid — exactly the ordering
/// hazard `--json` output is supposed to be free of. The plain-text path has
/// no such contract to protect, so it is what these observe.
@Suite("GateCommand: baseline unknown-operator diagnostic")
struct GateCommandBaselineOperatorDiagnosticTests {
    @Test("gate --baseline referencing an unknown operator ID warns on stderr")
    func warnsOnUnknownBaselineOperator() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let unknownOperatorPoint = point.with(operatorID: "swift.core.since-removed-operator")

        let baselinePlan = makePlan(mutations: [unknownOperatorPoint])
        let baselineReport = makeReport(
            plan: baselinePlan, results: [makeResult(point: unknownOperatorPoint, outcome: .survived)]
        )
        let baselinePath = dir.appendingPathComponent("baseline.json")
        try baselineReport.encoded().write(to: baselinePath, options: .atomic)

        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion)])
        let reportPath = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: reportPath, options: .atomic)

        let (exitCode, output) = try Acceptance.run(
            ["gate", "--report", reportPath.path, "--baseline", baselinePath.path, "--project-root", dir.path],
            in: dir
        )

        #expect(exitCode == 0, "the diagnostic must not change the gate's pass/fail outcome: \(output)")
        #expect(output.contains("operator ID(s) not known to this build's registry"), "expected the warning in: \(output)")
        #expect(output.contains("swift.core.since-removed-operator"))
    }

    @Test("gate --baseline referencing only known operator IDs does not warn")
    func doesNotWarnForOrdinaryBaseline() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let point = try makeAnchoredPoint(file: "Sources/A.swift")
        let plan = makePlan(mutations: [point])
        let baselineReport = makeReport(plan: plan, results: [makeResult(point: point, outcome: .survived)])
        let baselinePath = dir.appendingPathComponent("baseline.json")
        try baselineReport.encoded().write(to: baselinePath, options: .atomic)

        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion)])
        let reportPath = dir.appendingPathComponent("report.json")
        try report.encoded().write(to: reportPath, options: .atomic)

        let (exitCode, output) = try Acceptance.run(
            ["gate", "--report", reportPath.path, "--baseline", baselinePath.path, "--project-root", dir.path],
            in: dir
        )

        #expect(exitCode == 0, "unexpected gate failure: \(output)")
        #expect(!output.contains("not known to this build's registry"), "unexpected warning in: \(output)")
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GateCommandBaselineOperatorDiagnosticTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
