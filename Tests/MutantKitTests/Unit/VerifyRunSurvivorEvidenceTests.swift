@testable import CLI
import Foundation
@testable import MutationModel
import SwiftFrontend
import Testing

/// What `verify-run` can re-derive for a result's source edit and build
/// product from the report, the plan and the checkout, and what it must not
/// pass without.
@Suite("verify-run: survivor evidence")
struct VerifyRunSurvivorEvidenceTests {
    private static let sourceText = "struct Example {\n    func isReady() -> Bool { return true }\n}"
    private static let zeros = String(repeating: "0", count: 64)

    private struct Fixture {
        let dir: URL
        let plan: MutationPlan
        let report: RunReport

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeFixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("survivor-evidence-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("Sources/Example.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.sourceText.utf8).write(to: file)
        let point = try makeAnchoredPoint()
        let applied = try MutationApplication.apply(point, to: Data(Self.sourceText.utf8)).evidence
        let evidence = MutationEvidence(
            sourceBeforeHash: applied.sourceBeforeHash, sourceAfterHash: applied.sourceAfterHash,
            sourceDiff: applied.sourceDiff, buildProductHash: ContentHash.of("mutant-binary"),
            applicationEvidence: .isolated(.buildProductDiffersFromBaseline(
                mutantHash: ContentHash.of("mutant-binary"), baselineHash: ContentHash.of("baseline-binary")
            ))
        )
        let plan = makePlan(mutations: [point])
        let survivor = makeResult(point: point, outcome: .survived, evidence: evidence)
        return Fixture(dir: dir, plan: plan, report: makeReport(plan: plan, results: [survivor]))
    }

    private func tamper(_ report: RunReport, _ edit: (inout [String: Any]) -> Void) throws -> RunReport {
        var json = try #require(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        var results = json["results"] as? [[String: Any]] ?? []
        var evidence = results[0]["evidence"] as? [String: Any] ?? [:]
        edit(&evidence)
        results[0]["evidence"] = evidence
        json["results"] = results
        return try RunReport.decode(from: JSONSerialization.data(withJSONObject: json))
    }

    private func status(_ result: VerifyRunResult, _ name: String) -> [ReverificationCheck.Status] {
        result.checks.filter { $0.name == name }.map(\.status)
    }

    @Test("A clean survivor report verifies fully, including the re-derived source edit and build product")
    func cleanReportPasses() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let result = VerifyRunCommand.evaluate(report: fixture.report, plan: fixture.plan, root: fixture.dir)
        #expect(result.complete)
        for name in ["evidence.sourceAfter", "evidence.buildProduct", "evidence.sourceDiff"] {
            #expect(status(result, name) == [.pass], "\(name)")
        }
        #expect(VerifyRunCommand.summaryLine(for: result).hasPrefix("Fully verified"))
    }

    @Test("A survivor whose sourceAfterHash and buildProductHash were both overwritten no longer verifies")
    func overwrittenHashesFail() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let tampered = try tamper(fixture.report) { evidence in
            evidence["sourceAfterHash"] = Self.zeros
            evidence["buildProductHash"] = Self.zeros
        }
        let result = VerifyRunCommand.evaluate(report: tampered, plan: fixture.plan, root: fixture.dir)
        #expect(!result.passed)
        #expect(status(result, "evidence.sourceAfter") == [.fail])
        #expect(status(result, "evidence.buildProduct") == [.fail])
    }

    @Test("Each overwrite is caught on its own")
    func eachOverwriteFailsAlone() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let after = try tamper(fixture.report) { $0["sourceAfterHash"] = Self.zeros }
        let afterResult = VerifyRunCommand.evaluate(report: after, plan: fixture.plan, root: fixture.dir)
        #expect(status(afterResult, "evidence.sourceAfter") == [.fail])
        let product = try tamper(fixture.report) { $0["buildProductHash"] = Self.zeros }
        let productResult = VerifyRunCommand.evaluate(report: product, plan: fixture.plan, root: fixture.dir)
        #expect(status(productResult, "evidence.buildProduct") == [.fail])
    }

    @Test("A survivor recorded with the baseline's own build product is a mismatch")
    func identicalProductFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let tampered = try tamper(fixture.report) { $0["buildProductHash"] = ContentHash.of("baseline-binary") }
        let result = VerifyRunCommand.evaluate(report: tampered, plan: fixture.plan, root: fixture.dir)
        #expect(!result.passed)
        #expect(status(result, "evidence.buildProduct") == [.fail])
    }

    @Test("A diff that is not the point's edit is a mismatch")
    func foreignDiffFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let tampered = try tamper(fixture.report) { evidence in
            let diff = evidence["sourceDiff"] as? String ?? ""
            evidence["sourceDiff"] = diff.replacingOccurrences(of: "+    func isReady() -> Bool { return false }", with: "+    // nothing")
        }
        let result = VerifyRunCommand.evaluate(report: tampered, plan: fixture.plan, root: fixture.dir)
        #expect(!result.passed)
        #expect(status(result, "evidence.sourceDiff") == [.fail])
    }

    @Test("A checkout that is no longer the anchored file leaves the source edit not verifiable, never passed")
    func changedSourceIsNotVerifiable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try Data((Self.sourceText + "\n// edited later\n").utf8)
            .write(to: fixture.dir.appendingPathComponent("Sources/Example.swift"))
        let result = VerifyRunCommand.evaluate(report: fixture.report, plan: fixture.plan, root: fixture.dir)
        #expect(status(result, "evidence.sourceAfter") == [.notVerifiable])
        #expect(!result.complete)
    }

    @Test("A different baseline build product than the activation proof compared against is a mismatch")
    func foreignBaselineFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let tampered = try tamperBaseline(fixture.report)
        let result = VerifyRunCommand.evaluate(report: tampered, plan: fixture.plan, root: fixture.dir)
        #expect(!result.passed)
        #expect(status(result, "evidence.buildProduct") == [.fail])
    }

    private func tamperBaseline(_ report: RunReport) throws -> RunReport {
        var json = try #require(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        var baseline = json["baseline"] as? [String: Any] ?? [:]
        baseline["buildProductHash"] = ContentHash.of("another-baseline")
        json["baseline"] = baseline
        return try RunReport.decode(from: JSONSerialization.data(withJSONObject: json))
    }
}
