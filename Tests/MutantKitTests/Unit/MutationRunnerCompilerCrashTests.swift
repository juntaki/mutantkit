import Foundation
import MutationExecution
import MutationModel
import MutationPlanner
import SwiftFrontend
import Testing

/// A compiler crash on a mutant is `unviable` only when an independent rebuild in a fresh sandbox
/// crashes it the same way again. One crash, two different crashes, a crash that cannot be identified, a
/// rebuild that succeeds, and a first failure that is not a crash candidate all stay infrastructure
/// failures, and the mutant's tests are never run for a build that failed.
@Suite("Mutation runner: confirmed compiler crash")
struct MutationRunnerCompilerCrashTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-ccrash-project-\(UUID().uuidString)")
    private let scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-ccrash-scratch-\(UUID().uuidString)")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0", toolCommitSHA: nil, swiftVersion: "6.3.3", swiftSyntaxVersion: "603.0.2", xcodeVersion: nil
    )

    private struct Run {
        let outcome: MutationOutcome
        let build: ScriptedBuild
        let tests: ScriptedTests
    }

    private func outcome(_ script: [Script]) async throws -> Run {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("struct A { var enabled = true }".utf8).write(to: url)
        let plan = try await MutationPlanner().makePlan(
            configuration: Configuration(), projectRoot: root, toolchain: toolchain, diffScope: nil
        )
        let build = ScriptedBuild(script: script)
        let tests = ScriptedTests()
        let runner = MutationRunner(
            plan: plan, configuration: Configuration(), projectRoot: root, build: build, test: tests,
            workspaces: try WorkspaceManager(projectRoot: root, scratchRoot: scratchRoot)
        )
        let report = try await runner.run()
        return Run(outcome: try #require(report.results.first).outcome, build: build, tests: tests)
    }

    @Test("the compiler crashes on the mutant and again in a fresh rebuild: unviable, tests never run")
    func reproducedCrashIsUnviable() async throws {
        let run = try await outcome([.crash("A"), .crash("A")])
        let result = run.outcome
        let build = run.build
        let tests = run.tests
        #expect(result == .unviable)
        #expect(await build.mutantBuilds == 2)
        #expect(await tests.mutantRuns == 0)
    }

    @Test("a crash that does not reproduce stays an infrastructure failure")
    func unreproducedCrashStaysInfrastructure() async throws {
        let run = try await outcome([.crash("A"), .succeed])
        let result = run.outcome
        let build = run.build
        #expect(result == .infrastructureFailure)
        #expect(await build.mutantBuilds == 2)
    }

    @Test("a rebuild that fails some other way does not confirm the crash")
    func differentFailureDoesNotConfirm() async throws {
        let run = try await outcome([.crash("A"), .plainInfrastructure])
        let result = run.outcome
        #expect(result == .infrastructureFailure)
    }

    @Test("a rebuild that crashes the compiler somewhere else does not confirm the first crash")
    func differentCrashDoesNotConfirm() async throws {
        let run = try await outcome([.crash("A"), .crash("B")])
        let result = run.outcome
        let build = run.build
        let tests = run.tests
        #expect(result == .infrastructureFailure)
        #expect(await build.mutantBuilds == 2)
        #expect(await tests.mutantRuns == 0)
    }

    @Test("a crash whose output cannot be told from another crash is never rebuilt for confirmation")
    func unidentifiableCrashIsNotConfirmed() async throws {
        let run = try await outcome([.unidentifiedCrash, .unidentifiedCrash])
        let result = run.outcome
        let build = run.build
        #expect(result == .infrastructureFailure)
        #expect(await build.mutantBuilds == 1)
    }

    @Test("a first failure that is not a crash candidate is never rebuilt")
    func plainInfrastructureIsNotRebuilt() async throws {
        let run = try await outcome([.plainInfrastructure])
        let result = run.outcome
        let build = run.build
        #expect(result == .infrastructureFailure)
        #expect(await build.mutantBuilds == 1)
    }

    @Test("an ordinary compilation error is unviable without a confirming rebuild")
    func compilationErrorIsNotRebuilt() async throws {
        let run = try await outcome([.compilationError])
        let result = run.outcome
        let build = run.build
        #expect(result == .unviable)
        #expect(await build.mutantBuilds == 1)
    }
}

private enum Script {
    case crash(String), unidentifiedCrash, succeed, plainInfrastructure, compilationError

    /// Compiler output for the crash named `name`: the same name gives the same signature, another name a
    /// different one.
    static func crashOutput(_ name: String) -> String {
        """
        Stack dump:
        0.\tProgram arguments: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend
        1.\tApple Swift version 6.3 (swiftlang-6.3.0.1 clang-2100.0.1)
        2.\tWhile type-checking declaration '\(name)' at /tmp/sandbox-\(UUID().uuidString)/Sources/A.swift:3:5
        Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace.
        3  libsystem_platform.dylib 0x000000019cbec144 _sigtramp + 56
        4  swift-frontend           0x0000000105a7fb84 swift::Lowering::\(name)::emit(swift::ApplyExpr*) + 528
        """
    }
}

private actor ScriptedBuild: BuildAdapter {
    private var script: [Script]
    private(set) var mutantBuilds = 0
    init(script: [Script]) { self.script = script }

    nonisolated func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }

    private nonisolated func command(_ workspace: URL) -> CommandRecord {
        CommandRecord(executable: "swift", arguments: ["build"], workingDirectory: workspace.path)
    }

    func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        BuildArtifact(productsDirectory: workspace, productHash: "baseline", xctestrunPath: nil, command: command(workspace))
    }

    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        mutantBuilds += 1
        let step = script.isEmpty ? .succeed : script.removeFirst()
        let record = command(workspace)
        switch step {
        case let .crash(name):
            let output = Script.crashOutput(name)
            throw BuildFailure(
                kind: .infrastructure, diagnosis: "compiler crashed", command: record, output: output,
                isCompilerCrashCandidate: true, compilerCrashSignature: CompilerCrashSignature(output: output)
            )
        case .unidentifiedCrash:
            throw BuildFailure(
                kind: .infrastructure, diagnosis: "compiler crashed", command: record, output: "", isCompilerCrashCandidate: true
            )
        case .plainInfrastructure:
            throw BuildFailure(kind: .infrastructure, diagnosis: "no diagnostic", command: record, output: "")
        case .compilationError:
            throw BuildFailure(kind: .compilationError, diagnosis: "does not compile", command: record, output: "")
        case .succeed:
            return BuildArtifact(productsDirectory: workspace, productHash: "mutant", xctestrunPath: nil, command: record)
        }
    }
}

private actor ScriptedTests: TestAdapter {
    private(set) var mutantRuns = 0

    private static func passed() -> TestRunResult {
        TestRunResult(
            status: .passed, summary: nil, command: CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/t"),
            resultArtifactPath: nil, diagnosis: "scripted passed"
        )
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult { Self.passed() }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        mutantRuns += 1
        return Self.passed()
    }
}
