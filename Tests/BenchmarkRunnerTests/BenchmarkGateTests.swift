@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("BenchmarkGate")
struct BenchmarkGateTests {
    private func measurement(
        tool: String = "mutantkit", phantom: Int? = nil, falseScored: Int? = nil, backendDisagreements: Int? = nil
    ) -> MutationBenchmarkMeasurement {
        MutationBenchmarkMeasurement(
            runID: UUID(), tool: BenchmarkToolIdentity(name: tool, version: "0"), projectID: "p", projectCommit: "c",
            mode: .cold, toolchainProfileID: "test", discovered: 10, applied: 10, built: 10, provenActive: 10, provenExecuted: 10,
            killed: 5, survived: 5, noCoverage: 0, unviable: 0, infrastructureFailure: 0,
            phantom: phantom, falseScored: falseScored, backendDisagreements: backendDisagreements,
            wallSeconds: 1.0, peakResidentBytes: nil, workingDirectoryGrowthBytes: nil, exitCode: 0
        )
    }

    @Test("A clean result produces zero violations")
    func cleanResultPasses() {
        let aggregate = AggregateBenchmarkResult(projects: [
            AggregateProjectResult(
                projectID: "p", mutantKitMeasurements: [.cold: measurement()], muterMeasurements: [:],
                comparison: nil, mutantKitCorrectnessPassed: true
            )
        ])
        #expect(BenchmarkGate().evaluate(aggregate).isEmpty)
    }

    @Test("Any phantom mutant is a violation")
    func phantomMutantIsAViolation() {
        let aggregate = AggregateBenchmarkResult(projects: [
            AggregateProjectResult(
                projectID: "p", mutantKitMeasurements: [.cold: measurement(phantom: 1)], muterMeasurements: [:],
                comparison: nil, mutantKitCorrectnessPassed: true
            )
        ])
        #expect(!BenchmarkGate().evaluate(aggregate).isEmpty)
    }

    @Test("Any false-scored mutant is a violation")
    func falseScoredMutantIsAViolation() {
        let aggregate = AggregateBenchmarkResult(projects: [
            AggregateProjectResult(
                projectID: "p", mutantKitMeasurements: [.cold: measurement(falseScored: 1)], muterMeasurements: [:],
                comparison: nil, mutantKitCorrectnessPassed: true
            )
        ])
        #expect(!BenchmarkGate().evaluate(aggregate).isEmpty)
    }

    @Test("Any backend disagreement is a violation")
    func backendDisagreementIsAViolation() {
        let aggregate = AggregateBenchmarkResult(projects: [
            AggregateProjectResult(
                projectID: "p", mutantKitMeasurements: [.cold: measurement(backendDisagreements: 1)], muterMeasurements: [:],
                comparison: nil, mutantKitCorrectnessPassed: true
            )
        ])
        #expect(!BenchmarkGate().evaluate(aggregate).isEmpty)
    }

    @Test("Failed MutantKit correctness validation is a violation, independent of any count field")
    func correctnessFailureIsAViolation() {
        let aggregate = AggregateBenchmarkResult(projects: [
            AggregateProjectResult(
                projectID: "p", mutantKitMeasurements: [.cold: measurement()], muterMeasurements: [:],
                comparison: nil, mutantKitCorrectnessPassed: false
            )
        ])
        #expect(!BenchmarkGate().evaluate(aggregate).isEmpty)
    }

    @Test("nil optional fields (not observed) never trigger a violation on their own")
    func nilFieldsDoNotViolate() {
        let unmeasured = MutationBenchmarkMeasurement(
            runID: UUID(), tool: BenchmarkToolIdentity(name: "muter", version: "0"), projectID: "p", projectCommit: "c",
            mode: .cold, toolchainProfileID: "test", discovered: 10, applied: nil, built: nil, provenActive: nil, provenExecuted: nil,
            killed: 5, survived: 5, noCoverage: 0, unviable: 0, infrastructureFailure: 0,
            phantom: nil, falseScored: nil, backendDisagreements: nil,
            wallSeconds: 1.0, peakResidentBytes: nil, workingDirectoryGrowthBytes: nil, exitCode: 0
        )
        let aggregate = AggregateBenchmarkResult(projects: [
            AggregateProjectResult(
                projectID: "p", mutantKitMeasurements: [:], muterMeasurements: [.cold: unmeasured],
                comparison: nil, mutantKitCorrectnessPassed: true
            )
        ])
        #expect(BenchmarkGate().evaluate(aggregate).isEmpty)
    }
}
