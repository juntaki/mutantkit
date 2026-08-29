import Foundation
import MutationModel
import Testing

/// Differential acceptance gate for wave-based early kill.
///
/// This suite intentionally runs the same real `.xcodeproj` three ways:
/// ordinary batching, incremental ordinary batching, and incremental wave
/// execution. MutationID-level classification must be identical across all
/// three. The fixture's two coupon tests are split so one relational mutant
/// is detected in wave 1 while the other passes wave 1 and is detected in
/// wave 2; this proves a real multi-wave path rather than merely enabling the
/// flag and receiving the same one-shot batch.
@Suite("Acceptance: Xcode wave-based early kill", .enabled(if: Acceptance.waveEnabled))
struct XcodeWaveEarlyKillAcceptanceTests {
    private struct Runs {
        let ordinaryBatch: AcceptanceRun
        let incrementalBatch: AcceptanceRun
        let wave: AcceptanceRun
    }

    private struct PrioritySnapshot: Decodable {
        let detections: [String: Int]
    }

    private static func configuration(incremental: Bool, wave: Bool) throws -> String {
        var lines = [
            "version: 1",
            "project:",
            "  kind: xcodeProject",
            "  scheme: Checkout",
            "  destination: \(try Acceptance.iPhoneDestination())",
            "sources:",
            "  include: [Sources/**]",
            "tests:",
            "  targets: [CheckoutTests]",
            "operators:",
            "  profile: default",
            "execution:",
            "  strategy: isolated",
            "  workers: 2",
            "  selectCoveringTests: true"
        ]
        if incremental {
            lines.append("  incrementalBuild: true")
        }
        if wave {
            lines.append("  earlyAbortSelectedTests: true")
        }
        lines.append("  testBatchSize: 10")
        lines.append("reports: [console, json]")
        return lines.joined(separator: "\n") + "\n"
    }

    private static let sharedRuns = Result {
        Runs(
            ordinaryBatch: try Acceptance.planAndRun(
                fixture: "XcodeProject",
                configuration: configuration(incremental: false, wave: false),
                extraRunArguments: ["--no-resume"]
            ),
            incrementalBatch: try Acceptance.planAndRun(
                fixture: "XcodeProject",
                configuration: configuration(incremental: true, wave: false),
                extraRunArguments: ["--no-resume"]
            ),
            wave: try Acceptance.planAndRun(
                fixture: "XcodeProject",
                configuration: configuration(incremental: true, wave: true),
                extraRunArguments: ["--no-resume"]
            )
        )
    }

    private func runs() throws -> Runs {
        try Self.sharedRuns.get()
    }

    private func outcomes(_ run: AcceptanceRun) -> [MutationID: MutationOutcome] {
        Dictionary(uniqueKeysWithValues: run.report.results.map { ($0.id, $0.outcome) })
    }

    private func mismatchDescription(
        reference: [MutationID: MutationOutcome],
        candidate: [MutationID: MutationOutcome]
    ) -> String {
        let ids = Set(reference.keys).union(candidate.keys).sorted()
        return ids.compactMap { id in
            let lhs = reference[id]
            let rhs = candidate[id]
            guard lhs != rhs else { return nil }
            return "\(id.rawValue): \(lhs?.rawValue ?? "missing") → \(rhs?.rawValue ?? "missing")"
        }.joined(separator: "\n")
    }

    @Test("Ordinary, incremental, and wave execution classify every MutationID identically")
    func classificationMatchesAllReferencePaths() throws {
        let runs = try runs()

        for run in [runs.ordinaryBatch, runs.incrementalBatch, runs.wave] {
            #expect(run.report.integrity.violations.isEmpty, "\(run.report.integrity.violations.map(\.detail))")
        }

        let reference = outcomes(runs.ordinaryBatch)
        let incremental = outcomes(runs.incrementalBatch)
        let wave = outcomes(runs.wave)

        #expect(
            incremental == reference,
            "Incremental batching changed classification:\n\(mismatchDescription(reference: reference, candidate: incremental))"
        )
        #expect(
            wave == reference,
            "Wave execution changed classification:\n\(mismatchDescription(reference: reference, candidate: wave))"
        )
    }

    @Test("The real Xcode run advances one surviving mutant into a second wave")
    func realRunUsesTwoWaves() throws {
        let wave = try runs().wave
        let summary = try #require(wave.report.batchExecution)

        // Wave 1 tests both covered mutants with testCouponAboveMinimum:
        // `>=` → `<` dies, `>=` → `>` survives. Wave 2 tests only the latter
        // with testCouponAtMinimum, where it dies. Uncovered mutants take the
        // noCoverage fast path and never enter a batch.
        #expect(summary.batchCount == 2)
        #expect(summary.totalConfigurations == 3)
        #expect(summary.averageConfigurationsPerBatch == 1.5)
        #expect(summary.batchDurations.count == 2)

        #expect(wave.killed == [
            .init(declaration: "canApplyCoupon(subtotal:)", original: ">=", replacement: ">"),
            .init(declaration: "canApplyCoupon(subtotal:)", original: ">=", replacement: "<")
        ])
    }

    @Test("Each wave witness is credited exactly once in the persisted priority history")
    func priorityHistoryProvesBothWaveWitnessesRan() throws {
        let wave = try runs().wave
        let url = wave.directory.appendingPathComponent(".mutantkit/test-priority.json")
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(PrioritySnapshot.self, from: data)

        // `TestIdentifier.onlyTestingArgument` always appends `()` to the
        // method name (`PerTestCoverageMap.swift:46`) -- the real, correct
        // XCTest `-only-testing:` argument shape.
        #expect(snapshot.detections["CheckoutTests/CheckoutTests/testCouponAboveMinimum()"] == 1)
        #expect(snapshot.detections["CheckoutTests/CheckoutTests/testCouponAtMinimum()"] == 1)
        #expect(snapshot.detections.count == 2)
    }
}
