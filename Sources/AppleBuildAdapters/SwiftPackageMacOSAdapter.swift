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

        let located = try SchemataRuntimeLibraryLocator.locate(for: .macOS)
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

    /// The `swift test` build-related flags for one invocation, factored out
    /// so the exact contract is unit-testable without spawning a toolchain.
    ///
    /// - `enableCoverage`: whether `--enable-code-coverage` is passed.
    /// - `skipBuild`: whether `--skip-build` is passed. `nil` reproduces the
    ///   original either/or default (skip only when coverage is off, since a
    ///   coverage-enabled run may need SwiftPM's own one-shot instrumented
    ///   rebuild); an explicit `true`/`false` overrides that default,
    ///   letting a caller that already knows the current artifact's state —
    ///   `measurePerTestCoverage`'s loop, from its second iteration on —
    ///   request both flags together.
    static func swiftTestBuildFlags(enableCoverage: Bool, skipBuild: Bool?) -> [String] {
        var flags: [String] = []

        if enableCoverage {
            flags.append("--enable-code-coverage")
        }

        if skipBuild ?? !enableCoverage {
            flags.append("--skip-build")
        }

        return flags
    }

    private func runTests(
        in workspace: URL,
        timeoutSeconds: Double,
        enableCoverage: Bool = false,
        skipBuild: Bool? = nil,
        extraEnvironment: [String: String] = [:],
        testFilters: [String]? = nil,
        reliableExpectedTestCount: Int? = nil
    ) async throws -> TestRunResult {
        // Written inside the sandbox, so concurrent mutants cannot overwrite one
        // another's report — and so it disappears with the sandbox rather than
        // being left behind in the user's tree.
        //
        // Unique per invocation, not a fixed name: `measurePerTestCoverage`'s
        // loop calls this method many times against the *same* workspace, so
        // a fixed path would be the same file on every call. An earlier
        // version of this cleared that fixed path with a `try?`-guarded
        // delete before each run — but a failed removal (permissions, a
        // locked file, anything) would silently leave the previous
        // iteration's report in place, and `classify`'s shortfall check
        // would read it as this run's own (P12-B Finding C's fail-closed
        // contract broken by exactly the failure mode meant to protect it).
        // A UUID in the filename makes that collision structurally
        // impossible instead of merely attempted — no cleanup to fail.
        let xunitOutput = workspace.appendingPathComponent("mutantkit-xunit-\(UUID().uuidString).xml")

        // `--skip-build` because the build already happened and was already
        // classified. Letting the test step build would turn a compilation error
        // into a test failure, scoring an unviable mutant as killed.
        //
        // The baseline is the exception: `--enable-code-coverage` may force a
        // re-build with instrumentation. That rebuild is bounded and one-shot,
        // and letting SwiftPM do it inside `swift test` is simpler and more
        // reliable than re-deriving the flag's effect on `swift build`.
        //
        // `skipBuild` lets a caller that already knows the coverage-
        // instrumented artifact is current — `measurePerTestCoverage`'s loop,
        // from its second iteration on — pass both flags together. `nil`
        // reproduces the exact pre-existing either/or default: skip only when
        // coverage is off.
        var arguments = ["swift", "test"]
        arguments.append(contentsOf: Self.swiftTestBuildFlags(enableCoverage: enableCoverage, skipBuild: skipBuild))
        arguments.append(contentsOf: ["--xunit-output", xunitOutput.path])

        // Opt-in only. SwiftPM writes the XCTest half of the xunit report only in
        // parallel mode, so this is the difference between having per-test counts
        // and not — but a parallel-unsafe suite flakes, and a flake during a
        // mutant's run is recorded as that mutant being killed. Losing counts is
        // visible; an inflated score is not.
        if configuration.tests.parallel {
            arguments.append("--parallel")
        }

        // `testFilters` narrows to a specific set of tests (per-test coverage
        // measurement, `TestSelecting.runMutant`'s selected-test narrowing);
        // `nil` means "no narrowing requested", which falls back to the same
        // configured target list every unnarrowed call already used.
        for filter in testFilters ?? configuration.tests.targets {
            arguments.append(contentsOf: ["--filter", filter])
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

        return Self.classify(
            result: result, command: command, xunitOutput: xunitOutput,
            reliableExpectedTestCount: reliableExpectedTestCount
        )
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
    ///
    /// - Parameter reliableExpectedTestCount: how many tests a narrowed,
    ///   all-Swift-Testing selection named (`TestIdentifier.isSwiftTestingShaped`),
    ///   or `nil` for an unnarrowed run, or a selection that includes an
    ///   XCTest identifier. `swift test --filter` exits 0 even when it
    ///   selects zero tests (P12-B Finding C, confirmed live: SwiftPM emits
    ///   `warning: No matching test cases were run` on stderr and still
    ///   exits 0) — a run that tested nothing must never be indistinguishable
    ///   from one that passed. Restricted to all-Swift-Testing selections
    ///   because Swift Testing's own `--xunit-output` sibling report
    ///   (`XUnitParser`) reflects real executed counts unconditionally,
    ///   while XCTest's report is written only when `tests.parallel` is on
    ///   — under the (safe) default, an XCTest identifier's absence from it
    ///   proves nothing, so mixing frameworks or trusting an XCTest-only
    ///   selection here would misclassify a real, passing default-config
    ///   run as a shortfall.
    static func classify(
        result: ProcessResult,
        command: CommandRecord,
        xunitOutput: URL? = nil,
        reliableExpectedTestCount: Int? = nil
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
            if let reliableExpectedTestCount {
                // `nil` (no xunit report parsed at all -- missing, unreadable,
                // or `xunitOutput` itself absent) is treated as zero executed,
                // not as "unknown, so don't check" (codex review, P12-B Phase
                // B3): for a narrowed selection, no evidence that anything ran
                // is exactly as unsafe to call a pass as evidence that zero
                // things ran.
                let executedCount = xunitOutput.flatMap { XUnitParser.swiftTestingExecutedCount(forRequestedOutput: $0) }
                if (executedCount ?? 0) < reliableExpectedTestCount {
                    return TestRunResult(
                        status: .infrastructureFailure,
                        summary: summary,
                        command: command,
                        resultArtifactPath: xunitOutput,
                        diagnosis: """
                        This run was narrowed to \(reliableExpectedTestCount) Swift Testing test(s), but the \
                        xunit report records only \(executedCount.map(String.init) ?? "no") executed. Something \
                        in the selection did not run and left no failure record explaining why, so the \
                        shortfall is not scored as a pass.
                        """
                    )
                }
            }
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
        environment: [String: String],
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        try await runTests(
            in: workspace,
            timeoutSeconds: timeoutSeconds,
            enableCoverage: false,
            extraEnvironment: environment,
            testFilters: Self.testFilterArguments(for: selectedTests),
            reliableExpectedTestCount: Self.reliableExpectedCount(for: selectedTests)
        )
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

// MARK: - Test selection

extension SwiftPackageMacOSAdapter: TestSelecting {
    /// `TestSelecting.runMutant`. An empty selection is never turned into
    /// `--filter` arguments — that would filter the run down to nothing, and
    /// a run that tested nothing must never be mistaken for one that passed.
    /// Falls back to the full configured target list, the same behaviour as
    /// `selectedTests == nil` and identical to the unparameterised
    /// `runMutant` above.
    public func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        try await runTests(
            in: workspace,
            timeoutSeconds: timeoutSeconds,
            enableCoverage: false,
            testFilters: Self.testFilterArguments(for: selectedTests),
            reliableExpectedTestCount: Self.reliableExpectedCount(for: selectedTests)
        )
    }

    /// `selectedTests` -> `swift test --filter` arguments, or `nil` for an
    /// unrestricted run — the one place that empty-means-nil normalisation
    /// (`TestSelecting`'s documented convention) is applied, shared by every
    /// call site that turns a `Set<TestIdentifier>?` into filter arguments
    /// (`TestSelecting.runMutant` above, `SchemataTestable.runSchemataToken`
    /// below) so the rule can never drift between the two.
    fileprivate static func testFilterArguments(for selectedTests: Set<TestIdentifier>?) -> [String]? {
        selectedTests.flatMap { $0.isEmpty ? nil : $0.map(\.swiftTestFilterArgument) }
    }

    /// How many tests a narrowed selection should produce, when that count
    /// can actually be trusted against SwiftPM's own `--xunit-output` — see
    /// `classify(reliableExpectedTestCount:)`. `nil` for an unrestricted run
    /// (nothing to compare against) and for any selection that includes an
    /// XCTest identifier (its own report requires `tests.parallel`, so its
    /// absence proves nothing under the default configuration); a mixed
    /// selection is left unchecked rather than guessing which half of a
    /// merged count to trust.
    fileprivate static func reliableExpectedCount(for selectedTests: Set<TestIdentifier>?) -> Int? {
        guard let selectedTests, !selectedTests.isEmpty,
              selectedTests.allSatisfy(\.isSwiftTestingShaped) else { return nil }
        return selectedTests.count
    }

    public func measurePerTestCoverage(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        switch await measurePerTestCoverageFast(
            artifact: artifact,
            in: workspace,
            timeoutSeconds: timeoutSeconds
        ) {
        case .complete(let map):
            return map
        case .unavailable:
            return await measurePerTestCoverageSerial(
                artifact: artifact,
                in: workspace,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    /// The fast per-test coverage path: one coverage-instrumented `swift
    /// build`, then one direct `swiftpm-testing-helper` invocation per test
    /// — see `SwiftPMDirectCoverageRunner` — instead of one full `swift
    /// test --filter <id> --enable-code-coverage` process per test. Never
    /// invokes the `swift test` frontend itself; `xcrun swift test list`
    /// (already paid once by `enumerateTestIdentifiers`, same as the serial
    /// path) is the only SwiftPM CLI surface this path touches at all.
    ///
    /// `SwiftPMFastProfilingCapability.check` gates entry: Swift Testing
    /// only, exactly one resolvable `.xctest` product. A package with even
    /// one XCTest-shaped discovered test is `.unavailable` in full — see
    /// that type's own doc comment for why a mixed package never gets a
    /// partial speedup.
    ///
    /// Same all-or-nothing discipline as the serial reference: any single
    /// test this pass cannot positively profile makes the whole attempt
    /// `.unavailable`, never a map missing just that one test's entry.
    ///
    /// - Parameter processRunner: `AdapterSupport.swift`'s `ProcessRunner`
    ///   seam, threaded through to `SwiftPMDirectCoverageRunner`/
    ///   `SwiftPMCoverageExporter` — `internal`, not `private`, so a test in
    ///   another file can inject a spy and prove structurally that this
    ///   path never shells out to `swift test` per test (see
    ///   `SwiftPMFastProfilingStructuralAcceptanceTests`).
    func measurePerTestCoverageFast(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        processRunner: ProcessRunner = defaultProcessRunner
    ) async -> PerTestCoverageProfileAttempt {
        let enumerated = await Self.enumerateTestIdentifiers(
            in: workspace,
            timeoutSeconds: timeoutSeconds,
            terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
        )
        let tests = Self.scope(enumerated, toConfiguredTargets: configuration.tests.targets)

        let capability = SwiftPMFastProfilingCapability.check(tests: tests, productsDirectory: productsDirectory(in: workspace))
        guard case .supported = capability else {
            guard case .unsupported(let reason) = capability else { return .unavailable(reason: "unreachable") }
            return .unavailable(reason: reason)
        }

        // The capability check above resolved a product from the artifact
        // already on disk -- but that artifact is `runBaseline`'s own
        // *uninstrumented* one (see this method's own parameter doc on the
        // protocol). A coverage-instrumented rebuild is still required
        // before any test can be measured; re-resolve afterward, since the
        // rebuild can in principle change which product exists (a clean
        // rebuild racing a concurrent process, for instance) -- trusting
        // the pre-build resolution here would be exactly the kind of stale
        // assumption this fast path's own capability gate exists to avoid.
        guard let coverageArtifact = try? await build(in: workspace, extraArguments: ["--enable-code-coverage"]) else {
            return .unavailable(reason: "the coverage-instrumented build failed")
        }
        guard case .supported(let testBundleBinary) = SwiftPMFastProfilingCapability.check(
            tests: tests, productsDirectory: productsDirectory(in: workspace)
        ) else {
            return .unavailable(reason: "could not resolve the coverage-instrumented build's own .xctest product")
        }

        let scratchDirectory = workspace.appendingPathComponent(".mutantkit/FastProfiler", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        for test in tests {
            guard case .succeeded(let outcome) = await SwiftPMDirectCoverageRunner.run(
                testBundleBinary: testBundleBinary, test: test, workingDirectory: workspace,
                scratchDirectory: scratchDirectory, timeoutSeconds: timeoutSeconds, processRunner: processRunner
            ) else {
                return .unavailable(reason: "\(test) could not be profiled via the fast path")
            }

            guard case .exported(let json) = await SwiftPMCoverageExporter.export(
                profileURL: outcome.profileURL, testBundleBinary: testBundleBinary,
                scratchDirectory: scratchDirectory, processRunner: processRunner
            ) else {
                return .unavailable(reason: "\(test)'s coverage export failed")
            }

            guard let executed = SourceCoverageReader.parse(json, projectRoot: workspace) else {
                return .unavailable(reason: "\(test)'s coverage export could not be parsed")
            }
            Self.invert(CoverageMap(executedLines: executed, source: "swiftpm-direct-per-test"), coveredBy: test, into: &coveringTests)
        }

        guard !coveringTests.isEmpty else { return .unavailable(reason: "no coverage was attributed") }
        return .complete(PerTestCoverageMap(coveringTests: coveringTests, source: "swiftpm-direct-per-test"))
    }

    /// Runs every test `swift test list` reports, one at a time, with
    /// coverage enabled, against the artifact already built for the
    /// baseline — no separate coverage build step: `swift test
    /// --enable-code-coverage` re-instruments as a side effect the same way
    /// `runBaseline`'s own coverage pass already relies on (see its doc
    /// comment above), so only the first of these per-test invocations needs
    /// to pay for that one-shot rebuild. Every later one passes `skipBuild:
    /// true` explicitly — sources never change between iterations of this
    /// loop, so there is nothing for SwiftPM's own build-graph check to
    /// find, and skipping it outright avoids paying for that check on every
    /// one of what can be hundreds of invocations, with no change to what
    /// coverage gets attributed to which test (confirmed: `swift test
    /// --skip-build --enable-code-coverage` still exports a fresh, correct,
    /// unaccumulated `codecov/*.json` per invocation). Each individual run's
    /// codecov JSON is read right after that run finishes and merged into a
    /// reverse index.
    ///
    /// A one-time cost paid once per execution, not per mutant: worth it on
    /// a real project, where the fixed cost of re-running an entire suite
    /// dominates every mutant's wall clock regardless of how few tests
    /// actually exercise the mutated line.
    ///
    /// All-or-nothing (P12-B Finding D): a test whose isolated run cannot be
    /// proven — order-dependent and failing alone, crashed, timed out, or a
    /// selection SwiftPM silently ran zero of (Finding A/B/C, before this
    /// adapter's own filter and `classify` fixes) — invalidates the whole
    /// map, not just that one test's own entry. A previous version of this
    /// method `continue`d past such a test, returning whatever the
    /// *successful* tests alone had built; confirmed live (P12-B B1) that
    /// this produces a map that still looks complete and usable while
    /// silently missing the unprovable test's real coverage, which can turn
    /// a mutant that test alone would have killed into a false survivor. A
    /// test that legitimately covers nothing (a genuine, successfully-read
    /// empty `CoverageMap`) is not this case — that test's own turn simply
    /// contributes no lines, same as before, and the loop continues.
    /// - Parameter artifact: `runBaseline`'s own, uninstrumented artifact —
    ///   unused here beyond satisfying the protocol; test identifiers come
    ///   from `swift test list`, not from the artifact, and per-test
    ///   coverage needs its own coverage-instrumented run regardless of what
    ///   `artifact` was built with.
    private func measurePerTestCoverageSerial(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        let enumerated = await Self.enumerateTestIdentifiers(
            in: workspace,
            timeoutSeconds: timeoutSeconds,
            terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
        )
        let tests = Self.scope(enumerated, toConfiguredTargets: configuration.tests.targets)
        guard !tests.isEmpty else { return nil }

        var coveringTests: [String: [Int: Set<TestIdentifier>]] = [:]
        // Set only once a coverage-enabled run has actually completed *and*
        // its coverage was actually read — not merely after the first
        // iteration's status check — so a failed first invocation (build
        // error, infra failure, unreadable coverage) can never leave a later
        // iteration skipping the build against an artifact that may not
        // exist or may be stale. Moot in practice: any failure here already
        // returns `nil` below, ending the loop, but this ordering is the
        // contract this field exists to guarantee, not an incidental detail.
        var coverageArtifactBuilt = false
        for test in tests {
            guard let run = try? await runTests(
                in: workspace,
                timeoutSeconds: timeoutSeconds,
                enableCoverage: true,
                skipBuild: coverageArtifactBuilt,
                testFilters: [test.swiftTestFilterArgument],
                reliableExpectedTestCount: test.isSwiftTestingShaped ? 1 : nil
            ) else { return nil }
            // `runTests`'s xunit report path is unique per invocation (never
            // reused by a later iteration), and this loop -- unlike a real
            // mutant run -- never preserves it as evidence afterward: once
            // this iteration is done with it, it is pure disk usage a
            // project with many discovered tests would otherwise accumulate
            // one report pair per test, for the lifetime of this whole
            // method's loop, inside one sandbox.
            defer { Self.removeXUnitReports(at: run.resultArtifactPath) }
            guard run.status == .passed else { return nil }

            guard let map = await readCoverage(in: workspace, projectRoot: workspace) else { return nil }
            coverageArtifactBuilt = true
            Self.invert(map, coveredBy: test, into: &coveringTests)
        }

        guard !coveringTests.isEmpty else { return nil }
        return PerTestCoverageMap(coveringTests: coveringTests, source: "swiftpm-codecov-per-test")
    }

    /// Removes the xunit report(s) one `measurePerTestCoverage` iteration's
    /// `runTests` call wrote, once this loop is done reading them. Best-
    /// effort: unlike the freshness fix this exists alongside, a failed
    /// removal here is not a correctness risk -- the path is unique per
    /// invocation and is never read again by anything, so a leftover file
    /// is at worst a little unclaimed disk space, not a stale report a
    /// later run could mistake for its own.
    private static func removeXUnitReports(at resultArtifactPath: URL?, fileManager: FileManager = .default) {
        guard let resultArtifactPath else { return }
        for candidate in XUnitParser.candidatePaths(for: resultArtifactPath) {
            try? fileManager.removeItem(at: candidate)
        }
    }

    /// Merges one test's whole-run coverage map into the running per-line
    /// reverse index, in place. Pulled out of `measurePerTestCoverage`'s loop
    /// so the inversion itself — the part with no toolchain or process
    /// involved — can be driven directly from hand-built `CoverageMap`
    /// fixtures in tests, without spawning `swift test`.
    static func invert(
        _ map: CoverageMap,
        coveredBy test: TestIdentifier,
        into coveringTests: inout [String: [Int: Set<TestIdentifier>]]
    ) {
        for (file, lines) in map.executedLines {
            for line in lines {
                coveringTests[file, default: [:]][line, default: []].insert(test)
            }
        }
    }

    /// Restricts `swift test list`'s package-wide enumeration to the
    /// configured target list — the same restriction every other `swift
    /// test` invocation in this file already applies (see `runTests`'s own
    /// `--filter` loop). Xcode's equivalent enumeration gets this scoping
    /// for free, because its baseline bundle was already produced by an
    /// `-only-testing:`-filtered run; SwiftPM's `swift test list` has no
    /// such target restriction of its own, so it is applied here instead.
    /// An empty `configuredTargets` means "no restriction configured", and
    /// every enumerated test is kept, matching every other unrestricted
    /// fallback in this file.
    static func scope(_ tests: [TestIdentifier], toConfiguredTargets configuredTargets: [String]) -> [TestIdentifier] {
        guard !configuredTargets.isEmpty else { return tests }
        let allowed = Set(configuredTargets)
        return tests.filter { allowed.contains($0.target) }
    }

    /// Parses `swift test list`'s stdout: one `<Target>.<Class>/<method>`
    /// per line (confirmed against a real invocation — SwiftPM writes build
    /// progress to stderr, so stdout is test identifiers alone, nothing to
    /// filter out). Exposed for tests so a captured sample can drive parsing
    /// without a toolchain.
    static func parseTestIdentifiers(_ output: String) -> [TestIdentifier] {
        output.split(separator: "\n").compactMap { rawLine -> TestIdentifier? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let dotIndex = line.firstIndex(of: ".") else { return nil }
            let target = String(line[line.startIndex ..< dotIndex])
            let qualifiedName = String(line[line.index(after: dotIndex)...])
            guard !target.isEmpty, qualifiedName.contains("/") else { return nil }
            return TestIdentifier(target: target, qualifiedName: qualifiedName)
        }
    }

    /// Runs `swift test list --skip-build` and parses its output. `nil`/empty
    /// results (a launch failure, a non-zero exit, an unparseable line) all
    /// collapse to an empty list — `measurePerTestCoverage` already treats
    /// that as "no attribution possible", the same safe fallback every other
    /// failure path in this pass takes.
    static func enumerateTestIdentifiers(
        in workspace: URL,
        timeoutSeconds: Double,
        terminationGracePeriodSeconds: Double
    ) async -> [TestIdentifier] {
        let arguments = ["swift", "test", "list", "--skip-build"]
        guard let result = try? await ProcessSupervisor.run(
            executable: ToolPaths.xcrun,
            arguments: arguments,
            workingDirectory: workspace,
            timeoutSeconds: timeoutSeconds,
            terminationGracePeriodSeconds: terminationGracePeriodSeconds
        ), result.succeeded else { return [] }

        return parseTestIdentifiers(String(decoding: result.standardOutput, as: UTF8.self))
    }
}

private extension TestIdentifier {
    /// The exact string `swift test --filter` accepts for exactly this one
    /// test: an anchored regex over the same `<target>.<Class>/<method>`
    /// shape `swift test list` itself emits (see
    /// `SwiftPackageMacOSAdapter.parseTestIdentifiers`). `--filter` matches
    /// as a substring regex search, not an exact-match lookup, so both
    /// `target` and `qualifiedName` are escaped as regex *literals* — not
    /// just the `.` between them — and the whole thing is anchored with
    /// `^…`.
    ///
    /// `qualifiedName` is not just letters and slashes: a Swift Testing
    /// `@Test` function's own identifier includes its call parentheses
    /// (`seniorRateBoundary()`), which are regex metacharacters. Left
    /// unescaped, `()` at the end of a pattern is an empty capture group,
    /// not a literal match for the two characters `(` `)` — direct
    /// reproduction against a real Swift Testing target confirmed this
    /// alone is enough to make the previous, dot-only-escaped filter match
    /// **zero** tests, silently, exit code 0 included (P12-B Finding A/B).
    ///
    /// Swift Testing also filters at *runtime*, not in SwiftPM itself the
    /// way XCTest is, against `Test.ID.description` — which appends
    /// `/<file>:<line>:<column>` after the exact identifier `swift test
    /// list` reports, confirmed by direct reproduction against a throwaway
    /// probe package (`idprobeTests.idprobeTests/printsID()/…swift:6:6`).
    /// `list` itself never includes that suffix, so a bare `…$` anchor —
    /// correct for XCTest, which SwiftPM filters before that suffix ever
    /// enters the picture — cannot match a Swift Testing identifier's real
    /// runtime ID at all. `(?:/.*)?$` accepts that optional suffix without
    /// widening the match: `qualifiedName`'s own trailing `()` (or
    /// `(label:)` for a parameterised test) already means no *other*
    /// discovered identifier can share this literal prefix immediately
    /// followed by `/` or the end of the string, so this cannot pull in a
    /// second test the way a bare, unanchored prefix would.
    var swiftTestFilterArgument: String {
        let escapedTarget = NSRegularExpression.escapedPattern(for: target)
        let escapedQualifiedName = NSRegularExpression.escapedPattern(for: qualifiedName)
        return "^\(escapedTarget)\\.\(escapedQualifiedName)(?:/.*)?$"
    }
}

/// Split from the `private extension` above: `SwiftPMFastProfilingCapability`
/// (a different file) also needs `isSwiftTestingShaped` to decide whether a
/// discovered test set is fast-path-eligible at all -- `internal`, not
/// `private`, for exactly that cross-file reason. `swiftTestFilterArgument`
/// stays `private` above; `SwiftPMDirectCoverageRunner` deliberately
/// duplicates that one instead of sharing it (see its own doc comment).
///
/// Whether `swift test list` shaped this identifier the way it shapes every
/// Swift Testing test: `qualifiedName` ending in the test function's own
/// call parentheses (`Suite/method()`, or `Suite/method(label:)` for a
/// parameterised one) — confirmed live in B0 reproduction against this
/// package's own fixtures. An XCTest identifier's `qualifiedName` never
/// does (`Class/method`, no trailing `()`). See `SwiftPackageMacOSAdapter
/// .reliableExpectedCount(for:)` for why this specific, real distinction —
/// not a guess — is what this adapter trusts before treating a narrowed
/// selection's executed count as reliable evidence.
extension TestIdentifier {
    var isSwiftTestingShaped: Bool { qualifiedName.hasSuffix(")") }
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
