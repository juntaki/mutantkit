@testable import BenchmarkRunner
import Foundation
import Testing

/// Records the order tools were actually invoked in, per repetition —
/// the seam these tests use to prove the rotation schedule itself is
/// correct, without a real `mutantkit`/`muter`/`swift-mutation-testing`
/// binary on `PATH`.
private actor InvocationRecorder {
    private(set) var order: [(repetition: Int, tool: String)] = []
    func record(repetition: Int, tool: String) { order.append((repetition, tool)) }
}

private struct FakeTool: MutationBenchmarkTool {
    let identity: BenchmarkToolIdentity
    let recorder: InvocationRecorder
    var wallSeconds: Double = 1.0
    var reportJSON: Data = .init(#"{"results": []}"#.utf8)

    func prepare(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws {}

    func run(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws -> RawBenchmarkRun {
        await recorder.record(repetition: context.runIndex, tool: identity.name)
        return RawBenchmarkRun(
            tool: identity, projectID: project.project.id, projectCommit: project.project.commitSHA, mode: context.mode,
            execution: ToolExecutionResult(
                exitCode: 0, standardOutput: "", standardError: "", wallSeconds: wallSeconds, timedOut: false, processID: 0
            ),
            resources: .unavailable, reportData: reportJSON
        )
    }
}

@Suite("RawThroughputBenchmark (Phase B3)")
struct RawThroughputBenchmarkTests {
    private static let project = MaterializedBenchmarkProject(
        project: BenchmarkProject(
            id: "example", repositoryURL: "https://example.com/example.git",
            commitSHA: String(repeating: "a", count: 40), projectKind: .swiftPackage
        ),
        directory: FileManager.default.temporaryDirectory
    )

    @Test("Each repetition rotates the tool order by one position, per B0's own fixed schedule")
    func rotatesOrderByOnePositionPerRepetition() async throws {
        let recorder = InvocationRecorder()
        let tools: [(name: String, tool: any MutationBenchmarkTool)] = [
            ("mutantkit", FakeTool(identity: BenchmarkToolIdentity(name: "mutantkit", version: "t"), recorder: recorder)),
            (
                "swift-mutation-testing",
                FakeTool(identity: BenchmarkToolIdentity(name: "swift-mutation-testing", version: "t"), recorder: recorder)
            ),
            ("muter", FakeTool(identity: BenchmarkToolIdentity(name: "muter", version: "t"), recorder: recorder))
        ]
        _ = try await RawThroughputBenchmark.run(
            tools: tools, project: Self.project, mode: .cold, repetitions: 3,
            cacheDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 60
        )

        let order = await recorder.order
        #expect(order.filter { $0.repetition == 0 }.map(\.tool) == ["mutantkit", "swift-mutation-testing", "muter"])
        #expect(order.filter { $0.repetition == 1 }.map(\.tool) == ["swift-mutation-testing", "muter", "mutantkit"])
        #expect(order.filter { $0.repetition == 2 }.map(\.tool) == ["muter", "mutantkit", "swift-mutation-testing"])
    }

    @Test("A 4th repetition wraps back to the original rotation, not a new, unbounded sequence")
    func rotationWrapsAround() async throws {
        let recorder = InvocationRecorder()
        let tools: [(name: String, tool: any MutationBenchmarkTool)] = [
            ("a", FakeTool(identity: BenchmarkToolIdentity(name: "a", version: "t"), recorder: recorder)),
            ("b", FakeTool(identity: BenchmarkToolIdentity(name: "b", version: "t"), recorder: recorder))
        ]
        _ = try await RawThroughputBenchmark.run(
            tools: tools, project: Self.project, mode: .cold, repetitions: 4,
            cacheDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 60
        )
        let order = await recorder.order
        #expect(order.filter { $0.repetition == 0 }.map(\.tool) == ["a", "b"])
        #expect(order.filter { $0.repetition == 2 }.map(\.tool) == ["a", "b"], "repetition 2 must match repetition 0's own rotation")
        #expect(order.filter { $0.repetition == 1 }.map(\.tool) == ["b", "a"])
        #expect(order.filter { $0.repetition == 3 }.map(\.tool) == ["b", "a"], "repetition 3 must match repetition 1's own rotation")
    }

    @Test("Median wall time and mutants/sec are computed correctly across real repetitions")
    func computesMedianWallTimeAndThroughput() async throws {
        let recorder = InvocationRecorder()
        let reportWithTwoMutants = Data(#"""
        {"results": [
          {"point": {"file": "A.swift", "utf8Range": {"start": 0, "end": 4}, "originalText": "true", "replacementText": "false", "operatorID": "swift.core.bool-literal-inversion", "line": 1, "column": 1}, "outcome": "killedByAssertion"},
          {"point": {"file": "A.swift", "utf8Range": {"start": 10, "end": 14}, "originalText": "true", "replacementText": "false", "operatorID": "swift.core.bool-literal-inversion", "line": 2, "column": 1}, "outcome": "survived"}
        ]}
        """#.utf8)
        let tools: [(name: String, tool: any MutationBenchmarkTool)] = [
            ("mutantkit", FakeTool(
                identity: BenchmarkToolIdentity(name: "mutantkit", version: "t"), recorder: recorder,
                wallSeconds: 10.0, reportJSON: reportWithTwoMutants
            ))
        ]
        let (_, summaries) = try await RawThroughputBenchmark.run(
            tools: tools, project: Self.project, mode: .cold, repetitions: 3,
            cacheDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 60
        )
        let summary = try #require(summaries.first)
        #expect(summary.wallSecondsByRepetition == [10.0, 10.0, 10.0])
        #expect(summary.medianWallSeconds == 10.0)
        #expect(summary.discoveredCount == 2)
        #expect(summary.medianMutantsPerSecond == 0.2)
    }

    @Test("Disagreeing discovered counts across repetitions yield a nil discovered count, not an arbitrary pick")
    func disagreeingDiscoveredCountsYieldNil() async throws {
        let recorder = InvocationRecorder()
        // A tool that reports a different mutant count on its 2nd
        // repetition — real non-determinism, which must be visible, not
        // silently resolved by picking the first (or any) repetition.
        struct FlakyDiscoveryTool: MutationBenchmarkTool {
            let identity: BenchmarkToolIdentity
            let recorder: InvocationRecorder
            func prepare(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws {}
            func run(project: MaterializedBenchmarkProject, context: BenchmarkRunContext) async throws -> RawBenchmarkRun {
                await recorder.record(repetition: context.runIndex, tool: identity.name)
                let count = context.runIndex == 0 ? 1 : 2
                let results = (0 ..< count).map { i in
                    #"{"point": {"file": "A.swift", "utf8Range": {"start": \#(i * 10), "end": \#(i * 10 + 4)}, "originalText": "true", "replacementText": "false", "operatorID": "swift.core.bool-literal-inversion", "line": \#(i + 1), "column": 1}, "outcome": "killedByAssertion"}"#
                }.joined(separator: ",")
                let json = Data(#"{"results": [\#(results)]}"#.utf8)
                return RawBenchmarkRun(
                    tool: identity, projectID: project.project.id, projectCommit: project.project.commitSHA, mode: context.mode,
                    execution: ToolExecutionResult(
                        exitCode: 0, standardOutput: "", standardError: "", wallSeconds: 1.0, timedOut: false, processID: 0
                    ),
                    resources: .unavailable, reportData: json
                )
            }
        }
        let tools: [(name: String, tool: any MutationBenchmarkTool)] = [
            ("mutantkit", FlakyDiscoveryTool(identity: BenchmarkToolIdentity(name: "mutantkit", version: "t"), recorder: recorder))
        ]
        let (_, summaries) = try await RawThroughputBenchmark.run(
            tools: tools, project: Self.project, mode: .cold, repetitions: 2,
            cacheDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 60
        )
        let summary = try #require(summaries.first)
        #expect(summary.discoveredCount == nil)
        #expect(summary.medianMutantsPerSecond == nil)
    }

    /// B3.6: the exact real bug this guard exists for (Phase B3's
    /// swift-mutation-testing `--sources-path` scoping bug) reproduced with
    /// a `FakeTool` — a tool that exits cleanly but discovers zero mutants
    /// for a scope this call explicitly marked non-empty. The resulting
    /// throughput must never look like a real, fast measurement.
    @Test("A tool that exits cleanly with 0 discovered mutants for a non-empty scope is flagged invalid, never a fast result")
    func zeroDiscoveredForNonEmptyScopeIsInvalid() async throws {
        let recorder = InvocationRecorder()
        let tools: [(name: String, tool: any MutationBenchmarkTool)] = [
            ("swift-mutation-testing", FakeTool(
                identity: BenchmarkToolIdentity(name: "swift-mutation-testing", version: "t"),
                recorder: recorder, wallSeconds: 0.5, reportJSON: Data(#"{"results": []}"#.utf8)
            ))
        ]
        let (repetitions, summaries) = try await RawThroughputBenchmark.run(
            tools: tools, project: Self.project, mode: .cold, repetitions: 2,
            cacheDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 60,
            requestedScopeIsNonEmpty: ["swift-mutation-testing": true]
        )
        #expect(repetitions.allSatisfy { $0.validityViolation != nil })
        let summary = try #require(summaries.first)
        #expect(summary.violations.count == 2, "one violation per invalid repetition")
        #expect(summary.medianMutantsPerSecond == nil, "an invalid run must never report a throughput number, even 0")
    }

    @Test("A tool with an explicitly empty requested scope is exempt from the B3.6 guard")
    func explicitlyEmptyScopeIsExempt() async throws {
        let recorder = InvocationRecorder()
        let tools: [(name: String, tool: any MutationBenchmarkTool)] = [
            ("mutantkit", FakeTool(identity: BenchmarkToolIdentity(name: "mutantkit", version: "t"), recorder: recorder))
        ]
        let (repetitions, _) = try await RawThroughputBenchmark.run(
            tools: tools, project: Self.project, mode: .cold, repetitions: 1,
            cacheDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 60,
            requestedScopeIsNonEmpty: ["mutantkit": false]
        )
        #expect(repetitions.allSatisfy { $0.validityViolation == nil })
    }

    @Test("A fixture-documented zero-mutants expectation exempts a tool from the B3.6 guard")
    func fixtureDocumentedZeroMutantsIsExempt() async throws {
        let recorder = InvocationRecorder()
        let tools: [(name: String, tool: any MutationBenchmarkTool)] = [
            ("muter", FakeTool(identity: BenchmarkToolIdentity(name: "muter", version: "t"), recorder: recorder))
        ]
        let (repetitions, _) = try await RawThroughputBenchmark.run(
            tools: tools, project: Self.project, mode: .cold, repetitions: 1,
            cacheDirectory: FileManager.default.temporaryDirectory, timeoutSeconds: 60,
            requestedScopeIsNonEmpty: ["muter": true], zeroMutantsExpected: ["muter": true]
        )
        #expect(repetitions.allSatisfy { $0.validityViolation == nil })
    }
}
