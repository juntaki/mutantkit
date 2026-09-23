import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend

/// Builds and tests anything that needs `xcodebuild`: `.xcodeproj`,
/// `.xcworkspace`, and Swift packages targeting a non-host Apple platform.
///
/// The package case is not an afterthought. A package declaring only iOS has no
/// host slice, so `swift test` cannot run it at all; routing it here is what lets
/// it link UIKit and run on a simulator.
public struct XcodeBuildAdapter: Sendable {
    let configuration: Configuration
    public let kind: ProjectKind
    /// The `.xcodeproj`/`.xcworkspace`, relative to the project root. `nil` for a
    /// package, where `xcodebuild` reads the manifest from the working directory.
    ///
    /// Stored relative rather than absolute so it can be re-resolved against each
    /// sandbox. Passing the original absolute path would build the user's real,
    /// unmutated sources while the mutated copy sat unread in the sandbox — every
    /// mutant would then produce a binary identical to the baseline's and the run
    /// would report a confident, meaningless score.
    let projectFileRelativePath: String?
    let resultReader: XCResultAdapter
    /// Shared across every mutant, which is the entire point: it is what stops two
    /// of them being handed the same device.
    let simulators: SimulatorPool
    /// The destination resolved once, at run start — see `DestinationResolver`.
    /// `nil` when no resolution has been performed (a caller that predates
    /// this, or an intentionally unresolved one-off invocation); every build
    /// and test call falls back to the previous, per-call resolution in that
    /// case, so this is purely additive.
    let resolvedDestination: ResolvedDestination?
    /// Per-worker device affinity: when set, `leaseAndRunTests` looks up the
    /// mutant's sandbox by `workspace.lastPathComponent` here *before*
    /// falling back to the single, run-wide `resolvedDestination.device`
    /// every worker otherwise shares. Keyed by
    /// `WorkspaceManager.directoryName(for:)`'s own hashed sandbox-name
    /// convention (computed once, by whoever provisions the pool — see
    /// `RunCommand`), not by the worker id string itself, since a sandbox's
    /// own directory name is the only worker-identifying value that
    /// actually reaches this adapter — no protocol change to
    /// `TestAdapter`/`BuildAdapter` was needed to thread a separate worker
    /// id down. `nil` (the default, and the only value every existing
    /// caller passes) reproduces today's single-shared-device behavior
    /// exactly.
    ///
    /// **Known limitation, documented rather than silently accepted:**
    /// crash/timeout *confirmation* runs (`MutationRunner`'s
    /// `-crash-confirm`/`-timeout-confirm` sandboxes) are created and named
    /// per-mutation-ID, never per-worker, so their
    /// `workspace.lastPathComponent` never matches a key in this
    /// dictionary — they always fall through to the
    /// `resolvedDestination?.device` branch below, i.e. the single shared
    /// base device, reintroducing exactly the contention `simulatorPool`
    /// exists to remove, but only for the confirmation re-run of a mutant
    /// already suspected to have crashed or hung, not for the primary,
    /// parallel test pass. A structural fix would need to know which
    /// worker's device produced the original crash/timeout so the
    /// confirmation run could reuse it — not knowable from this dictionary
    /// alone, since worker-to-mutant assignment is dynamic (`MutationQueue`
    /// hands mutants to whichever worker asks next, not a static mapping
    /// precomputed at provisioning time). Deferred rather than solved here:
    /// confirmation runs are rare (only suspected crashes/timeouts trigger
    /// one) relative to the primary pass this feature already parallelizes
    /// correctly.
    let workerDevicesByWorkspace: [String: SimulatorDevice]?
    /// How `uninstallStaleApp` actually spawns `simctl` —
    /// `AdapterSupport.swift`'s `ProcessRunner` seam. Every production path
    /// gets `defaultProcessRunner`; only the test-only initializer below
    /// substitutes anything else.
    ///
    /// Constructor-injected rather than passed per call because the callers
    /// that must be proven fail-closed (`runTestsAfterUninstall`,
    /// `runSchemataTokenAfterUninstall`) are already at this project's
    /// `function_parameter_count` ceiling, and because a scripted runner is
    /// the only way to pin the failure branches deterministically: a real
    /// `simctl` against a bogus UDID was assumed to fail the same way every
    /// time, and CI disproved that assumption.
    let processRunner: ProcessRunner

    /// The scheme-discovery/resolution collaborator — see
    /// `XcodeSchemeResolver`'s own doc comment. Extracted from this struct in
    /// v2 Step 4 §7 Step 1; every method a test calls directly
    /// (`discoverSchemes`/`resolveScheme`) stays declared here, unchanged
    /// signature, forwarding to this collaborator.
    let schemeResolver: XcodeSchemeResolver

    /// The stale-app-uninstall collaborator — see `StaleAppUninstaller`'s own
    /// doc comment. Extracted from this struct in v2 Step 4 §7 Step 2;
    /// `uninstallStaleApp` stays declared here, unchanged signature,
    /// forwarding to this collaborator.
    let uninstaller: StaleAppUninstaller

    /// The shared "launch `xcodebuild test-without-building`, handle a
    /// launch failure or timeout" collaborator — see
    /// `XCTestInvocationService`'s own doc comment. Extracted from this
    /// struct in v2 Step 4 §7 Step 3; `runTestsOnDestination`/
    /// `runSchemataTokenOnDestination` stay declared here, unchanged
    /// signature, each now a thin resolve-inputs-then-forward wrapper.
    let invocationService: XCTestInvocationService

    /// The device-selection-and-lease collaborator — see
    /// `SimulatorLeaseCoordinator`'s own doc comment. Extracted from this
    /// struct in v2 Step 4 §7 Step 5; `leaseAndRunTests`,
    /// `leaseAndRunSchemataToken`, and `runBatchTests` stay declared here,
    /// each now delegating device selection to this collaborator while
    /// keeping its own `SimulatorPoolError`-to-`TestRunResult` shaping and
    /// (for the schemata path) its own `GateTimingRecorder` wrap, since each
    /// of the three shapes that failure value differently today.
    let leaseCoordinator: SimulatorLeaseCoordinator

    /// The build collaborator — see `BuildDriver`'s own doc comment. Extracted
    /// from this struct in v2 Step 4 §7 Step 6; `build(in:enableCoverage:
    /// extraArguments:)` stays declared here (private, called by
    /// `buildBaseline`/`buildMutant`/`buildSchemataChunk`/`readCoverage`,
    /// none of which change), now a thin resolve-inputs-then-forward
    /// wrapper. `BuildDriver`'s own stored-property list has no
    /// `SimulatorPool`/`SimulatorLeaseCoordinator`/`resolvedDestination` —
    /// see its file's header comment for why that is Structural Invariant
    /// 1's structural enforcement, not just an incidental fact.
    let buildDriver: BuildDriver

    /// Where each `xcodebuild -list -json` attempt's timing is appended, or
    /// `nil` to record nothing — the default on every path that does not say
    /// otherwise, since the variable is unset outside CI.
    ///
    /// Read once here rather than from the global environment at each call
    /// site so a test can point one adapter at its own file without setting a
    /// process-wide variable that every *other* adapter running concurrently
    /// in the same test process would then also write to.
    var schemeDiscoveryLogPath: String? =
        ProcessInfo.processInfo.environment[SchemeDiscoveryObservationLog.environmentVariable]

    public init(
        configuration: Configuration,
        kind: ProjectKind,
        projectFile: URL?,
        projectRoot: URL,
        resolvedDestination: ResolvedDestination? = nil,
        workerDevicesByWorkspace: [String: SimulatorDevice]? = nil
    ) {
        self.configuration = configuration
        self.kind = kind
        projectFileRelativePath = projectFile.flatMap { Self.relativePath(of: $0, under: projectRoot) }
        resultReader = XCResultAdapter()
        simulators = SimulatorPool(workingDirectory: projectRoot)
        self.resolvedDestination = resolvedDestination
        self.workerDevicesByWorkspace = workerDevicesByWorkspace
        processRunner = defaultProcessRunner
        schemeResolver = XcodeSchemeResolver(
            configuredScheme: configuration.project.scheme,
            projectFileRelativePath: projectFileRelativePath,
            kind: kind,
            processRunner: processRunner
        )
        uninstaller = StaleAppUninstaller(processRunner: processRunner)
        invocationService = XCTestInvocationService(
            terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds,
            resultReader: XCResultAdapter()
        )
        leaseCoordinator = SimulatorLeaseCoordinator(simulators: simulators, resolvedDestination: resolvedDestination)
        buildDriver = BuildDriver(
            kind: kind, projectFileRelativePath: projectFileRelativePath, configuration: configuration, scheme: schemeResolver
        )
    }

    /// Test-only initializer that injects the simulator pool and the
    /// `simctl` process seam, so `prepareSimulatorForRun()`'s outcome
    /// mapping and `uninstallStaleApp`'s fail-closed contract can both be
    /// exercised against scripted doubles without a real simulator.
    /// Internal to keep it out of the public surface.
    init(
        configuration: Configuration,
        kind: ProjectKind,
        projectFile: URL?,
        projectRoot: URL,
        resolvedDestination: ResolvedDestination?,
        simulators: SimulatorPool,
        workerDevicesByWorkspace: [String: SimulatorDevice]? = nil,
        processRunner: @escaping ProcessRunner = defaultProcessRunner
    ) {
        self.configuration = configuration
        self.kind = kind
        projectFileRelativePath = projectFile.flatMap { Self.relativePath(of: $0, under: projectRoot) }
        resultReader = XCResultAdapter()
        self.simulators = simulators
        self.resolvedDestination = resolvedDestination
        self.workerDevicesByWorkspace = workerDevicesByWorkspace
        self.processRunner = processRunner
        schemeResolver = XcodeSchemeResolver(
            configuredScheme: configuration.project.scheme,
            projectFileRelativePath: projectFileRelativePath,
            kind: kind,
            processRunner: processRunner
        )
        uninstaller = StaleAppUninstaller(processRunner: processRunner)
        invocationService = XCTestInvocationService(
            terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds,
            resultReader: XCResultAdapter()
        )
        leaseCoordinator = SimulatorLeaseCoordinator(simulators: simulators, resolvedDestination: resolvedDestination)
        buildDriver = BuildDriver(
            kind: kind, projectFileRelativePath: projectFileRelativePath, configuration: configuration, scheme: schemeResolver
        )
    }

    /// The device name in a destination string, if it names one.
    ///
    /// `platform=iOS Simulator,name=iPhone 17 Pro` → `iPhone 17 Pro`.
    static func deviceName(inDestination destination: String) -> String? {
        for field in destination.split(separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "name" else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Whether this destination runs on a simulator device that must not be shared.
    ///
    /// A generic or macOS destination has no device to contend over. Unlike
    /// the original version of this check, a destination pinned to `id=` is
    /// *not* exempted: once `resolvedDestination` is set, `destination()`
    /// itself always returns an `id=` string (see below), and that device
    /// still needs exactly the same mutual exclusion an unresolved
    /// `name=` destination would have needed — the resolution changed
    /// *which* string names the device, not whether concurrent workers can
    /// still collide on it.
    var destinationNeedsSimulatorLease: Bool {
        let target = destination()
        // This used to check only `"iOS Simulator"`. A tvOS/watchOS/visionOS
        // destination is exactly as shared and exactly as unsafe for two
        // concurrent workers to install/run tests on at once as an iOS one
        // is — reusing `DestinationResolver.isSimulatorDestination` (the
        // same check that now also resolves those destinations to a pinned
        // device in the first place) rather than keeping a second, narrower
        // copy of this logic that would silently under-lease the three
        // platforms the other copy was just fixed for.
        return DestinationResolver.isSimulatorDestination(target)
            && !target.localizedCaseInsensitiveContains("generic/")
    }

    /// `nil` when the file lies outside the root — a layout we cannot sandbox, and
    /// one the caller must not silently paper over.
    static func relativePath(of file: URL, under root: URL) -> String? {
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    /// Boots and verifies readiness of the device this adapter's tests will
    /// run on, if it has a resolved simulator destination. No-op for macOS
    /// destinations, packages without a simulator, and adapters that were
    /// never given a `resolvedDestination`.
    ///
    /// Idempotent and cheap on a warm device: `bootstatus` returns
    /// immediately. The CLI calls this once at run start so the first
    /// `xcodebuild` test invocation does not pay the cold-boot tax or hit
    /// the CoreSimulator race a cold first install was found to hit.
    ///
    /// Returns a record of what happened — warm, cold, or failed — rather
    /// than dropping the result: the run logs it, persists it to the
    /// `RunManifest`, and (per the fail-closed policy in `RunCommand`) stops
    /// before the baseline if readiness could not be verified.
    public func prepareSimulatorForRun() async -> SimulatorPreparationRecord {
        guard let device = resolvedDestination?.device else {
            return SimulatorPreparationRecord(outcome: .notApplicable)
        }
        do {
            let outcome = try await simulators.prepare(udid: device.udid)
            return SimulatorPreparationRecord(
                outcome: outcome == .alreadyBooted ? .alreadyBooted : .prepared,
                udid: device.udid,
                name: device.name
            )
        } catch {
            return SimulatorPreparationRecord(
                outcome: .failed,
                udid: device.udid,
                name: device.name,
                detail: "\(error)"
            )
        }
    }

    // MARK: - Invocation shape

    /// `-workspace`/`-project` resolved inside `workspace`, or nothing for a package.
    private func projectArguments(in workspace: URL) -> [String] {
        guard let projectFileRelativePath else { return [] }
        let path = workspace.appendingPathComponent(projectFileRelativePath).path
        switch kind {
        case .xcodeWorkspace: return ["-workspace", path]
        case .xcodeProject: return ["-project", path]
        case .swiftPackageApple, .swiftPackageMacOS, .auto: return []
        }
    }

    /// Where DerivedData goes for this workspace.
    ///
    /// Always explicit, and meant to always stay inside the sandbox. Xcode's
    /// default is a shared path keyed by project name, so every concurrent
    /// mutant — each a copy of the same project, and therefore sharing that
    /// name — would build into one directory and overwrite the binaries the
    /// others are about to test. Mutants would then be scored against each
    /// other's products.
    ///
    /// The primary guarantee against that is upstream: `ConfigurationValidator`
    /// rejects an absolute `project.derivedDataPath` before a run ever starts,
    /// so this function should never actually be asked to resolve one. The
    /// `hasPrefix("/")` branch below is a defensive fallback, not the
    /// guarantee itself — kept because this adapter can be constructed
    /// directly (e.g. in tests) without going through that validation step.
    ///
    /// Same story for a symlinked path component that resolves outside the
    /// workspace (`derivedDataPath: ExternalDD/build` where `ExternalDD` is
    /// a symlink): `ConfigurationValidator` now rejects that too, by
    /// resolving symlinks against the real project directory and requiring
    /// a strict descendant. That check deliberately lives there, not here:
    /// this function only ever sees `workspace`, a per-worker sandbox
    /// already copied once the run has started, whereas the validator can
    /// inspect the original tree before any worker exists — the earliest
    /// point a symlink on disk can be observed at all. This function does
    /// not re-resolve and refuse on its own; doing so here would either
    /// silently coerce the path or crash a run a config-time check should
    /// already have stopped, and this codebase prefers the latter checked
    /// loudly up front (see the validator's doc comment).
    func derivedDataPath(in workspace: URL) -> URL {
        if let configured = configuration.project.derivedDataPath {
            // Checked on `configured` itself, not on `URL(fileURLWithPath:
            // configured).path` — that initializer always yields an absolute
            // path (resolving a relative input against the current working
            // directory), so testing the resolved URL's path would always be
            // true and this fallback would never actually resolve a relative
            // path against the workspace as intended.
            guard configured.hasPrefix("/") else {
                return workspace.appendingPathComponent(configured)
            }
            return URL(fileURLWithPath: configured)
        }
        return workspace.appendingPathComponent(".mutantkit/DerivedData", isDirectory: true)
    }

    /// `xcodebuild test-without-building` arguments, extracted so the target
    /// filter can be pinned without needing a real toolchain to run it against.
    ///
    /// An xctestrun built for a scheme with more than one test target (a UI test
    /// target alongside the unit tests, say) runs all of them unless told
    /// otherwise. Left unfiltered, `tests.targets` — which the SwiftPM adapter
    /// honours with `--filter` — would silently do nothing here, and every
    /// mutant's classification would include targets the user never asked to
    /// measure against: slower, and liable to fail the baseline on a UI test
    /// that has nothing to do with the mutation being scored.
    /// - Parameters:
    ///   - targets: what to run, as `-only-testing:` selectors. Accepts
    ///     either granularity the flag itself accepts: a bare test target
    ///     (`"AppTests"`, the normal case) or a single fully-qualified test
    ///     (`"AppTests/AddTests/testAdd"`, used to narrow a mutant's run to
    ///     the tests `TestSelecting` attributed to its line). Both are valid
    ///     `-only-testing:` selectors, so no separate code path is needed
    ///     for the narrowed case.
    ///   - enableCoverage: adds `-enableCodeCoverage YES`. Used for the
    ///     baseline run — whole-suite or, once per test, individually — that
    ///     `CoverageMeasuring`/`TestSelecting` read back afterward; never for
    ///     an ordinary mutant run, which has no use for the instrumentation
    ///     and would only pay its cost.
    static func testWithoutBuildingArguments(
        xctestrunPath: String,
        destination: String,
        resultBundlePath: String,
        targets: [String],
        extraArguments: [String],
        enableCoverage: Bool = false
    ) -> [String] {
        var arguments = [
            "test-without-building",
            "-xctestrun", xctestrunPath,
            "-destination", destination,
            // Always requested, so there is always a structured record to classify
            // from. Without it a failing run leaves only console text, and console
            // text is not something this tool is willing to decide an outcome from.
            "-resultBundlePath", resultBundlePath,
            // xcodebuild's default (`on-failure`) shells out to `simctl diagnose` —
            // a sysdiagnose-grade log collection with its own internal timeout in
            // the hundreds of seconds — the moment any mutant's first test fails,
            // which every survived-vs-killed mutant does by design half the time.
            // Found the hard way: a mutant can sit for minutes past what its own
            // test takes while this runs, racing mutantkit's own timeout — and if that
            // timeout fires first, the result bundle it kills mid-write is exactly
            // the shape a wrong verdict comes from. This tool builds its own
            // evidence from the structured result and the build product hash; it
            // has no use for a sysdiagnose.
            "-collect-test-diagnostics", "never"
        ]
        if enableCoverage {
            arguments.append(contentsOf: ["-enableCodeCoverage", "YES"])
        }
        for target in targets {
            arguments.append("-only-testing:\(target)")
        }
        arguments.append(contentsOf: extraArguments)
        return arguments
    }

    /// The destination to build and test against.
    ///
    /// A package for a non-host platform needs a real one; guessing a specific
    /// simulator here would be the same class of mistake as guessing the
    /// `.xctestrun` name, so an unconfigured package asks for `generic/platform=iOS`
    /// at build time and requires a leased device at test time.
    ///
    /// `resolvedDestination` — when set — wins over the raw configuration:
    /// it is what `DestinationResolver` already resolved `name=`/implicit
    /// `OS:latest` to, once, at run start, and every build and test in the
    /// run must address that same device, not re-derive its own answer.
    func destination() -> String {
        if let resolvedDestination { return resolvedDestination.destinationArgument }
        if let configured = configuration.project.destination { return configured }
        return DestinationResolver.defaultDestination(for: kind)
    }

    // MARK: - Scheme

    //
    // Delegates entirely to `schemeResolver` (v2 Step 4 §7 Step 1 — see
    // `XcodeSchemeResolver`'s own doc comment). These two methods stay
    // declared here, unchanged signature, because `@testable` unit tests
    // call them directly on `XcodeBuildAdapter`
    // (`XcodeBuildAdapterSchemeDiscoveryRetryTests`,
    // `SchemeDiscoveryObservationLogTests`) — see plan §6's design
    // constraint. `schemeDiscoveryLogPath` is read here, at the call site,
    // rather than baked into `schemeResolver` at construction time: it is a
    // mutable `var` tests set *after* constructing the adapter, so it must
    // be threaded through per call to keep observing the current value.

    /// The scheme to build. See `XcodeSchemeResolver.resolve(in:logPath:)`.
    func resolveScheme(in workspace: URL) async throws -> String {
        try await schemeResolver.resolve(in: workspace, logPath: schemeDiscoveryLogPath)
    }

    /// Discovered schemes, or an empty list when discovery itself failed.
    /// See `XcodeSchemeResolver.discover(in:emptyResultRetryCount:logPath:)`.
    ///
    /// `public`, not just used internally by `resolveScheme`: `XcodeConfigDetector`
    /// (`init`/`doctor` auto-detection) needs this exact same real
    /// `xcodebuild -list -json` discovery, before any `Configuration` exists
    /// to construct a full adapter for a real run.
    public func discoverSchemes(in workspace: URL, emptyResultRetryCount: Int = 2) async -> [String] {
        await schemeResolver.discover(
            in: workspace, emptyResultRetryCount: emptyResultRetryCount, logPath: schemeDiscoveryLogPath
        )
    }
}

// MARK: - Build

extension XcodeBuildAdapter: BuildAdapter {
    public func buildBaseline(in workspace: URL) async throws -> BuildArtifact {
        try await build(in: workspace)
    }

    public func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact {
        try await build(in: workspace)
    }

    /// - Parameter enableCoverage: adds `-enableCodeCoverage YES` to
    ///   `build-for-testing` itself. Confirmed necessary, not just the test
    ///   invocation's own `-enableCodeCoverage YES`, on a real Xcode
    ///   project (a hand-authored `.xcodeproj`, not an auto-generated
    ///   SwiftPM scheme): source-based coverage is compiled in, and a
    ///   binary `build-for-testing` produced without the flag has no
    ///   instrumentation for `test-without-building` to retroactively turn
    ///   on — confirmed by a bundle whose `content-availability` reported
    ///   `hasCoverage: false` despite the test-time flag. Only ever used
    ///   for the dedicated coverage rebuild in `readCoverage`/
    ///   `measurePerTestCoverage`, never for `buildBaseline`/`buildMutant`:
    ///   an instrumented baseline's product hash would differ from every
    ///   mutant's uninstrumented one purely from the added profiling
    ///   counters, making every mutant look "activated" whether or not its
    ///   own edit actually reached the binary — the same reason
    ///   `SwiftPackageMacOSAdapter` captures its baseline's hash *before*
    ///   the coverage-instrumented test rebuild rather than after.
    private func build(in workspace: URL, enableCoverage: Bool = false, extraArguments: [String] = []) async throws -> BuildArtifact {
        try await buildDriver.build(
            in: workspace,
            buildDestination: destination(),
            schemeDiscoveryLogPath: schemeDiscoveryLogPath,
            enableCoverage: enableCoverage,
            extraArguments: extraArguments
        )
    }

    public func diagnose() async throws -> BuildDiagnosis {
        await Diagnostics.full(adapter: self)
    }
}

// MARK: - Test

extension XcodeBuildAdapter: TestAdapter {
    public func runBaseline(
        _ artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await runTests(
            artifact: artifact,
            in: workspace,
            label: "baseline",
            timeoutSeconds: timeoutSeconds,
            enableCoverage: configuration.execution.measureCoverage || configuration.execution.selectCoveringTests
        )
    }

    public func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async throws -> TestRunResult {
        try await runMutant(point, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, selectedTests: nil)
    }

    /// Runs the tests, holding a simulator for exactly as long as they need it.
    ///
    /// Only the test phase leases. A build never boots the device, so builds still
    /// run fully in parallel — and they dominate the wall clock, so serializing on
    /// a scarce device costs much less than it appears to.
    ///
    /// Without this, concurrent mutants were handed the same `name=` destination
    /// and fought over one device. The loser did not fail cleanly: it exceeded its
    /// timeout, was recorded `timedOut`, and vanished from the score — which is
    /// excluded from both denominators. Two runs of the same plan then disagreed,
    /// intermittently and silently, on the tool's primary use case.
    private func runTests(
        artifact: BuildArtifact,
        in workspace: URL,
        label: String,
        timeoutSeconds: Double,
        testFilters: [String]? = nil,
        enableCoverage: Bool = false,
        expectedTestCount: Int? = nil
    ) async throws -> TestRunResult {
        guard destinationNeedsSimulatorLease else {
            return try await runTestsOnDestination(
                destination(), artifact: artifact, in: workspace, label: label, timeoutSeconds: timeoutSeconds,
                testFilters: testFilters, enableCoverage: enableCoverage, expectedTestCount: expectedTestCount
            )
        }

        do {
            return try await leaseAndRunTests(
                artifact: artifact, in: workspace, label: label, timeoutSeconds: timeoutSeconds,
                testFilters: testFilters, enableCoverage: enableCoverage, expectedTestCount: expectedTestCount
            )
        } catch let error as SimulatorPoolError {
            return TestRunResult(
                status: .infrastructureFailure,
                summary: nil,
                command: artifact.command,
                resultArtifactPath: nil,
                diagnosis: "No simulator could be leased for this mutant: \(error.description)"
            )
        }
    }

    /// Which device this run's tests land on is `leaseCoordinator`'s own
    /// decision (v2 Step 4 §7 Step 5 — see `SimulatorLeaseCoordinator`'s own
    /// doc comment for the four-case fallback order and why
    /// `workerDevicesByWorkspace` — when this mutant's persistent
    /// incremental-build sandbox (`workspace`) has an entry — is passed as
    /// `leaseAndRunTests`'s own `preferredDevice`, ahead of every other
    /// case). Exclusivity is structurally guaranteed even for a worker's own
    /// preferred device (each worker's own sandbox is only ever touched by
    /// that one worker, serially), but leasing it anyway, same as every
    /// other case, costs nothing and keeps "at most one lease per device" a
    /// real invariant `SimulatorPool` enforces, not one this call site
    /// merely assumes.
    /// The uninstall-then-launch decision itself, factored out of
    /// `leaseAndRunTests` so `XcodeBuildAdapterUninstallFailureTests` can
    /// drive it directly with a hand-built `SimulatorLease` — the same
    /// reason `uninstallStaleApp` itself is `internal`, not `private`: a
    /// real `SimulatorPool` lease needs a real, already-booted device, which
    /// a launch-suppression regression has no need to depend on. This is
    /// also the one place that actually enforces the fail-closed uninstall
    /// contract: a failed uninstall must never reach `runTestsOnDestination` at all.
    func runTestsAfterUninstall(
        lease: SimulatorLease,
        artifact: BuildArtifact,
        in workspace: URL,
        label: String,
        timeoutSeconds: Double,
        testFilters: [String]? = nil,
        enableCoverage: Bool = false,
        expectedTestCount: Int? = nil
    ) async throws -> TestRunResult {
        if case let .failed(bundleID, detail) = await uninstallStaleApp(artifact: artifact, from: lease) {
            return Self.uninstallFailureResult(bundleID: bundleID, udid: lease.device.udid, detail: detail, command: artifact.command)
        }
        return try await runTestsOnDestination(
            lease.destination, artifact: artifact, in: workspace, label: label, timeoutSeconds: timeoutSeconds,
            testFilters: testFilters, enableCoverage: enableCoverage, expectedTestCount: expectedTestCount
        )
    }

    private func leaseAndRunTests(
        artifact: BuildArtifact,
        in workspace: URL,
        label: String,
        timeoutSeconds: Double,
        testFilters: [String]? = nil,
        enableCoverage: Bool = false,
        expectedTestCount: Int? = nil
    ) async throws -> TestRunResult {
        @Sendable func run(_ lease: SimulatorLease) async throws -> TestRunResult {
            try await runTestsAfterUninstall(
                lease: lease, artifact: artifact, in: workspace, label: label, timeoutSeconds: timeoutSeconds,
                testFilters: testFilters, enableCoverage: enableCoverage, expectedTestCount: expectedTestCount
            )
        }

        // Device selection delegated to `leaseCoordinator` (v2 Step 4 §7
        // Step 5 — see `SimulatorLeaseCoordinator`'s own doc comment). The
        // per-worker device, when this mutant's sandbox has one assigned, is
        // passed as `preferredDevice` — this is the *only* one of the three
        // call sites that does (plan §5.1); the other two always pass `nil`.
        return try await leaseCoordinator.withLease(
            preferredDevice: workerDevicesByWorkspace?[workspace.lastPathComponent],
            rawDestination: destination(),
            run: run
        )
    }

    /// The device UDID in a destination string, if it names one.
    ///
    /// `platform=iOS Simulator,id=8B23...` → `8B23...`.
    static func udid(inDestination destination: String) -> String? {
        for field in destination.split(separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "id" else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Removes whatever this leased device already has installed under the
    /// mutant's own bundle identifier before it is tested.
    ///
    /// Confirmed necessary, not just suspected, on a real project (the Debug
    /// Dylib fixture): two mutants sharing one leased simulator device, run
    /// back to back by the pool exactly as designed, occasionally produced a
    /// verdict that matched neither binary — a mutation the build product
    /// proves reached the binary was reported `survived` although the
    /// identical, already-built sandbox failed deterministically when built
    /// and tested by hand outside the pool, on the same device, moments
    /// later. Disabling only this call (with the `-collect-test-diagnostics`
    /// fix below still active) reproduced the exact same impossible verdict
    /// on the very first run afterward; re-enabling it made three separate
    /// runs agree with ground truth. The pool guarantees no two mutants
    /// install at the same time; it says nothing about what CoreSimulator
    /// does with an app already registered under the same bundle identifier
    /// from the mutant before, and an explicit uninstall removes that
    /// variable outright rather than trusting `test-without-building` to
    /// notice the difference.
    ///
    /// **Fail-closed: a genuine `simctl uninstall` failure blocks
    /// this mutant's run** — the caller must never proceed to launch
    /// `xcodebuild test-without-building` once this returns `.failed`.
    /// Confirmed directly against a real simulator: `simctl uninstall` on a
    /// bundle ID that was never installed still **exits 0**, with no error
    /// output at all — "nothing to uninstall" is not distinguishable from
    /// "uninstalled successfully" at the exit-code level, and does not need
    /// to be, since both are the fully-expected, ordinary case this method
    /// exists to handle silently (`.ready`). That means a *non-zero* exit
    /// here is never the ordinary case — it is always a real failure (a busy
    /// device, a transient CoreSimulator fault, the same class of flake
    /// `SimulatorPool.prepare`'s own retry logic exists to absorb
    /// elsewhere).
    /// This method previously only logged a genuine failure (stderr) and let
    /// the caller proceed regardless — an earlier version of its own doc
    /// comment reasoned that surfacing the fact was enough. It was not: a
    /// stale install surviving an uninstall failure immediately before the
    /// next test run can make a runtime image UUID disagree with the build
    /// receipt, or a leftover process shadow a fresh mutant's own result,
    /// without needing a rebuild at all — exactly the class of
    /// infrastructure hazard this codebase otherwise never launches a real
    /// test run on top of (see the `boot`/`bootstatus` failure class,
    /// retried and diagnosed, never silently proceeded past). `report`
    /// still fires on every failure (mirroring `MutationRunner`'s own
    /// convention for an infrastructure hiccup that must not vanish
    /// silently from a human's view), but the return value is now what a
    /// caller must actually act on.
    /// return value is now what a caller must actually act on.
    ///
    /// `report` is a seam, not a production knob: every real caller uses the
    /// default (a real `FileHandle.standardError.write`), and
    /// `XcodeBuildAdapterUninstallFailureTests` overrides it to capture
    /// exactly what would have been reported, against a real `simctl`
    /// invocation with a deliberately-invalid device, without needing to
    /// intercept the process's actual stderr file descriptor. `internal`
    /// (not `private`), for the same reason: a test in another file needs
    /// to call this directly, bypassing the full `leaseAndRunTests` path
    /// that would otherwise require a real build and a real lease to reach
    /// it at all.
    /// The `simctl` invocation itself goes through this adapter's own
    /// `processRunner` property, so a scripted failure reaches every caller
    /// of this method — including `runTestsAfterUninstall` and
    /// `runSchemataTokenAfterUninstall`, whose launch-suppression contract
    /// can therefore be proven without a real simulator at all.
    /// See `StaleAppUninstaller.Outcome` — kept as a `typealias` rather than
    /// a re-declared type, so `XcodeBuildAdapterUninstallFailureTests`'
    /// `guard case let .failed(...) = outcome` (type-inferred, never
    /// spelling a qualified name) keeps compiling unchanged.
    typealias StaleAppUninstallOutcome = StaleAppUninstaller.Outcome

    /// Delegates entirely to `uninstaller` (v2 Step 4 §7 Step 2 — see
    /// `StaleAppUninstaller`'s own doc comment). Stays declared here,
    /// unchanged signature, because `XcodeBuildAdapterUninstallFailureTests`
    /// calls it directly — see plan §6's design constraint.
    func uninstallStaleApp(
        artifact: BuildArtifact, from lease: SimulatorLease,
        report: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) async -> StaleAppUninstallOutcome {
        await uninstaller.uninstall(artifact: artifact, from: lease, report: report)
    }

    /// The `TestRunResult` a caller reports when `uninstallStaleApp` returns
    /// `.failed`, in place of ever launching `xcodebuild
    /// test-without-building` — the diagnosis text is the same
    /// `uninstallFailureWarning` a human watching the run sees on stderr, so
    /// a report reader sees exactly why this mutant never got a real test
    /// verdict. Stays here rather than moving to `StaleAppUninstaller`: it
    /// builds a `TestRunResult`, this adapter's own return type, not the
    /// uninstaller's concern (plan §7 Step 2).
    static func uninstallFailureResult(bundleID: String, udid: String, detail: String, command: CommandRecord) -> TestRunResult {
        TestRunResult(
            status: .infrastructureFailure, summary: nil, command: command, resultArtifactPath: nil,
            diagnosis: uninstallFailureWarning(bundleID: bundleID, udid: udid, detail: detail).trimmingCharacters(in: .newlines)
        )
    }

    /// Thin forwarder kept here (unlike `uninstallFailureDetail`/
    /// `bundleIdentifiers`, which moved without a trace left behind):
    /// `XcodeBuildAdapterUninstallFailureTests`' own "uninstallFailureWarning
    /// names the bundle, the device, and the real detail" test calls
    /// `XcodeBuildAdapter.uninstallFailureWarning` directly as a static, and
    /// `uninstallFailureResult` above also needs it.
    static func uninstallFailureWarning(bundleID: String, udid: String, detail: String) -> String {
        StaleAppUninstaller.uninstallFailureWarning(bundleID: bundleID, udid: udid, detail: detail)
    }

    /// Delegates the shared launch/timeout shape to `invocationService` (v2
    /// Step 4 §7 Step 3 — see `XCTestInvocationService`'s own doc comment).
    /// What stays here is resolving `artifact.xctestrunPath` (including its
    /// own "no `.xctestrun` at all" early return, unchanged) and classifying
    /// the result via `resultReader.classify(...expectedTestCount:)` — the
    /// isolated path's own classify shape, which the schemata path's does
    /// not share (see plan §5.4/§6.3).
    private func runTestsOnDestination(
        _ destination: String,
        artifact: BuildArtifact,
        in workspace: URL,
        label: String,
        timeoutSeconds: Double,
        testFilters: [String]? = nil,
        enableCoverage: Bool = false,
        expectedTestCount: Int? = nil
    ) async throws -> TestRunResult {
        guard let xctestrun = artifact.xctestrunPath else {
            return TestRunResult(
                status: .infrastructureFailure,
                summary: nil,
                command: artifact.command,
                resultArtifactPath: nil,
                diagnosis: """
                The build produced no .xctestrun, so there is nothing for \
                test-without-building to run.
                """
            )
        }

        let resultBundle = resultBundlePath(in: workspace, label: label)
        let arguments = Self.testWithoutBuildingArguments(
            xctestrunPath: xctestrun.path,
            destination: destination,
            resultBundlePath: resultBundle.path,
            targets: testFilters ?? configuration.tests.targets,
            extraArguments: configuration.tests.extraArguments,
            enableCoverage: enableCoverage
        )

        return await invocationService.runSingle(
            arguments: arguments,
            resultBundle: resultBundle,
            timeoutSeconds: timeoutSeconds,
            timeoutDiagnosis: """
            The test run exceeded its \(String(format: "%.0f", timeoutSeconds))s limit \
            and was terminated.
            """,
            in: workspace
        ) {
            await resultReader.classify(
                resultBundle: resultBundle, workingDirectory: workspace, expectedTestCount: expectedTestCount
            )
        }
    }

    /// A bundle path unique to this run.
    ///
    /// Keyed by mutation ID because concurrent workers share a machine, and a
    /// second `test-without-building` writing to a path a first is still reading
    /// would corrupt both records.
    private func resultBundlePath(in workspace: URL, label: String) -> URL {
        let safe = label.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return workspace
            .appendingPathComponent(".mutantkit/Results", isDirectory: true)
            .appendingPathComponent("\(String(safe)).xcresult")
    }
}

// MARK: - Schemata build

extension XcodeBuildAdapter: SchemataBuildable {
    public func buildSchemataChunk(loweredSources: [SchemataSourceFile], in workspace: URL) async throws -> BuildArtifact {
        for source in loweredSources {
            try SchemataSourceWriter.write(source, in: workspace)
        }

        let target = destination()
        guard let platform = SchemataRuntimePlatform.resolve(destination: target) else {
            throw SchemataRuntimeLibraryLocator.LocatorError.unsupportedDestination(target)
        }
        let located = try SchemataRuntimeLibraryLocator.locate(for: platform)
        let linkerArguments = XcodeLinkerInjector.extraArguments(archivePath: located.archivePath)
        let buildStart = GateTimingRecorder.shared.now()
        let artifact = try await build(in: workspace, extraArguments: linkerArguments)
        await GateTimingRecorder.shared.record("chunk.build", chunkID: workspace.lastPathComponent, start: buildStart)
        return artifact
    }

    public func resolveSchemataBuildReceipt(
        for units: [SchemataCompilationUnitTargetRequest],
        artifact: BuildArtifact,
        in workspace: URL,
        context: SchemataBuildReceiptContext
    ) async throws -> SchemataBuildReceipt {
        let receiptStart = GateTimingRecorder.shared.now()
        defer {
            Task { await GateTimingRecorder.shared.record("receipt.resolve", chunkID: context.chunkID, start: receiptStart) }
        }
        // Deliberately not `destination()`: reading back where this chunk's
        // product was written must not depend on the run's device still
        // existing — see `DestinationResolver.buildSettingsDestination(for:)`.
        let buildSettingsContext = XcodeCompilationUnitImageResolver.BuildSettingsContext(
            projectArguments: projectArguments(in: workspace), scheme: try await resolveScheme(in: workspace),
            destination: DestinationResolver.buildSettingsDestination(for: destination()),
            derivedDataPath: derivedDataPath(in: workspace), workspace: workspace, timeoutSeconds: configuration.timeouts.baselineSeconds
        )
        let targetsByName = Dictionary(grouping: units, by: \.buildTarget.targetName)

        var imagesByTarget: [BuildTargetIdentity: BuiltImageReceipt] = [:]
        for (targetName, requests) in targetsByName {
            let buildTarget = requests[0].buildTarget
            let resolved = try await XcodeCompilationUnitImageResolver.resolveArtifactPath(
                target: targetName, context: buildSettingsContext
            )
            let discovered = try SchemataBuiltImageInspection.inspectSingle(at: resolved.path, bundleName: resolved.bundleName)
            imagesByTarget[buildTarget] = try BuiltImageReceipt(
                buildTarget: buildTarget, binaryPath: discovered.binaryPath, contentHash: discovered.contentHash, slices: discovered.slices
            )
        }

        let compilationUnits = units.map {
            CompilationUnitReceipt(
                compilationUnitID: $0.compilationUnitID, sourceEmbeddingID: $0.sourceEmbeddingID, buildTarget: $0.buildTarget
            )
        }

        return try SchemataBuildReceipt(
            planID: context.planID, workUnitID: context.workUnitID, chunkID: context.chunkID,
            toolchainHash: context.toolchainHash, buildArgumentsHash: context.buildArgumentsHash,
            runtimeABIVersion: UInt32(BoolLiteralSchemataLowerer.runtimeABIVersion),
            images: Array(imagesByTarget.values), compilationUnits: compilationUnits
        )
    }
}

// MARK: - Schemata test

extension XcodeBuildAdapter: SchemataTestable {
    /// Runs the already-built schemata chunk once for one requested token,
    /// without rebuilding — the Xcode analogue of `SwiftPackageMacOSAdapter
    /// .runSchemataToken`. Simulator leasing mirrors `runTests`/
    /// `leaseAndRunTests` exactly (only the test phase leases a device; a
    /// build never does).
    public func runSchemataToken(
        _ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String],
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        // Same empty-means-nil normalisation `TestSelecting.runMutant` uses
        // above: an empty selection is never sent to `-only-testing:`, which
        // would run nothing. Falls back to the full configured list, same as
        // `selectedTests == nil`.
        let filters = selectedTests.flatMap { $0.isEmpty ? nil : $0.map(\.onlyTestingArgument) }
        guard destinationNeedsSimulatorLease else {
            return try await runSchemataTokenOnDestination(
                destination(), artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, environment: environment,
                testFilters: filters
            )
        }

        do {
            return try await leaseAndRunSchemataToken(
                artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, environment: environment, testFilters: filters
            )
        } catch let error as SimulatorPoolError {
            return TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "No simulator could be leased for this schemata token run: \(error.description)"
            )
        }
    }

    /// The schemata-path counterpart to `runTestsAfterUninstall` — same
    /// reason it exists as a directly-testable, `internal` seam: proving
    /// the fail-closed uninstall contract holds for the schemata launch path too, without
    /// needing a real `SimulatorPool` lease to reach it.
    func runSchemataTokenAfterUninstall(
        lease: SimulatorLease, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double,
        environment: [String: String], testFilters: [String]?
    ) async throws -> TestRunResult {
        let uninstallStart = GateTimingRecorder.shared.now()
        let uninstallOutcome = await uninstallStaleApp(artifact: artifact, from: lease)
        await GateTimingRecorder.shared.record("token.uninstall", start: uninstallStart)
        if case let .failed(bundleID, detail) = uninstallOutcome {
            return Self.uninstallFailureResult(bundleID: bundleID, udid: lease.device.udid, detail: detail, command: artifact.command)
        }
        return try await runSchemataTokenOnDestination(
            lease.destination, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds, environment: environment,
            testFilters: testFilters
        )
    }

    private func leaseAndRunSchemataToken(
        artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String], testFilters: [String]?
    ) async throws -> TestRunResult {
        @Sendable func run(_ lease: SimulatorLease) async throws -> TestRunResult {
            try await runSchemataTokenAfterUninstall(
                lease: lease, artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds,
                environment: environment, testFilters: testFilters
            )
        }

        // `token.leaseAndRun.total` must keep wrapping exactly this span —
        // device selection through lease acquisition through `run`'s own
        // body — unchanged by moving the device-selection logic itself into
        // `leaseCoordinator` (plan §5.4/§8: a mark's placement must move
        // with its sub-step, never separate from it).
        let leaseAndRunStart = GateTimingRecorder.shared.now()
        defer {
            Task { await GateTimingRecorder.shared.record("token.leaseAndRun.total", start: leaseAndRunStart) }
        }
        // `preferredDevice: nil` — the schemata path never honors
        // `workerDevicesByWorkspace` (plan §5.1); see
        // `SimulatorLeaseCoordinator`'s own doc comment.
        return try await leaseCoordinator.withLease(preferredDevice: nil, rawDestination: destination(), run: run)
    }

    /// `SchemataXcodeRuntimeAcceptanceTests` already proved by hand: setting
    /// `Process.environment` on the `xcodebuild test-without-building`
    /// invocation itself does not reliably reach the actual `xctest`
    /// process Xcode's own tooling launches — env vars must be injected
    /// into the `.xctestrun` plist's `EnvironmentVariables` dictionary
    /// instead, the same mechanism a scheme's own "Environment Variables"
    /// editor pane ultimately writes to. This writes a fresh variant of
    /// `artifact`'s own `.xctestrun` with `environment` merged in, per
    /// mutant, rather than mutating the one shared file every mutant's
    /// build produced (which concurrent mutants running against the same
    /// chunk build would otherwise race on).
    /// Delegates the shared launch/timeout shape to `invocationService` (v2
    /// Step 4 §7 Step 3 — see `XCTestInvocationService`'s own doc comment).
    /// What stays here: resolving `artifact.xctestrunPath`, writing the
    /// env-merged `.xctestrun` variant (`token.xctestrunVariant`, unchanged),
    /// and classifying with the schemata path's own `token.xcresultClassify`
    /// `GateTimingRecorder` wrap — a mark the isolated path does not have
    /// (plan §5.4) — so it stays here, bracketing only the classify call, not
    /// moved into the shared service.
    private func runSchemataTokenOnDestination(
        _ destination: String, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String],
        testFilters: [String]? = nil
    ) async throws -> TestRunResult {
        guard let baseXCTestRun = artifact.xctestrunPath else {
            return TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "The build produced no .xctestrun, so there is nothing for test-without-building to run."
            )
        }

        let variantXCTestRun: URL
        let variantStart = GateTimingRecorder.shared.now()
        do {
            variantXCTestRun = try XCTestRunLocator.writingVariant(mergingEnvironment: environment, into: baseXCTestRun)
        } catch {
            return TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "Could not write a schemata .xctestrun variant: \(error)"
            )
        }
        await GateTimingRecorder.shared.record("token.xctestrunVariant", start: variantStart)

        let resultBundle = resultBundlePath(in: workspace, label: "schemata-\(UUID().uuidString)")
        let arguments = Self.testWithoutBuildingArguments(
            xctestrunPath: variantXCTestRun.path, destination: destination, resultBundlePath: resultBundle.path,
            targets: testFilters ?? configuration.tests.targets, extraArguments: configuration.tests.extraArguments
        )

        return await invocationService.runSingle(
            arguments: arguments,
            resultBundle: resultBundle,
            timeoutSeconds: timeoutSeconds,
            timeoutDiagnosis: """
            The schemata test run exceeded its \(String(format: "%.0f", timeoutSeconds))s limit \
            and was terminated.
            """,
            in: workspace
        ) {
            let classifyStart = GateTimingRecorder.shared.now()
            let outcome = await resultReader.classify(resultBundle: resultBundle, workingDirectory: workspace)
            await GateTimingRecorder.shared.record("token.xcresultClassify", start: classifyStart)
            return outcome
        }
    }
}

// MARK: - Coverage

extension XcodeBuildAdapter: CoverageMeasuring {
    /// Rebuilds and re-tests the baseline once more, this time with
    /// coverage instrumentation, and reads back the result. Deliberately a
    /// second build rather than reusing `runBaseline`'s own bundle: that
    /// build was never instrumented (see `build(in:enableCoverage:)`), so
    /// its bundle has no coverage to read regardless of what flag the test
    /// step is given. `nil` when the rebuild, the retest, or the read
    /// itself fails — coverage is opt-in evidence; its absence never
    /// becomes a fabricated claim.
    public func readCoverage(in workspace: URL, projectRoot: URL) async -> CoverageMap? {
        guard let artifact = try? await build(in: workspace, enableCoverage: true) else { return nil }
        guard let run = try? await runTests(
            artifact: artifact,
            in: workspace,
            label: "coverage-baseline",
            timeoutSeconds: configuration.timeouts.baselineSeconds,
            enableCoverage: true
        ), run.status == .passed, let bundle = run.resultArtifactPath else { return nil }

        return await XccovCoverageReader.read(archive: bundle, projectRoot: projectRoot)
    }
}

// MARK: - Test selection

extension XcodeBuildAdapter: TestSelecting {
    public func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        // An empty selection is never sent to `-only-testing:` — that would
        // run nothing, and a run that tested nothing must never be mistaken
        // for one that passed. Falls back to the full configured list, the
        // same as `selectedTests == nil`.
        let filters = selectedTests.flatMap { $0.isEmpty ? nil : $0.map(\.onlyTestingArgument) }
        return try await runTests(
            artifact: artifact,
            in: workspace,
            label: point.id.description,
            timeoutSeconds: timeoutSeconds,
            testFilters: filters,
            // Only meaningful when the selection is truly narrowed: each
            // identifier in `selectedTests` names exactly one test, so its
            // count is the exact number of tests this run is expected to
            // execute. `configuration.tests.targets`, `filters`' own
            // fallback whenever `selectedTests` is nil/empty, names targets
            // (whole suites) instead — its count is not a test count at
            // all, so this must stay nil in that case rather than pass a
            // number that would misfire the zero-work invariant below.
            expectedTestCount: filters?.count
        )
    }

    public func measurePerTestCoverage(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        await PerTestCoverageProfileAttempt.resolve(
            fast: { await measurePerTestCoverageFast(artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds) },
            serial: { await measurePerTestCoverageSerial(artifact: artifact, in: workspace, timeoutSeconds: timeoutSeconds) }
        )
    }

    private func measurePerTestCoverageFast(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageProfileAttempt {
        .unavailable(reason: "no fast per-test coverage backend is implemented yet")
    }

    /// Runs every test the baseline bundle reports, one at a time, against
    /// the artifact already built for the baseline — no rebuild — with
    /// coverage enabled and its own scratch result bundle, and merges what
    /// each one touched into a reverse index.
    ///
    /// A one-time cost paid once per execution, not per mutant: found worth
    /// it on a real project, where the fixed cost of re-running an entire
    /// suite dominated every mutant's wall clock regardless of how few tests
    /// actually exercised the mutated line. Runs sequentially, one simulator
    /// lease at a time via `runTests`; spreading this pass across several
    /// leased devices concurrently is a further optimisation, not attempted
    /// here.
    ///
    /// The retry, and what becomes of a test that still cannot be proven,
    /// are `PerTestCoverageAttribution.attribute`'s — see its doc comment,
    /// and `PerTestCoverageMap`'s, for the policy and why it is safe. One
    /// thing specific to this adapter: a test that legitimately covers
    /// nothing is not distinguished from one that could not be measured,
    /// because `XccovCoverageReader.read` conservatively folds a
    /// validly-parsed, genuinely-empty export into the same `nil` a
    /// malformed one produces (see its own doc comment). Such a test is
    /// therefore treated as unattributed — safe, since that only means it is
    /// always run, but not the narrowest correct behaviour; sharpening it is
    /// a performance question for later.
    /// - Parameter artifact: `runBaseline`'s own, uninstrumented artifact —
    ///   kept only to enumerate test identifiers from its already-produced
    ///   bundle; never built or tested against directly. Per-test coverage
    ///   needs a coverage-instrumented binary (see
    ///   `build(in:enableCoverage:)`), built once here and reused for
    ///   every individual test run, exactly the same "instrumented copy is
    ///   never what activation evidence is measured against" split
    ///   `readCoverage` makes.
    private func measurePerTestCoverageSerial(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        let baselineBundle = resultBundlePath(in: workspace, label: "baseline")
        let tests = await Self.enumerateTestIdentifiers(inBundle: baselineBundle)
        guard !tests.isEmpty else { return nil }

        guard let coverageArtifact = try? await build(in: workspace, enableCoverage: true) else { return nil }

        // The loop, the retry policy and what becomes of a test that cannot
        // be proven are all `PerTestCoverageAttribution.attribute`'s — see
        // its doc comment. What is adapter-specific, and all that is left
        // here, is how one test is run and how its coverage is read back.
        return await PerTestCoverageAttribution.attribute(
            tests: tests, source: "xcodebuild-xccov-per-test",
            progress: ProgressReporter(total: tests.count, label: "per-test coverage")
        ) { test, attempt in
            guard let run = try? await runTests(
                artifact: coverageArtifact,
                in: workspace,
                // Distinct per attempt: a retry that reused the first
                // attempt's bundle path would be read against whatever the
                // failed attempt left behind, which is precisely the
                // half-written state being retried past.
                label: attempt == 1
                    ? "pertest-\(test.onlyTestingArgument)"
                    : "pertest-retry\(attempt)-\(test.onlyTestingArgument)",
                timeoutSeconds: timeoutSeconds,
                testFilters: [test.onlyTestingArgument],
                enableCoverage: true
            ) else { return nil }
            guard run.status == .passed, let bundle = run.resultArtifactPath else { return nil }
            return await XccovCoverageReader.read(archive: bundle, projectRoot: workspace)
        }
    }

    /// Walks `xcresulttool get test-results tests` for one bundle, pulling
    /// out every `Test Case` leaf and the `Unit test bundle` ancestor that
    /// names its target — the two things `-only-testing:` needs. A `Test
    /// Case` node's own `nodeIdentifier` is already shaped `Class/method()`
    /// (confirmed against a real bundle), so no separate class-name
    /// tracking is needed; only the trailing `()` is stripped.
    static func enumerateTestIdentifiers(inBundle bundle: URL) async -> [TestIdentifier] {
        guard FileManager.default.fileExists(atPath: bundle.path) else { return [] }

        let result = try? await ProcessSupervisor.run(
            executable: ToolPaths.xcrun,
            arguments: ["xcresulttool", "get", "test-results", "tests", "--path", bundle.path, "--compact"],
            workingDirectory: bundle.deletingLastPathComponent(),
            timeoutSeconds: 120
        )
        guard let result, result.succeeded else { return [] }
        return parseTestIdentifiers(result.standardOutput)
    }

    /// Parses `xcresulttool get test-results tests --compact` output. Exposed
    /// for tests so a captured document can drive the walk without a
    /// toolchain or a real bundle.
    ///
    /// `qualifiedName`'s own doc comment describes `"<Class>/<method>"` —
    /// true for XCTest, whose `nodeIdentifier` is exactly that shape
    /// (`"AddTests/testAdd()"`, confirmed by `XcodeTestIdentifierEnumerationTests`'
    /// own captured fixture). A Swift Testing `nodeIdentifier` is shaped
    /// differently — confirmed by direct reproduction against a real
    /// Xcode/iOS-Simulator Swift Testing target: it is
    /// `"<Target>/<method>()"` (the *target* name, never the enclosing
    /// `@Suite`'s own name, which never appears in the identifier at all)
    /// — so `qualifiedName` for a Swift Testing test ends up
    /// `"<Target>/<method>"`, not `"<Class>/<method>"`. This looks
    /// unusual next to the XCTest case, but it is exactly what makes
    /// `onlyTestingArgument` (`target + "/" + qualifiedName + "()"`)
    /// produce the one filter shape `xcodebuild -only-testing:` actually
    /// matches for a Swift Testing function — empirically, that shape is
    /// `<Target>/<Target>/<method>()` (the target name doubled), not
    /// `<Target>/<SuiteName>/<method>()` as the XCTest-shaped convention
    /// would suggest. See `TestIdentifier.onlyTestingArgument`'s own doc
    /// comment for the full account, including why this was previously
    /// silently broken (missing `()`, not this target-doubling shape).
    static func parseTestIdentifiers(_ data: Data) -> [TestIdentifier] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let testNodes = root["testNodes"] as? [[String: Any]]
        else { return [] }

        var found: [TestIdentifier] = []
        func walk(_ node: [String: Any], target: String?) {
            let nodeType = node["nodeType"] as? String
            // `xcresulttool` names a UI test target's own bundle node "UI
            // test bundle", never "Unit test bundle" — confirmed against a
            // real UI-test-only bundle (Phase 5A,
            // `Fixtures/AccessibilityUISubstrate`). Recognizing only "Unit
            // test bundle" here silently dropped every UI test's identifier
            // from enumeration (`currentTarget` stayed `nil`, so the `Test
            // Case` guard below never matched): a UI test target added to
            // `tests.targets` would enumerate as if it had zero tests,
            // starving `selectCoveringTests`'s per-test coverage
            // measurement and any schemata identifier resolution of a UI
            // test's own identifiers, even though the test genuinely ran.
            let currentTarget = isTestBundleNode(nodeType) ? (node["name"] as? String) : target

            if nodeType == "Test Case", let currentTarget,
               let identifier = node["nodeIdentifier"] as? String {
                let qualifiedName = identifier.hasSuffix("()") ? String(identifier.dropLast(2)) : identifier
                found.append(TestIdentifier(target: currentTarget, qualifiedName: qualifiedName))
            }

            for child in (node["children"] as? [[String: Any]]) ?? [] {
                walk(child, target: currentTarget)
            }
        }
        for node in testNodes { walk(node, target: nil) }
        return found
    }

    /// Whether an `xcresulttool` `nodeType` names a test-bundle-level node —
    /// the node whose own `name` is the actual test target's name. Shared
    /// with `XCResultAdapter.ownFailures`, which threads a target name down
    /// for display the identical way. Two node type strings, empirically
    /// confirmed against real result bundles: `"Unit test bundle"` for an
    /// XCTest/Swift Testing unit target, `"UI test bundle"` for an XCUITest
    /// target (see `Fixtures/AccessibilityUISubstrate`, Phase 5A).
    static func isTestBundleNode(_ nodeType: String?) -> Bool {
        nodeType == "Unit test bundle" || nodeType == "UI test bundle"
    }
}

// MARK: - Schemata batch testing

extension XcodeBuildAdapter: SchemataBatchTestable {
    /// Tests several already-embedded schemata tokens — all sharing the one
    /// `artifact` the chunk build produced — in a single `xcodebuild
    /// test-without-building` invocation, reusing `BatchXCTestRunBuilder`
    /// and the same private `runBatchTests`/`runBatchOnDestination` machinery
    /// `BatchTestable.runBatch` below already uses: both ultimately merge
    /// `TestConfigurations` into one `.xctestrun` and read results back via
    /// `XCResultAdapter.classifyBatch`, keyed by configuration name — the
    /// only difference is that every `BatchTestItem` here points at the
    /// *same* `xctestrunPath` instead of each mutant's own, with its own
    /// `environmentVariables` (token/runID/transcript path) standing in for
    /// what isolated mode's separate artifacts already give it for free.
    public func runSchemataTokenBatch(
        _ artifact: BuildArtifact, in workspace: URL, items: [SchemataBatchTokenItem], timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult] {
        guard let xctestrunPath = artifact.xctestrunPath else {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                diagnosis: "The chunk build produced no .xctestrun, so there is nothing for a token batch to run."
            )
            return Dictionary(uniqueKeysWithValues: items.map { ($0.mutationID, failure) })
        }

        var batchable: [BatchTestItem] = []
        var configurationTestIdentifiers: [String: [String]] = [:]
        var idsByConfigurationName: [String: MutationID] = [:]
        // A caller-contract violation (`SchemataBatchTestable
        // .runSchemataTokenBatch`'s own doc comment: every item must
        // already have a known, non-empty selection), not a normal runtime
        // path — reported directly rather than silently dropped or, worse,
        // fed to `BatchXCTestRunBuilder.build` with an empty
        // `onlyTestingIdentifiers`, which would drop the target entirely
        // and throw `.selectionMatchesNoTarget`, failing every *other* item
        // in the same batch for one item's bad input.
        var results: [MutationID: TestRunResult] = [:]
        for item in items {
            let configurationName = item.mutationID.rawValue
            guard let selectedTests = item.selectedTests, !selectedTests.isEmpty else {
                results[item.mutationID] = TestRunResult(
                    status: .infrastructureFailure, summary: nil, command: artifact.command, resultArtifactPath: nil,
                    diagnosis: "This token has no known test selection, so it cannot share a batch — it must run unbatched."
                )
                continue
            }
            batchable.append(BatchTestItem(
                configurationName: configurationName, xctestrunPath: xctestrunPath,
                onlyTestingIdentifiers: Array(selectedTests), environmentVariables: item.environment
            ))
            configurationTestIdentifiers[configurationName] = selectedTests.map(\.onlyTestingArgument)
            idsByConfigurationName[configurationName] = item.mutationID
        }

        func failAllBatchable(_ diagnosis: String) -> [MutationID: TestRunResult] {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil),
                resultArtifactPath: nil, diagnosis: diagnosis
            )
            for mutationID in idsByConfigurationName.values { results[mutationID] = failure }
            return results
        }

        guard !batchable.isEmpty else { return results }

        let batchData: Data
        do {
            batchData = try BatchXCTestRunBuilder.build(items: batchable)
        } catch {
            return failAllBatchable("The schemata token batch .xctestrun could not be constructed: \(error)")
        }

        let batchDirectory = workspace.appendingPathComponent(".mutantkit/SchemataBatches", isDirectory: true)
        let batchXCTestRunPath = batchDirectory.appendingPathComponent("schemata-batch-\(UUID().uuidString).xctestrun")
        do {
            try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
            try batchData.write(to: batchXCTestRunPath, options: .atomic)
        } catch {
            return failAllBatchable("The schemata token batch .xctestrun could not be written: \(error)")
        }

        let outcomes = await runBatchTests(
            xctestrunPath: batchXCTestRunPath, in: workspace, timeoutSeconds: timeoutSeconds,
            configurationTestIdentifiers: configurationTestIdentifiers,
            nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
        )

        for (configurationName, mutationID) in idsByConfigurationName {
            results[mutationID] = outcomes[configurationName] ?? TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil),
                resultArtifactPath: nil, diagnosis: "This token's outcome went unreported by the batch classifier."
            )
        }
        return results
    }
}

// MARK: - Batch testing

extension XcodeBuildAdapter: BatchTestable {
    public func runBatch(
        _ items: [BatchMutantItem],
        in workspace: URL,
        timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult] {
        var results: [MutationID: TestRunResult] = [:]
        var batchable: [BatchTestItem] = []
        // Only a narrowed selection can be told apart afterward: the batch
        // bundle's failures are attributed back to a configuration by
        // matching test identifiers, and a configuration left unnarrowed
        // (the full target list, `TestSelecting`'s safe fallback for an
        // unknown attribution) could legitimately run several tests —
        // there would be no way to tell whether a failure among them was a
        // plain assertion or a crash without a distinguishable identifier
        // to match. An item like that runs the ordinary, already-correct
        // unbatched way instead of joining the batch.
        var unbatched: [BatchMutantItem] = []
        // Keyed separately from `BatchTestItem.onlyTestingIdentifiers`
        // because the two serve different consumers of the same selection:
        // `BatchXCTestRunBuilder.build` needs each identifier's owning
        // target so it can narrow (or, when a bundle has none of its own
        // tests selected, drop) each `.xctestrun` target dict independently
        // — see its doc comment for why a target-qualified identifier must
        // never reach a bundle's own bare-`Class/method` `OnlyTestIdentifiers`
        // list. Failure attribution against `xcresulttool`'s batch-wide
        // `testFailures` instead needs the fully target-qualified
        // `TestIdentifier.onlyTestingArgument`, since that is the shape
        // `TestSummaryJSON.Failure.identifier` itself uses.
        var configurationTestIdentifiers: [String: [String]] = [:]

        for item in items {
            if let selectedTests = item.selectedTests, !selectedTests.isEmpty,
               let xctestrunPath = item.artifact.xctestrunPath {
                batchable.append(BatchTestItem(
                    configurationName: item.id.rawValue,
                    xctestrunPath: xctestrunPath,
                    onlyTestingIdentifiers: Array(selectedTests)
                ))
                configurationTestIdentifiers[item.id.rawValue] = selectedTests.map(\.onlyTestingArgument)
            } else {
                unbatched.append(item)
            }
        }

        await withTaskGroup(of: (MutationID, TestRunResult).self) { group in
            for item in unbatched {
                group.addTask {
                    let result = try? await self.runTests(
                        artifact: item.artifact, in: workspace, label: item.id.rawValue,
                        timeoutSeconds: timeoutSeconds
                    )
                    return (item.id, result ?? TestRunResult(
                        status: .infrastructureFailure, summary: nil, command: item.artifact.command,
                        resultArtifactPath: nil, diagnosis: "The mutant's tests could not be run."
                    ))
                }
            }
            for await (id, result) in group {
                results[id] = result
            }
        }

        guard !batchable.isEmpty else { return results }

        let idsByConfigurationName = Dictionary(
            uniqueKeysWithValues: items.compactMap { item -> (String, MutationID)? in
                batchable.contains { $0.configurationName == item.id.rawValue } ? (item.id.rawValue, item.id) : nil
            }
        )

        func failAllBatchable(_ diagnosis: String) {
            for item in batchable {
                guard let id = idsByConfigurationName[item.configurationName] else { continue }
                results[id] = TestRunResult(
                    status: .infrastructureFailure, summary: nil,
                    command: CommandRecording.record(
                        executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil
                    ),
                    resultArtifactPath: nil, diagnosis: diagnosis
                )
            }
        }

        let batchData: Data
        do {
            batchData = try BatchXCTestRunBuilder.build(items: batchable)
        } catch {
            failAllBatchable("The batch .xctestrun could not be constructed: \(error)")
            return results
        }

        let batchDirectory = workspace.appendingPathComponent(".mutantkit/Batches", isDirectory: true)
        let batchXCTestRunPath = batchDirectory.appendingPathComponent("batch-\(UUID().uuidString).xctestrun")
        do {
            try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
            try batchData.write(to: batchXCTestRunPath, options: .atomic)
        } catch {
            failAllBatchable("The batch .xctestrun could not be written: \(error)")
            return results
        }

        let outcomes = await runBatchTests(
            xctestrunPath: batchXCTestRunPath,
            in: workspace,
            timeoutSeconds: timeoutSeconds,
            configurationTestIdentifiers: configurationTestIdentifiers,
            nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
        )

        for item in batchable {
            guard let id = idsByConfigurationName[item.configurationName] else { continue }
            // Fail-closed even here: `outcomes` is keyed by every name this
            // call was asked about (see `XCResultAdapter.classifyBatch`), so
            // a missing entry only happens if that contract was violated —
            // still handled rather than trusted blindly.
            results[id] = outcomes[item.configurationName] ?? TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "This configuration's outcome went unreported by the batch classifier."
            )
        }

        return results
    }

    /// Leases a device (when the destination needs one) and runs the batch
    /// `.xctestrun`, the same shape `runTests`/`leaseAndRunTests` use for a
    /// single mutant.
    private func runBatchTests(
        xctestrunPath: URL,
        in workspace: URL,
        timeoutSeconds: Double,
        configurationTestIdentifiers: [String: [String]],
        nativeTimeoutAllowanceSeconds: Double? = nil
    ) async -> [String: TestRunResult] {
        @Sendable func run(destination: String) async -> [String: TestRunResult] {
            await runBatchOnDestination(
                destination, xctestrunPath: xctestrunPath, in: workspace,
                timeoutSeconds: timeoutSeconds, configurationTestIdentifiers: configurationTestIdentifiers,
                nativeTimeoutAllowanceSeconds: nativeTimeoutAllowanceSeconds
            )
        }

        guard destinationNeedsSimulatorLease else {
            return await run(destination: destination())
        }

        do {
            // `preferredDevice: nil` — the batch path never honors
            // `workerDevicesByWorkspace` (plan §5.1); see
            // `SimulatorLeaseCoordinator`'s own doc comment.
            return try await leaseCoordinator.withLease(preferredDevice: nil, rawDestination: destination()) { lease in
                await run(destination: lease.destination)
            }
        } catch let error as SimulatorPoolError {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "No simulator could be leased for this batch: \(error.description)"
            )
            return Dictionary(uniqueKeysWithValues: configurationTestIdentifiers.keys.map { ($0, failure) })
        } catch {
            let failure = TestRunResult(
                status: .infrastructureFailure, summary: nil,
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild, arguments: [], workingDirectory: workspace, result: nil
                ),
                resultArtifactPath: nil,
                diagnosis: "The batch could not be leased or run: \(error)"
            )
            return Dictionary(uniqueKeysWithValues: configurationTestIdentifiers.keys.map { ($0, failure) })
        }
    }

    /// Builds the batch invocation's own arguments (including the
    /// native-timeout-allowance injection, specific to this one call path —
    /// see `XCTestInvocationService`'s own doc comment for why there is no
    /// shared pure static for it, unlike `testWithoutBuildingArguments`) and
    /// delegates launch/timeout/classification to `invocationService` (v2
    /// Step 4 §7 Step 4). Deliberately does not remove any existing item at
    /// `resultBundle` first — unchanged from before this step: the path is
    /// already a fresh per-call UUID, so there is nothing stale at it to
    /// remove.
    private func runBatchOnDestination(
        _ destination: String,
        xctestrunPath: URL,
        in workspace: URL,
        timeoutSeconds: Double,
        configurationTestIdentifiers: [String: [String]],
        nativeTimeoutAllowanceSeconds: Double? = nil
    ) async -> [String: TestRunResult] {
        let resultBundle = workspace
            .appendingPathComponent(".mutantkit/Results", isDirectory: true)
            .appendingPathComponent("batch-\(UUID().uuidString).xcresult")
        try? FileManager.default.createDirectory(
            at: resultBundle.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        var arguments = [
            "test-without-building",
            "-xctestrun", xctestrunPath.path,
            "-destination", destination,
            "-resultBundlePath", resultBundle.path,
            "-collect-test-diagnostics", "never"
        ]
        // Containment, layered underneath `timeoutSeconds` (the outer,
        // aggregate fail-safe below, unchanged): confirmed empirically that
        // XCTest's own per-test allowance cuts a single hanging
        // configuration off — reported `.timedOut` by
        // `XCResultAdapter.classifyBatch`'s native-timeout branch — without
        // killing this `xcodebuild` invocation or losing its siblings'
        // results, so a batch no longer has to burn its *entire* combined
        // outer budget on one hang before anything is known. `nil` (every
        // caller except isolated wave batching's own multi-member batches,
        // for now) leaves `xcodebuild`'s own default (timeouts disabled)
        // untouched.
        //
        // An earlier version of this code layered a second,
        // `ProcessSupervisor`-level containment mechanism underneath this
        // one — an external, file-growth-based stall watchdog on
        // `-resultStreamPath` — for the case native per-test timeout does
        // not reliably catch (a CPU-bound, non-cooperative hang). Direct
        // content inspection of that stream on a real, long-running hang
        // batch found the hypothesis behind it was wrong: the periodic
        // writes it depended on distinguishing from "stall" turned out to
        // be genuine `testStarted`/timeout events for *additional* tests in
        // the same mutant's own covering-test list, not noise — so no
        // finite margin could ever have made file-growth a reliable "this
        // configuration is truly stuck" signal. Retired for that reason.
        // The real fix for the underlying problem (one mutant's own
        // multiple covering tests each independently hanging) turned out to
        // be a wave-based early-abort for isolated mode and a
        // single-test-only batching eligibility rule for schemata — neither
        // of which touches this function or `ProcessSupervisor`.
        if let nativeTimeoutAllowanceSeconds {
            let allowance = String(format: "%.0f", nativeTimeoutAllowanceSeconds)
            arguments.append(contentsOf: [
                "-test-timeouts-enabled", "YES",
                "-default-test-execution-time-allowance", allowance,
                "-maximum-test-execution-time-allowance", allowance
            ])
        }
        arguments.append(contentsOf: configuration.tests.extraArguments)

        return await invocationService.runBatch(
            arguments: arguments,
            resultBundle: resultBundle,
            timeoutSeconds: timeoutSeconds,
            configurationTestIdentifiers: configurationTestIdentifiers,
            in: workspace
        )
    }
}

// MARK: - Project adapter

/// Pairs the xcodebuild build and test halves for one project kind.
public struct XcodeBuildProjectAdapter: ProjectAdapter {
    public let kind: ProjectKind
    public let build: any BuildAdapter
    public let test: any TestAdapter
    /// The destination resolved once at construction — see
    /// `DestinationResolver`. Surfaced so a caller building a `RunManifest`
    /// can record exactly which device this run is bound to, without
    /// needing to downcast `build`/`test` back to `XcodeBuildAdapter`.
    public let resolvedDestination: ResolvedDestination?
    /// Kept so `prepareSimulatorForRun()` can reach the pool the
    /// underlying adapter owns, without exposing that pool or downcasting
    /// `build`/`test` back to `XcodeBuildAdapter` from the CLI.
    private let simulatorBearingAdapter: XcodeBuildAdapter?
    /// Six `ProjectAdapter` capability properties, populated below from the
    /// same `XcodeBuildAdapter` instance `build`/`test` already share —
    /// zero `as?`, a compile-time-checked upcast, since `adapter`'s
    /// concrete type and every protocol it conforms to are both statically
    /// known right here. See `ProjectAdapter`'s own doc comment and this
    /// project's internal execution-engine restructuring notes (not part
    /// of this public repo) for the full rationale.
    public let schemataBuild: (any SchemataBuildable)?
    public let schemataTest: (any SchemataTestable)?
    public let coverageMeasuring: (any CoverageMeasuring)?
    public let testSelecting: (any TestSelecting)?
    public let batchTestable: (any BatchTestable)?
    public let schemataBatchTestable: (any SchemataBatchTestable)?

    public init(
        configuration: Configuration,
        kind: ProjectKind,
        projectFile: URL?,
        projectRoot: URL,
        resolvedDestination: ResolvedDestination? = nil,
        workerDevicesByWorkspace: [String: SimulatorDevice]? = nil
    ) {
        self.kind = kind
        self.resolvedDestination = resolvedDestination
        let adapter = XcodeBuildAdapter(
            configuration: configuration,
            kind: kind,
            projectFile: projectFile,
            projectRoot: projectRoot,
            resolvedDestination: resolvedDestination,
            workerDevicesByWorkspace: workerDevicesByWorkspace
        )
        simulatorBearingAdapter = adapter
        build = adapter
        test = adapter
        schemataBuild = adapter
        schemataTest = adapter
        coverageMeasuring = adapter
        testSelecting = adapter
        batchTestable = adapter
        schemataBatchTestable = adapter
    }

    /// Boots and verifies readiness of the device this run will test on,
    /// if it has one. See `XcodeBuildAdapter.prepareSimulatorForRun`.
    public func prepareSimulatorForRun() async -> SimulatorPreparationRecord {
        if let simulatorBearingAdapter {
            return await simulatorBearingAdapter.prepareSimulatorForRun()
        }
        return SimulatorPreparationRecord(outcome: .notApplicable)
    }
}
