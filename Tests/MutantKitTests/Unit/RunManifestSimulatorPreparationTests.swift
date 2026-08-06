import AppleBuildAdapters
@testable import CLI
import Foundation
import MutationModel
import Testing

/// `RunManifest` now carries `simulatorPreparation`, so `--replay` and post-hoc
/// inspection can see how the run's simulator was prepared. These tests pin the
/// round trip and — the part that matters for an on-disk record written by an
/// older build — that a manifest without the new key decodes as `nil` rather
/// than throwing.
@Suite("RunManifest simulator preparation")
struct RunManifestSimulatorPreparationTests {
    private func makeManifest(preparation: SimulatorPreparationRecord?) -> RunManifest {
        RunManifest(
            planID: "plan",
            workUnitID: "wu",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            resolvedDestination: nil,
            scheme: nil,
            testTargets: [],
            extraTestArguments: [],
            mutantTimeoutSeconds: 30,
            baselineTimeoutSeconds: 600,
            toolchain: makeToolchain(),
            configurationHash: "hash",
            resourceSnapshot: nil,
            simulatorPreparation: preparation
        )
    }

    @Test("A simulatorPreparation record round-trips through disk")
    func roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-manifest-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let record = SimulatorPreparationRecord(
            outcome: .prepared, udid: "UDID", name: "iPhone 16", detail: nil
        )
        try makeManifest(preparation: record).write(to: url)
        let read = try RunManifest.read(from: url)

        #expect(read.simulatorPreparation?.outcome == .prepared)
        #expect(read.simulatorPreparation?.udid == "UDID")
        #expect(read.simulatorPreparation?.name == "iPhone 16")
    }

    @Test("A manifest written without simulatorPreparation decodes as nil")
    func backwardCompatible() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-manifest-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try makeManifest(preparation: SimulatorPreparationRecord(outcome: .failed, detail: "x"))
            .write(to: url)

        // Simulate an older file: strip the key the new field lives under.
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object.removeValue(forKey: "simulatorPreparation")
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: url)

        let read = try RunManifest.read(from: url)
        #expect(read.simulatorPreparation == nil)
        #expect(read.planID == "plan", "the rest of the record still reads back")
    }

    @Test("A manifest with no simulator preparation records nil by default")
    func defaultsToNil() throws {
        let manifest = makeManifest(preparation: nil)
        #expect(manifest.simulatorPreparation == nil)
    }
}
