import Foundation
import MutationModel
import SwiftFrontend

// MARK: - Build

/// A built, testable product.
///
/// `productHash` is load-bearing: comparing a mutant's product against the
/// baseline's is what proves the mutation actually reached the binary. A build
/// adapter that cannot produce this hash cannot produce activation evidence, and
/// its mutants cannot be scored.
public struct BuildArtifact: Sendable {
    /// Root of the built products (a `.build` directory, or DerivedData's `Build/Products`).
    public let productsDirectory: URL
    /// Content hash over the test binaries. `nil` only when the adapter cannot
    /// identify them — which the integrity check will then treat as unproven.
    public let productHash: String?
    /// `.xctestrun` path for `xcodebuild test-without-building`. Located, never guessed.
    public let xctestrunPath: URL?
    public let command: CommandRecord

    public init(
        productsDirectory: URL,
        productHash: String?,
        xctestrunPath: URL?,
        command: CommandRecord
    ) {
        self.productsDirectory = productsDirectory
        self.productHash = productHash
        self.xctestrunPath = xctestrunPath
        self.command = command
    }
}

/// One `doctor` check.
public struct DiagnosisItem: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        case warning
        case failure
    }

    /// A stable, documented identifier for *what was checked* — independent
    /// of `status`/`detail`, which describe the outcome and vary run to run.
    /// Follows `QualityGateViolation.Kind`'s own convention (a `String` enum
    /// alongside a free-text `detail`) so `doctor --json` gives an agent the
    /// same thing `gate --json` already does: something to `switch` on
    /// instead of parsing prose. Two different checks that happen to render
    /// under the same display `name` (e.g. `ReadinessCheck`'s "Project" vs.
    /// `Diagnostics.projectKind`'s "Project kind", which `ReadinessCheck
    /// .deduplicated` collapses to one line) intentionally share a `code`
    /// too — the code names the fact being reported, not the source line
    /// that reported it.
    public enum Code: String, Codable, Sendable {
        case configurationInvalid
        case mutantkitVersion
        case swiftToolchain
        case xcodeToolchain
        case projectDetected
        case projectResolutionFailed
        case declaredPlatforms
        case productionProfileRecommended
        case scheme
        case destination
        case derivedData
        case trialBuild
        case trialBuildSkipped
        case xctestrunArtifact
        case testTargets
        case productHash
        case diskSpace
        case availableMemory
        case systemLoad
        case bootedSimulators
    }

    public let name: String
    public let status: Status
    public let code: Code
    public let detail: String
    /// What the user should do about it. Populated for anything not `ok`.
    public let remedy: String?

    public init(name: String, status: Status, code: Code, detail: String, remedy: String? = nil) {
        self.name = name
        self.status = status
        self.code = code
        self.detail = detail
        self.remedy = remedy
    }
}

/// `doctor`'s fully-computed verdict — every check already run, `canProceed`
/// already decided — mirroring `QualityGateResult`'s own shape (`gate`'s
/// analogous decision-before-render result): a stored `schemaVersion` set
/// internally, never a caller-supplied init param, and `canProceed` stored
/// rather than left purely computed so `mutantkit doctor --json` exposes the
/// same verdict `DoctorCommand` itself branches its exit code on, the same
/// way `QualityGateResult.passed` does for `gate --json`.
public struct BuildDiagnosis: Codable, Sendable {
    public let schemaVersion: Int
    public let items: [DiagnosisItem]
    public let canProceed: Bool

    public init(items: [DiagnosisItem]) {
        schemaVersion = SchemaVersion.buildDiagnosis
        self.items = items
        canProceed = !items.contains { $0.status == .failure }
    }
}

/// Builds baselines and mutants.
///
/// Split from `TestAdapter` because the useful combinations differ per project
/// kind, and because forcing one type to do both is how a Swift package for iOS
/// ends up being built with `swift test` and failing to find UIKit.
public protocol BuildAdapter: Sendable {
    /// Checks the environment before any config is written. Backs `doctor`.
    func diagnose() async throws -> BuildDiagnosis
    func buildBaseline(in workspace: URL) async throws -> BuildArtifact
    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact
}

/// A build adapter that can build a schemata chunk — every mutation in
/// `loweredSources` embedded into one shared build, rather than one
/// mutation rebuilt from scratch per mutant.
///
/// Conformance is optional, mirroring `CoverageMeasuring`/`BatchTestable`:
/// only an adapter whose project kind schemata mode actually supports
/// conforms, and `RunCommand` fails closed with a clear message when
/// `.schemata` execution is requested against one that does not, rather
/// than silently falling back to isolated mode.
public protocol SchemataBuildable: BuildAdapter {
    /// Writes every file in `loweredSources` into `workspace` (overwriting
    /// whatever plain, unmutated copy the sandbox already has at that
    /// relative path) and builds once, linked against
    /// `MutantKitSchemataRuntime` — see `SwiftPMLinkerInjector`. The
    /// resulting `BuildArtifact` is expected to serve every embedded
    /// mutation in the chunk, run one token at a time via
    /// `SchemataTestable.runSchemataToken`, not rebuilt per mutant.
    func buildSchemataChunk(loweredSources: [SchemataSourceFile], in workspace: URL) async throws -> BuildArtifact

    /// Builds the real, per-compilation-unit build receipt for everything
    /// `buildSchemataChunk` just produced — the build-time half of
    /// ADR-0006's proof chain (Finding 2/4). Every `unit` in `units` names
    /// its own real `BuildTargetIdentity` (the chunk planner's own
    /// project/target/module identity, never a name this method has to
    /// guess at); this method's job is only to prove which real built
    /// image that target's code actually ended up in, and extract that
    /// image's real `LC_UUID` — never to invent or assume the mapping.
    ///
    /// Fails closed (throws) for any unit whose target cannot be resolved
    /// to a provably unique built image — an ambiguous or absent mapping
    /// must never silently fall back to a placeholder identity.
    func resolveSchemataBuildReceipt(
        for units: [SchemataCompilationUnitTargetRequest],
        artifact: BuildArtifact,
        in workspace: URL,
        context: SchemataBuildReceiptContext
    ) async throws -> SchemataBuildReceipt
}

/// The identity fields `resolveSchemataBuildReceipt` stamps onto the
/// `SchemataBuildReceipt` it produces — bundled so the method itself stays
/// within SwiftLint's parameter-count threshold, the same discipline
/// `SchemataMutationRunner.EmbeddingContext` already uses.
public struct SchemataBuildReceiptContext: Sendable {
    public let planID: String
    public let workUnitID: String
    public let chunkID: String
    public let toolchainHash: SHA256Digest
    public let buildArgumentsHash: SHA256Digest

    public init(planID: String, workUnitID: String, chunkID: String, toolchainHash: SHA256Digest, buildArgumentsHash: SHA256Digest) {
        self.planID = planID
        self.workUnitID = workUnitID
        self.chunkID = chunkID
        self.toolchainHash = toolchainHash
        self.buildArgumentsHash = buildArgumentsHash
    }
}

/// One compilation unit's own real target identity, as already known by
/// the chunk planner that assigned it — never a display name a resolver
/// would otherwise have to guess at from a built artifact's filename.
public struct SchemataCompilationUnitTargetRequest: Sendable {
    public let compilationUnitID: CompilationUnitID
    public let sourceEmbeddingID: SHA256Digest
    public let buildTarget: BuildTargetIdentity

    public init(compilationUnitID: CompilationUnitID, sourceEmbeddingID: SHA256Digest, buildTarget: BuildTargetIdentity) {
        self.compilationUnitID = compilationUnitID
        self.sourceEmbeddingID = sourceEmbeddingID
        self.buildTarget = buildTarget
    }
}

// MARK: - Test

//
// TestRunStatus/TestRunResult/BuildFailureKind/BuildFailure moved to
// MutationModel/TestObservation.swift (ADR-0006 Stage 1) — the verifier
// needs to inspect them directly and cannot depend on this module.

public protocol TestAdapter: Sendable {
    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws
        -> TestRunResult

    func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async throws -> TestRunResult
}

/// A test adapter that can run an already-built schemata chunk once per
/// requested selector token, without rebuilding.
///
/// `environment` carries the schemata protocol's own env vars
/// (`SchemataEvidenceCollector.tokenEnvironmentVariable` and friends) —
/// the caller is responsible for choosing a fresh `runNonce` per call and
/// collecting evidence afterward via `SchemataEvidenceCollector`; this
/// method's only job is to run the already-built product with those
/// variables set and report the test outcome, exactly like `runMutant`
/// does for isolated mode, just without a build in between calls.
public protocol SchemataTestable: TestAdapter {
    /// - Parameter selectedTests: the same convention `TestSelecting
    ///   .runMutant` establishes: `nil` and an empty set both mean "no
    ///   narrowing, run the full configured test list" — an adapter must
    ///   never turn an empty selection into a filter that runs nothing.
    ///   Populated by the caller from a `PerTestCoverageMap` lookup when
    ///   `execution.selectCoveringTests` is enabled and the adapter also
    ///   conforms to `TestSelecting`; `nil` otherwise, which reproduces the
    ///   exact unrestricted behaviour schemata mode always had before this
    ///   parameter existed.
    func runSchemataToken(
        _ artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        environment: [String: String],
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult
}

/// One already-built schemata token's slot in a batched test run — the
/// schemata counterpart to `BatchMutantItem`. No `artifact` field: unlike
/// isolated mode, every token in a schemata chunk shares the *same* build
/// (the chunk's own), so the batch as a whole carries one artifact, not
/// one per item.
public struct SchemataBatchTokenItem: Sendable {
    public let mutationID: MutationID
    /// This token's own `EnvironmentVariables` (token/runID/transcript
    /// path — `SchemataEvidenceCollector`'s own env vars), merged into its
    /// `TestConfigurations` entry so each configuration in the shared
    /// batch activates and reports evidence for a different mutation
    /// despite all sharing one binary.
    public let environment: [String: String]
    /// Same meaning and same fallback as `SchemataTestable.runSchemataToken`'s:
    /// `nil` or empty runs the full configured test list. Unlike isolated's
    /// `BatchMutantItem`, an item with `nil`/empty `selectedTests` is never
    /// handed to `runSchemataTokenBatch` at all — see that method's own doc
    /// comment for why an unnarrowed configuration cannot share a batch.
    public let selectedTests: Set<TestIdentifier>?

    public init(mutationID: MutationID, environment: [String: String], selectedTests: Set<TestIdentifier>?) {
        self.mutationID = mutationID
        self.environment = environment
        self.selectedTests = selectedTests
    }
}

/// An adapter that can test several already-built schemata tokens — all
/// sharing one chunk build — in a single process instead of one process
/// per token. The schemata counterpart to `BatchTestable`; see that
/// protocol's own doc comment for what "batched" empirically costs and
/// recovers from (confirmed there for isolated mode's own per-mutant
/// artifacts; schemata batching reuses the identical `.xctestrun`
/// `TestConfigurations` mechanism, just against one shared artifact
/// instead of several separate ones).
///
/// Conformance is optional, the same shape as `BatchTestable`: an adapter
/// that does not conform simply never gets asked, and every token runs the
/// unbatched way via `SchemataTestable.runSchemataToken`.
public protocol SchemataBatchTestable: SchemataTestable {
    /// Tests every item in one process, against the one already-built
    /// chunk `artifact`. Returns exactly one result per item's
    /// `mutationID` — a batch-level failure reports that item
    /// `.infrastructureFailure` rather than omitting it, the same
    /// never-drop-a-handed-in-item contract `BatchTestable.runBatch`
    /// makes. Every item's `selectedTests` must be non-`nil` and
    /// non-empty (the caller's responsibility, not this method's to
    /// enforce) — an unnarrowed configuration cannot be told apart from
    /// its batch-mates afterward, the identical reason `runBatch` never
    /// batches an unnarrowed `BatchMutantItem` either.
    ///
    /// - Parameter nativeTimeoutAllowanceSeconds: same meaning as
    ///   `BatchTestable.runBatch`'s parameter of the same name (Gate 3
    ///   Phase H3) — when non-`nil`, enables XCTest's own per-test
    ///   execution-time allowance for every configuration in the batch, so
    ///   one hanging token cannot hold the whole batch's outer,
    ///   aggregate `timeoutSeconds` hostage. `nil` (the default, via the
    ///   protocol-extension overload below) is a complete no-op.
    func runSchemataTokenBatch(
        _ artifact: BuildArtifact,
        in workspace: URL,
        items: [SchemataBatchTokenItem],
        timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult]
}

public extension SchemataBatchTestable {
    func runSchemataTokenBatch(
        _ artifact: BuildArtifact,
        in workspace: URL,
        items: [SchemataBatchTokenItem],
        timeoutSeconds: Double
    ) async -> [MutationID: TestRunResult] {
        await runSchemataTokenBatch(
            artifact, in: workspace, items: items, timeoutSeconds: timeoutSeconds, nativeTimeoutAllowanceSeconds: nil
        )
    }
}

/// An adapter that can measure line coverage on the baseline run.
///
/// Conformance is optional: an adapter that cannot produce a coverage map (a
/// host without `llvm-cov`, an xcodebuild setup whose result bundle cannot be
/// parsed) simply does not conform, and the runner treats the run as
/// coverage-blind — every mutant is built and tested. That is the safe
/// fallback: a missing map never turns into a `noCoverage` verdict, because a
/// `noCoverage` claim the data cannot back is the exact laundering this tool
/// exists to prevent.
public protocol CoverageMeasuring: TestAdapter {
    /// Reads the coverage map produced by the most recent `runBaseline` in
    /// `workspace`, normalised against `projectRoot`.
    ///
    /// Called once per execution, after the baseline has passed. `nil` means
    /// "no coverage information", which the runner treats as if the protocol
    /// were not conformed to at all: no mutant is classified `.noCoverage` on
    /// the basis of missing data.
    func readCoverage(in workspace: URL, projectRoot: URL) async -> CoverageMap?
}

/// An adapter that can attribute baseline coverage to individual tests, and
/// run a mutant against only the tests that cover it.
///
/// Conformance is optional, the same shape as `CoverageMeasuring`: an
/// adapter that cannot (or was not asked to) produce this attribution simply
/// does not conform, and every mutant runs the full configured test list —
/// the safe, unrestricted default. `runMutant(...selectedTests:)` mirrors
/// that same fallback at the call level: `nil` means "no narrowing", and a
/// caller with an attribution that turned out empty must pass `nil` rather
/// than an empty set, because an empty `-only-testing:` selection runs
/// nothing and a run that tests nothing must never be mistaken for one that
/// passed.
public protocol TestSelecting: TestAdapter {
    /// Runs every test individually against `artifact` — already built for
    /// the baseline, not rebuilt — with coverage enabled, and returns the
    /// resulting per-test attribution.
    ///
    /// Called once per execution, after the baseline has passed, from
    /// inside the same sandbox `runBaseline` used. `nil` means no
    /// attribution could be produced (as `CoverageMeasuring.readCoverage`
    /// does), which the runner treats as if this protocol were not
    /// conformed to at all.
    func measurePerTestCoverage(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap?

    /// `TestAdapter.runMutant`, parameterised by which tests to run.
    /// `selectedTests == nil` must behave identically to the unparameterised
    /// `runMutant` — every configured test target, unrestricted.
    func runMutant(
        _ point: MutationPoint,
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult
}

/// One already-built mutant's slot in a batched test run.
///
/// The build already happened — `artifact` is whatever `BuildAdapter`
/// produced, exactly as it would be for an unbatched `runMutant` — this
/// only asks for it to be *tested* together with others in one process
/// instead of alone in its own.
public struct BatchMutantItem: Sendable {
    public let id: MutationID
    public let artifact: BuildArtifact
    /// Same meaning and same fallback as `TestSelecting`'s: `nil` or empty
    /// runs the full configured test list, never nothing.
    public let selectedTests: Set<TestIdentifier>?

    public init(id: MutationID, artifact: BuildArtifact, selectedTests: Set<TestIdentifier>?) {
        self.id = id
        self.artifact = artifact
        self.selectedTests = selectedTests
    }
}

/// An adapter that can test several already-built mutants in a single
/// process instead of one process per mutant.
///
/// Conformance is optional, the same shape as `CoverageMeasuring` and
/// `TestSelecting`: an adapter that does not conform simply never gets
/// asked, and every mutant is tested the unbatched way. Confirmed on a real
/// project that `xcodebuild test-without-building` accepts an `.xctestrun`
/// naming several `TestConfigurations` and pays its fixed per-invocation
/// cost (device install/launch, tens of seconds) once for the whole batch
/// rather than once per mutant — and that it recovers on its own from a
/// configuration whose test process crashes, continuing to the rest of the
/// batch rather than losing it.
public protocol BatchTestable: TestAdapter {
    /// Tests every item in one process. Returns exactly one result per
    /// item's `id` — a batch-level failure (the process itself could not
    /// run, or a specific configuration's result went missing from the
    /// bundle even though others in the same batch succeeded) reports that
    /// item `.infrastructureFailure` rather than omitting it: every mutant
    /// handed in must come back out, proven or not.
    ///
    /// - Parameter nativeTimeoutAllowanceSeconds: When non-`nil`, enables
    ///   XCTest's own per-test execution-time allowance
    ///   (`-test-timeouts-enabled`) at this value for every configuration in
    ///   the batch — confirmed (Gate 3 Phase H1/H2) to cut a single hanging
    ///   configuration off without killing the shared `xcodebuild`
    ///   invocation or losing its siblings' results. This is *containment*,
    ///   layered underneath — never a replacement for — `timeoutSeconds`,
    ///   which remains the outer, aggregate fail-safe for the whole
    ///   invocation exactly as before. `nil` (the default) is a complete
    ///   no-op: every caller that does not pass it gets today's behavior
    ///   unchanged.
    func runBatch(
        _ items: [BatchMutantItem],
        in workspace: URL,
        timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult]
}

public extension BatchTestable {
    func runBatch(
        _ items: [BatchMutantItem],
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> [MutationID: TestRunResult] {
        await runBatch(items, in: workspace, timeoutSeconds: timeoutSeconds, nativeTimeoutAllowanceSeconds: nil)
    }
}

/// A build+test pair for one project kind, chosen by detection or configuration.
public protocol ProjectAdapter: Sendable {
    var kind: ProjectKind { get }
    var build: any BuildAdapter { get }
    var test: any TestAdapter { get }

    /// Boots and verifies readiness of whatever simulator this run's tests
    /// will execute on, if any. Called once at run start; a no-op
    /// `.notApplicable` for adapters whose destination is not a simulator.
    /// The returned record records whether the device was warm, cold, or
    /// failed readiness, so a run can log it, persist it to the
    /// `RunManifest`, and fail closed on a device that did not verify.
    func prepareSimulatorForRun() async -> SimulatorPreparationRecord
}

public extension ProjectAdapter {
    func prepareSimulatorForRun() async -> SimulatorPreparationRecord {
        SimulatorPreparationRecord(outcome: .notApplicable)
    }
}
