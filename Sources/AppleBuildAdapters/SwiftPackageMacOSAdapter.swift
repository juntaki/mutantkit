import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend

/// Builds and tests a Swift package on the host with `swift build` / `swift test`.
///
/// Only for packages that actually have a host slice. A package declaring only
/// iOS cannot be tested this way — it has no macOS platform to link against, and
/// forcing it through here is what makes `import UIKit` fail with an error that
/// blames the user's code. `ProjectDetector` is what keeps those packages away
/// from this adapter.
public struct SwiftPackageMacOSAdapter: Sendable {
    let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Where SwiftPM leaves the test bundles.
    func productsDirectory(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".build/debug", isDirectory: true)
    }
}

// MARK: - Build

extension SwiftPackageMacOSAdapter: BuildAdapter {
    public func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        try await build(in: workspace)
    }

    /// The mutated source is already on disk in this workspace, so a mutant build
    /// is the same command as the baseline's.
    public func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        try await build(in: workspace)
    }

    private func build(in workspace: URL, extraArguments: [String] = []) async throws -> BuildArtifact {
        // `--build-tests` so the test bundle exists before `swift test --skip-build`
        // runs. Without it the test step would silently rebuild, and the build and
        // test timings — which drive the adaptive mutant timeout — would be wrong.
        let arguments = ["swift", "build", "--build-tests"] + extraArguments

        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcrun,
                arguments: arguments,
                workingDirectory: workspace,
                timeoutSeconds: configuration.timeouts.baselineSeconds,
                terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
            )
        } catch {
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: "Could not launch the Swift toolchain: \(error)",
                command: CommandRecording.record(
                    executable: ToolPaths.xcrun,
                    arguments: arguments,
                    workingDirectory: workspace,
                    result: nil
                ),
                output: ""
            )
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcrun,
            arguments: arguments,
            workingDirectory: workspace,
            result: result
        )

        guard result.succeeded else {
            throw BuildClassifier.failure(from: result, command: command)
        }

        let products = productsDirectory(in: workspace)
        return BuildArtifact(
            productsDirectory: products,
            productHash: TestProductHasher.hash(productsDirectory: products),
            // SwiftPM does not produce one; `swift test` needs no such handoff.
            xctestrunPath: nil,
            command: command
        )
    }

    public func diagnose() async throws -> BuildDiagnosis {
        var items: [DiagnosisItem] = []
        let workspace = URL(fileURLWithPath: configuration.project.path ?? ".")

        items.append(await Diagnostics.swiftVersion(workingDirectory: workspace))
        items.append(contentsOf: await Diagnostics.projectKind(workspace: workspace))
        items.append(Diagnostics.diskSpace(at: workspace))

        return BuildDiagnosis(items: items)
    }
}

// MARK: - Schemata build

extension SwiftPackageMacOSAdapter: SchemataBuildable {
    public func buildSchemataChunk(loweredSources: [SchemataSourceFile], in workspace: URL) async throws -> BuildArtifact {
        for source in loweredSources {
            try SchemataSourceWriter.write(source, in: workspace)
        }

        let located = try SchemataRuntimeLibraryLocator.locate()
        let linkerArguments = SwiftPMLinkerInjector.extraArguments(libraryDirectory: located.libraryDirectory)
        return try await build(in: workspace, extraArguments: linkerArguments)
    }

    public func resolveSchemataBuildReceipt(
        for units: [SchemataCompilationUnitTargetRequest],
        artifact: BuildArtifact,
        in workspace: URL,
        context: SchemataBuildReceiptContext
    ) async throws -> SchemataBuildReceipt {
        let discovered = try SchemataBuiltImageInspection.inspect(productsDirectory: artifact.productsDirectory)
        let graph = try await SwiftPMTargetResolver.resolveDependencyGraph(projectRoot: workspace)

        // Keyed by the *request's own* `buildTarget` — the chunk planner's
        // already-authoritative identity — never a value this resolver
        // recomputes from the dependency graph's own `projectIdentity`.
        // The two can legitimately differ (a caller's `projectIdentity` need
        // not be `Package.swift`'s own path), and a receipt whose
        // `buildTarget` silently disagreed with what the caller requested
        // would make every later `CompilationUnitReceipt.buildTarget ==
        // request.buildTarget` lookup fail closed for the wrong reason.
        let buildTargetsByName = Dictionary(units.map { ($0.buildTarget.targetName, $0.buildTarget) }) { first, _ in first }
        let resolvedByTarget = try SwiftPMCompilationUnitImageResolver.resolve(
            targets: Set(buildTargetsByName.keys), graph: graph, discovered: discovered
        )

        var imagesByTarget: [BuildTargetIdentity: BuiltImageReceipt] = [:]
        for (targetName, image) in resolvedByTarget {
            guard let buildTarget = buildTargetsByName[targetName] else { continue }
            if imagesByTarget[buildTarget] == nil {
                imagesByTarget[buildTarget] = try BuiltImageReceipt(
                    buildTarget: buildTarget,
                    binaryPath: image.binaryPath,
                    contentHash: image.contentHash,
                    slices: image.slices
                )
            }
        }

        let compilationUnits = units.map {
            CompilationUnitReceipt(
                compilationUnitID: $0.compilationUnitID,
                sourceEmbeddingID: $0.sourceEmbeddingID,
                buildTarget: $0.buildTarget
            )
        }

        return try SchemataBuildReceipt(
            planID: context.planID,
            workUnitID: context.workUnitID,
            chunkID: context.chunkID,
            toolchainHash: context.toolchainHash,
            buildArgumentsHash: context.buildArgumentsHash,
            runtimeABIVersion: UInt32(BoolLiteralSchemataLowerer.runtimeABIVersion),
            images: Array(imagesByTarget.values),
            compilationUnits: compilationUnits
        )
    }
}

// MARK: - Test

extension SwiftPackageMacOSAdapter: TestAdapter {
    public func runBaseline(
        _ artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async throws -> TestRunResult {
        // Coverage is measured on the baseline only, once per run, then reused
        // for every mutant — see `CoverageMeasuring`. Turning the flag on here
        // means SwiftPM re-instruments the build during this test run; the
        // baseline's `productHash` was captured *before* instrumentation, so
        // every mutant is still compared against an uninstrumented reference.
        // Mutants are never built with coverage, so the comparison stays
        // apples-to-apples.
        try await runTests(
            in: workspace,
            timeoutSeconds: timeoutSeconds,
            enableCoverage: configuration.execution.measureCoverage
        )
    }

    public func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await runTests(in: workspace, timeoutSeconds: timeoutSeconds, enableCoverage: false)
    }

    private func runTests(
        in workspace: URL,
        timeoutSeconds: Double,
        enableCoverage: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) async throws -> TestRunResult {
        // Written inside the sandbox, so concurrent mutants cannot overwrite one
        // another's report — and so it disappears with the sandbox rather than
        // being left behind in the user's tree.
        let xunitOutput = workspace.appendingPathComponent("mutantkit-xunit.xml")

        // `--skip-build` because the build already happened and was already
        // classified. Letting the test step build would turn a compilation error
        // into a test failure, scoring an unviable mutant as killed.
        //
        // The baseline is the exception: `--enable-code-coverage` may force a
        // re-build with instrumentation. That rebuild is bounded and one-shot,
        // and letting SwiftPM do it inside `swift test` is simpler and more
        // reliable than re-deriving the flag's effect on `swift build`.
        var arguments = ["swift", "test"]
        if enableCoverage {
            arguments.append("--enable-code-coverage")
        } else {
            arguments.append("--skip-build")
        }
        arguments.append(contentsOf: ["--xunit-output", xunitOutput.path])

        // Opt-in only. SwiftPM writes the XCTest half of the xunit report only in
        // parallel mode, so this is the difference between having per-test counts
        // and not — but a parallel-unsafe suite flakes, and a flake during a
        // mutant's run is recorded as that mutant being killed. Losing counts is
        // visible; an inflated score is not.
        if configuration.tests.parallel {
            arguments.append("--parallel")
        }

        for target in configuration.tests.targets {
            arguments.append(contentsOf: ["--filter", target])
        }
        arguments.append(contentsOf: configuration.tests.extraArguments)

        let result: ProcessResult
        do {
            // `extraEnvironment` merges over the ambient environment,
            // exactly the default `ProcessSupervisor.run` would otherwise
            // use on its own — this is the only difference from every
            // other call site here, and is empty (a true no-op) for both
            // `runBaseline`/`runMutant`.
            let environment = extraEnvironment.isEmpty
                ? ProcessInfo.processInfo.environment
                : ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, new in new }
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcrun,
                arguments: arguments,
                workingDirectory: workspace,
                environment: environment,
                timeoutSeconds: timeoutSeconds,
                terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
            )
        } catch {
            return TestRunResult(
                status: .infrastructureFailure,
                summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcrun,
                    arguments: arguments,
                    workingDirectory: workspace,
                    result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "Could not launch the Swift toolchain: \(error)"
            )
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcrun,
            arguments: arguments,
            workingDirectory: workspace,
            result: result
        )

        return Self.classify(result: result, command: command, xunitOutput: xunitOutput)
    }

    /// Classifies a `swift test` run from its exit status and its xunit report.
    ///
    /// `swift test` writes no `.xcresult`, but `--xunit-output` gives it a
    /// structured record all the same, so the console text is still never parsed.
    /// The exit status decides the verdict — it is a contract of the tool — while
    /// the xunit report supplies the counts and the names of the tests that
    /// caught the mutant. When no report was written the counts are reported as
    /// unknown rather than invented: a fabricated "1 test failed" would be
    /// indistinguishable downstream from a measured one.
    static func classify(
        result: ProcessResult,
        command: CommandRecord,
        xunitOutput: URL? = nil
    ) -> TestRunResult {
        let summary = xunitOutput.flatMap { XUnitParser.summary(forRequestedOutput: $0) }
        if result.timedOut {
            return TestRunResult(
                status: .timedOut,
                summary: nil,
                command: command,
                resultArtifactPath: nil,
                diagnosis: """
                The test run exceeded its time limit and was terminated after \
                \(String(format: "%.1f", result.durationSeconds))s.
                """
            )
        }

        if let signal = result.terminatingSignal {
            return TestRunResult(
                status: .crashed,
                summary: nil,
                command: command,
                resultArtifactPath: nil,
                diagnosis: "The test process was killed by signal \(signal)."
            )
        }

        if result.exitCode == 0 {
            return TestRunResult(
                status: .passed,
                summary: summary,
                command: command,
                resultArtifactPath: xunitOutput,
                diagnosis: summary.map { "swift test exited successfully; all \($0.total) tests passed." }
                    ?? "swift test exited successfully; every test passed."
            )
        }

        // A failing suite exits 1. Anything else means the runner could not do its
        // job — a missing bundle, a dyld failure — which is not the mutant's doing.
        guard result.exitCode == 1 else {
            return TestRunResult(
                status: .infrastructureFailure,
                summary: nil,
                command: command,
                resultArtifactPath: nil,
                diagnosis: """
                swift test exited with \(result.exitCode), which indicates it could \
                not run the suite rather than that a test failed: \
                \(OutputRedactor.redactAndTruncate(result.combinedOutput, limit: 300)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                """
            )
        }

        return TestRunResult(
            status: .failed,
            summary: summary,
            command: command,
            resultArtifactPath: xunitOutput,
            diagnosis: summary.map { report in
                let caught = report.failingTests.prefix(3).joined(separator: ", ")
                return caught.isEmpty
                    ? "swift test exited with 1: \(report.failed) of \(report.total) tests failed."
                    : "swift test exited with 1: \(report.failed) of \(report.total) tests failed, caught by \(caught)."
            } ?? "swift test exited with 1: at least one test failed."
        )
    }

    static let emptySummary = TestOutcomeSummary(
        total: 0, passed: 0, failed: 0, failingTests: [], durationSeconds: nil
    )
}

// MARK: - Schemata test

extension SwiftPackageMacOSAdapter: SchemataTestable {
    /// Reuses the exact `swift test --skip-build` invocation shape
    /// `runMutant` already uses — no rebuild, no extra linker flags needed
    /// here (the chunk was already linked by `buildSchemataChunk`), just
    /// `environment` merged in so the runtime activates the requested
    /// token. Proven end to end by `SchemataSwiftPMLinkerInjectionAcceptanceTests
    /// .testBundleLinksAndActivatesWithNoManifestChange`.
    public func runSchemataToken(
        _ artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        environment: [String: String]
    ) async throws -> TestRunResult {
        try await runTests(in: workspace, timeoutSeconds: timeoutSeconds, enableCoverage: false, extraEnvironment: environment)
    }
}

// MARK: - Coverage

extension SwiftPackageMacOSAdapter: CoverageMeasuring {
    public func readCoverage(in workspace: URL, projectRoot: URL) async -> CoverageMap? {
        // SwiftPM writes codecov JSON under `.build/<arch>/<build>/codecov/`.
        // `.build/debug` is normally a symlink to the real path; resolving it
        // is what makes the enumerator actually descend (HANDOVER §3-3).
        let buildDir = productsDirectory(in: workspace).resolvingSymlinksInPath()
        let codecovDir = buildDir.appendingPathComponent("codecov", isDirectory: true)
        // The codecov paths are absolute and rooted at the *sandbox*, because
        // that is where the instrumented binary was built. The plan, however,
        // uses repository-relative paths, and the sandbox is a verbatim copy of
        // the project tree — so stripping the *workspace* prefix (not the
        // caller's `projectRoot`) yields the same repo-relative shape the plan
        // uses. Passing `projectRoot` here would match nothing.
        return SourceCoverageReader.read(directory: codecovDir, projectRoot: workspace)
    }
}

// MARK: - Project adapter

/// Pairs the host build and test halves.
public struct SwiftPackageMacOSProjectAdapter: ProjectAdapter {
    public let kind: ProjectKind = .swiftPackageMacOS
    public let build: any BuildAdapter
    public let test: any TestAdapter

    public init(configuration: Configuration) {
        let adapter = SwiftPackageMacOSAdapter(configuration: configuration)
        build = adapter
        test = adapter
    }
}
