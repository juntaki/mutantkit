@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("Phase timings — parsed against real captured Stage 1 reports")
struct PhaseTimingsTests {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    @Test("MutantKit phase timings are read from the real Stage 1 incremental report — 100% isolated, 0 schemata")
    func mutantKitPhaseTimingsFromRealReport() throws {
        let data = try fixture("stage1-mutantkit-incremental.json")
        let parsed = try ResultNormalizer.normalizeMutantKitReport(data)
        let timings = try #require(parsed.phaseTimings)

        #expect(timings.isolatedCount == 6, "this real run scoped RelationalOperatorReplacement, which is not schemata-eligible")
        #expect(timings.schemataCount == 0)
        #expect(timings.operatorCounts["swift.core.relational-operator-replacement"] == 6)
        #expect(timings.baselineBuildSeconds != nil && timings.baselineBuildSeconds! > 0)
        #expect(timings.baselineTestSeconds != nil && timings.baselineTestSeconds! > 0)
        #expect(timings.sumFreshMutantBuildSeconds > 0)
        #expect(timings.sumFreshMutantTestSeconds > 0)
        #expect(timings.totalWallSeconds != nil && timings.totalWallSeconds! > 0)
    }

    @Test("Muter phase timings are read from the real Stage 1 incremental report — total elapsed and operator distribution only")
    func muterPhaseTimingsFromRealReport() throws {
        let data = try fixture("stage1-muter-incremental.json")
        let timings = try ResultNormalizer.muterPhaseTimings(data)

        #expect(timings.operatorCounts["RelationalOperatorReplacement"] == 5)
        #expect(
            timings.totalWallSeconds != nil && timings.totalWallSeconds! > 0,
            "parsed from Muter's own real HH:MM:SS.mmm timeElapsed field"
        )
    }

    @Test("Muter's HH:MM:SS.mmm elapsed format parses to the correct seconds")
    func muterElapsedFormatParsesCorrectly() throws {
        let data = Data(#"{"fileReports": [], "timeElapsed": "00:01:24.088"}"#.utf8)
        let timings = try ResultNormalizer.muterPhaseTimings(data)
        #expect(timings.totalWallSeconds != nil)
        #expect(abs(timings.totalWallSeconds! - 84.088) < 0.001)
    }

    @Test("A report missing all phase-timing fields yields nil, not a fabricated zero")
    func missingPhaseFieldsYieldNil() throws {
        let data = Data(#"{"results": []}"#.utf8)
        let parsed = try ResultNormalizer.normalizeMutantKitReport(data)
        #expect(parsed.phaseTimings == nil)
    }
}
