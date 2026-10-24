import Foundation
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import Testing

/// Differential proof for `NilCoalescingFallbackSchemataLowerer`: its real
/// output is compiled with `swiftc` and executed, and compared against the
/// isolated-mode oracle (the original source with the mutation applied as a
/// plain text edit), as `CallOperandDifferentialTests` does for the other
/// lowerers.
///
/// Every `a` and `b` records its evaluation in a global trace, so the trace
/// shows which of them ran, how often and in what order. The shapes cover the
/// cases where duplicating `b` into the selected arm could change type
/// inference: literal, implicit-member and empty-collection fallbacks, an
/// optional result, chained `??`, optional chaining on the left, and a
/// fallback inside interpolation, a call argument and a ternary condition.
@Suite("Nil-coalescing fallback: differential (compiled with swiftc)")
struct NilCoalescingFallbackDifferentialTests {
    private static let backend = SchemataBackendInfo(
        backendID: "swiftpm-process-executor", backendVersion: 1,
        toolchainHash: "sha256:toolchain", buildArgumentsHash: "sha256:args"
    )
    private static let target = SchemataTargetInfo(
        projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
    )

    static let sample = """
    nonisolated(unsafe) var trace: [String] = []
    func oi(_ name: String, _ value: Int?) -> Int? { trace.append(name); return value }
    func ti(_ name: String, _ value: Int) -> Int { trace.append(name); return value }
    enum Mode { case fast, slow }
    struct Inner { var v: Int? }
    struct S {
        var o: Int?
        var p: Int?
        var name: String?
        var mode: Mode?
        var arr: [Int]?
        var inner: Inner?
        var fn: ((Int) -> Int)?
    }
    func f1(_ s: S) -> Int { oi("a", s.o) ?? ti("b", 5) }
    func f2(_ s: S) -> String { s.name ?? "none" }
    func f3(_ s: S) -> Mode { s.mode ?? .fast }
    func f4(_ s: S) -> [Int] { s.arr ?? [] }
    func f5(_ s: S) -> Int? { oi("a", s.o) ?? oi("b", s.p) }
    func f6(_ s: S) -> Int { oi("a", s.o) ?? oi("b", s.p) ?? ti("c", 7) }
    func f7(_ s: S) -> Int { s.inner?.v ?? ti("d", 3) }
    func f8(_ s: S) -> String { "v=\\(s.o ?? 0)" }
    func f9(_ s: S) -> Int { (s.fn ?? { $0 + 1 })(2) }
    func f10(_ s: S) -> Int { s.o ?? s.p ?? s.inner?.v ?? 0 }
    func f11(_ s: S) -> Int { (s.o ?? 0) > 0 ? ti("pos", 1) : ti("neg", 0) }
    func f13(_ s: S) -> Int { s.o ?? .zero }

    """

    static let mainSource = """
    nonisolated(unsafe) var __activeNS: UInt64 = UInt64.max
    nonisolated(unsafe) var __activeIdx: UInt32 = 0
    let arguments = CommandLine.arguments
    if arguments.count > 2 { __activeNS = UInt64(arguments[1])!; __activeIdx = UInt32(arguments[2])! }
    for bits in 0 ..< 64 {
        let s = S(
            o: bits & 1 != 0 ? 1 : nil, p: bits & 2 != 0 ? 9 : nil, name: bits & 4 != 0 ? "x" : nil,
            mode: bits & 8 != 0 ? .slow : nil, arr: bits & 16 != 0 ? [1] : nil,
            inner: bits & 32 != 0 ? Inner(v: 4) : nil, fn: bits & 1 != 0 ? { $0 * 10 } : nil
        )
        func run<T>(_ name: String, _ f: (S) -> T) {
            trace = []
            let r = f(s)
            print(name, bits, r, trace.joined())
        }
        run("f1", f1); run("f2", f2); run("f3", f3); run("f4", f4); run("f5", f5); run("f6", f6)
        run("f7", f7); run("f8", f8); run("f9", f9); run("f10", f10); run("f11", f11); run("f13", f13)
    }
    """

    private static let functionCount = 12

    private struct BuildJob {
        let name: String
        let files: [String: String]
        let arguments: [String]
    }

    private enum DiffError: Error {
        case compileFailed(String, String)
        case runFailed(String)
    }

    private struct LoweredRun {
        let jobName: String
        let point: MutationPoint
        let oracle: String
    }

    private func execute(_ job: BuildJob, in root: URL) throws -> String {
        let dir = root.appendingPathComponent(job.name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (file, text) in job.files {
            try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let binary = dir.appendingPathComponent("out")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        compile.arguments = ["swiftc", "-swift-version", "5", "-Onone", "-module-name", "Diff", "-o", binary.path]
            + job.files.keys.sorted().map { dir.appendingPathComponent($0).path }
        let errPipe = Pipe()
        compile.standardError = errPipe
        compile.standardOutput = Pipe()
        try compile.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            throw DiffError.compileFailed(job.name, String(decoding: errData, as: UTF8.self))
        }
        return try run(binary, arguments: job.arguments)
    }

    private func run(_ binary: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DiffError.runFailed(binary.lastPathComponent) }
        return String(decoding: data, as: UTF8.self)
    }

    private func planChunks(for points: [MutationPoint]) throws -> SchemataChunkPlanResult {
        let registry = try SchemataLowererRegistry(lowerers: [NilCoalescingFallbackSchemataLowerer()])
        return try SchemataChunkPlanner.plan(
            mutationPlan: makePlan(mutations: points), registry: registry,
            sources: ["Sample.swift": Data(Self.sample.utf8)], targetInfo: ["Sample.swift": [Self.target]],
            backend: Self.backend
        )
    }

    /// Oracle: isolated-mode semantics, one plain text edit per point.
    private func oracleJobs(for points: [MutationPoint]) -> [BuildJob] {
        let originalBytes = Array(Self.sample.utf8)
        return points.enumerated().map { index, point in
            var bytes = originalBytes
            bytes.replaceSubrange(point.utf8Range.range, with: Array(point.replacementText.utf8))
            return BuildJob(
                name: "oracle\(index)", files: ["Sample.swift": String(decoding: bytes, as: UTF8.self), "main.swift": Self.mainSource],
                arguments: []
            )
        }
    }

    /// Lowered programs: run neutral once, then once per embedded selector.
    private func loweredJobs(
        for result: SchemataChunkPlanResult, points: [MutationPoint]
    ) throws -> (jobs: [BuildJob], runs: [LoweredRun]) {
        var jobs: [BuildJob] = []
        var runs: [LoweredRun] = []
        for (programIndex, program) in result.programs.enumerated() {
            let source = try #require(program.loweredSources.first)
            let body = source.contents.split(separator: "\n", omittingEmptySubsequences: false)
                .dropFirst(source.prependedLineCount).joined(separator: "\n")
            let suffix = try #require(body.range(of: "__mutantkitUnitDescriptor_[0-9a-f]+", options: .regularExpression))
            let prelude = """
            func __mutantkitIsActiveV3(_ d: OpaquePointer?, _ ns: UInt64, _ i: UInt32) -> Bool { __activeNS == ns && __activeIdx == i }
            nonisolated(unsafe) let \(body[suffix]): OpaquePointer? = nil

            """
            let files = ["Sample.swift": body, "prelude.swift": prelude, "main.swift": Self.mainSource]
            jobs.append(BuildJob(name: "lowered\(programIndex)-neutral", files: files, arguments: []))
            for entry in program.entries {
                let token = try #require(entry.selectorToken)
                let pointIndex = try #require(points.firstIndex { $0.id == entry.mutationID })
                jobs.append(BuildJob(
                    name: "lowered\(programIndex)-\(pointIndex)", files: files,
                    arguments: ["\(token.namespace)", "\(token.localIndex)"]
                ))
                runs.append(LoweredRun(
                    jobName: "lowered\(programIndex)-\(pointIndex)", point: points[pointIndex], oracle: "oracle\(pointIndex)"
                ))
            }
        }
        return (jobs, runs)
    }

    /// Compiles each distinct source set once, in parallel; the lowered
    /// binary is reused for every selector of the same program.
    private func compileConcurrently(_ jobs: [BuildJob], in root: URL) -> (outputs: [String: String], failures: [String]) {
        let compileJobs = jobs.filter { !$0.name.contains("-") || $0.name.hasSuffix("-neutral") }
        nonisolated(unsafe) var outputs: [String: String] = [:]
        nonisolated(unsafe) var failures: [String] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: compileJobs.count) { index in
            let job = compileJobs[index]
            do {
                let output = try self.execute(job, in: root)
                lock.lock(); outputs[job.name] = output; lock.unlock()
            } catch {
                lock.lock(); failures.append("\(job.name): \(error)"); lock.unlock()
            }
        }
        return (outputs, failures)
    }

    @Test("Lowered `??` sites behave exactly like the isolated mutant and, unselected, like the original")
    func loweredMatchesIsolatedOracle() throws {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.sample, operatorID: NilCoalescingFallbackOperator.descriptor.id, relativePath: "Sample.swift"
        )
        #expect(points.count >= 14, "\(points.count) points discovered")

        let result = try planChunks(for: points)
        let fallenBack = result.schemataPlan.entries.filter { !$0.isEmbedded }
        #expect(fallenBack.isEmpty, "\(fallenBack.map { ($0.mutationID, $0.fallbackReason) })")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-nilco-differential-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let lowered = try loweredJobs(for: result, points: points)
        let originalJob = BuildJob(
            name: "original", files: ["Sample.swift": Self.sample, "main.swift": Self.mainSource], arguments: []
        )
        let jobs = [originalJob] + oracleJobs(for: points) + lowered.jobs
        let (outputs, failures) = compileConcurrently(jobs, in: root)
        #expect(failures.isEmpty, "\(failures)")

        let original = try #require(outputs["original"])
        #expect(original.split(separator: "\n").count == 64 * Self.functionCount)
        // Canary sanity: the trace column records evaluation (non-vacuous).
        #expect(original.contains("f1 0 5 ab\n"), "a is nil, so the fallback runs after a")
        #expect(original.contains("f1 1 1 a\n"), "a is non-nil, so the fallback is never evaluated")

        var observablyDifferent = 0
        for programIndex in result.programs.indices {
            #expect(
                outputs["lowered\(programIndex)-neutral"] == original,
                "unselected lowered program \(programIndex) diverged from the original"
            )
        }
        for run in lowered.runs {
            let programIndex = run.jobName.dropFirst("lowered".count).prefix { $0 != "-" }
            let binary = root.appendingPathComponent("lowered\(programIndex)-neutral/out")
            let job = try #require(jobs.first { $0.name == run.jobName })
            let loweredOutput = try self.run(binary, arguments: job.arguments)
            let oracle = try #require(outputs[run.oracle])
            #expect(
                loweredOutput == oracle,
                "selector for \(run.point.originalText)->\(run.point.replacementText) at line \(run.point.line) diverged from the isolated mutant"
            )
            if oracle != original { observablyDifferent += 1 }
        }
        #expect(observablyDifferent >= points.count * 3 / 4, "only \(observablyDifferent) of \(points.count) mutants observable")
    }
}
