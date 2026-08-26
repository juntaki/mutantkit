@testable import BenchmarkRunner
import Testing

/// Phase B3 (rigorous-benchmark program): a real, silent scoping mistake
/// this suite exists to make impossible to reintroduce — `--sources-path`
/// takes a *directory*, confirmed the hard way when passing a file path
/// there discovered zero mutants with no error at all. `--exclude`
/// (repeatable) is the real way to scope this tool down to one specific
/// file within a larger directory.
@Suite("SwiftMutationTestingBenchmarkTool.arguments")
struct SwiftMutationTestingBenchmarkToolTests {
    @Test("cold mode adds --no-cache; warm/incremental do not")
    func coldModeAddsNoCache() {
        let cold = SwiftMutationTestingBenchmarkTool.arguments(
            reportPath: "/tmp/report.json", mode: .cold, sourcesPath: nil, operatorIDs: [], excludePatterns: []
        )
        #expect(cold.contains("--no-cache"))

        let warm = SwiftMutationTestingBenchmarkTool.arguments(
            reportPath: "/tmp/report.json", mode: .warm, sourcesPath: nil, operatorIDs: [], excludePatterns: []
        )
        #expect(!warm.contains("--no-cache"))
    }

    @Test("--sources-path is passed as a single flag+value pair")
    func sourcesPathIsPassedThrough() {
        let arguments = SwiftMutationTestingBenchmarkTool.arguments(
            reportPath: "/tmp/report.json", mode: .cold, sourcesPath: "Sources/IntegerUtilities", operatorIDs: [], excludePatterns: []
        )
        #expect(arguments.contains("--sources-path"))
        let index = try! #require(arguments.firstIndex(of: "--sources-path"))
        #expect(arguments[index + 1] == "Sources/IntegerUtilities")
    }

    @Test("Each exclude pattern gets its own repeated --exclude flag, in order")
    func excludePatternsAreRepeatedFlags() {
        let arguments = SwiftMutationTestingBenchmarkTool.arguments(
            reportPath: "/tmp/report.json", mode: .cold, sourcesPath: "Sources/IntegerUtilities", operatorIDs: [],
            excludePatterns: ["Sources/IntegerUtilities/A.swift", "Sources/IntegerUtilities/B.swift"]
        )
        let excludeIndices = arguments.indices.filter { arguments[$0] == "--exclude" }
        #expect(excludeIndices.count == 2)
        #expect(excludeIndices.map { arguments[$0 + 1] } == ["Sources/IntegerUtilities/A.swift", "Sources/IntegerUtilities/B.swift"])
    }

    @Test("Each operator ID gets its own repeated --operator flag")
    func operatorIDsAreRepeatedFlags() {
        let arguments = SwiftMutationTestingBenchmarkTool.arguments(
            reportPath: "/tmp/report.json", mode: .cold, sourcesPath: nil,
            operatorIDs: ["RelationalOperatorReplacement", "SwapTernary"], excludePatterns: []
        )
        let operatorIndices = arguments.indices.filter { arguments[$0] == "--operator" }
        #expect(operatorIndices.map { arguments[$0 + 1] } == ["RelationalOperatorReplacement", "SwapTernary"])
    }

    @Test("No sources-path/operators/excludes given produces no stray flags")
    func emptyOptionsProduceNoStrayFlags() {
        let arguments = SwiftMutationTestingBenchmarkTool.arguments(
            reportPath: "/tmp/report.json", mode: .warm, sourcesPath: nil, operatorIDs: [], excludePatterns: []
        )
        #expect(arguments == ["--output", "/tmp/report.json", "--quiet"])
    }
}
