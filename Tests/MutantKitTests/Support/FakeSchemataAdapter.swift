import Foundation
import MutationExecution
import MutationModel
import SwiftFrontend
import Testing

// MARK: - Fake SchemataBuildable/SchemataTestable

/// Writes real v3 binary transcript records (`mutantkit_protocol_v3.c`'s
/// wire format) rather than short-circuiting `MutationVerdictVerifier
/// .verifySchemataChain` — the same discipline `SchemataEvidenceCollectorTests`
/// uses to pin the parser itself, applied here so runner-level routing is
/// proven against genuine bytes, never a shortcut that assumes what the
/// runner will decide.
///
/// Shared across every `SchemataMutationRunner` test suite (Group 2 dynamic
/// fallback, ADR-0008 containment/hang-budget/recovery-rebuild) rather than
/// duplicated per file, since the wire-format encoding and env-var protocol
/// it implements are identical everywhere it's used.
/// `@unchecked Sendable`, made actually thread-safe rather than merely
/// asserted so (ADR-0008 chunk-concurrency validation): `SchemataMutationRunner
/// .run()` now fans independent chunks out over a bounded `TaskGroup`, and
/// every chunk in flight shares this *one* adapter instance — a concurrency
/// test running with `workers: 2`+ genuinely calls `buildSchemataChunk`/
/// `runSchemataToken`/etc. from more than one `Task` at once, on the same
/// object. Every stored `var` this class mutates after construction is
/// guarded by `lock`; the ones only ever *written* during test setup, before
/// `run()` is ever called (`scripts`, `buildFailureScript`,
/// `delayNanosecondsBeforeRun`, `perTestCoverageToReturn`), are safe to read
/// unlocked during concurrent execution because nothing ever mutates them
/// again once a test starts running the adapter.
final class FakeSchemataAdapter: BuildAdapter, SchemataBuildable, TestAdapter, SchemataTestable, TestSelecting, SchemataBatchTestable,
    @unchecked Sendable {
    /// One token can be scripted with more than one behavior (ADR-0008):
    /// index 0 is the primary run, index 1 the first confirmation (the same
    /// selector token is reused for both in the real protocol). The last
    /// entry repeats once exhausted, so a single-behavior script — the
    /// common case, Group 2's own tests — needs no change.
    enum Behavior {
        case passed(includeHit: Bool)
        case timedOut
        case crashed
    }

    struct Script {
        let compilationUnitID: CompilationUnitID
        let sourceEmbeddingID: SHA256Digest
        let behaviors: [Behavior]

        init(compilationUnitID: CompilationUnitID, sourceEmbeddingID: SHA256Digest, includeHit: Bool) {
            self.init(
                compilationUnitID: compilationUnitID, sourceEmbeddingID: sourceEmbeddingID, behaviors: [.passed(includeHit: includeHit)]
            )
        }

        init(compilationUnitID: CompilationUnitID, sourceEmbeddingID: SHA256Digest, behaviors: [Behavior]) {
            self.compilationUnitID = compilationUnitID
            self.sourceEmbeddingID = sourceEmbeddingID
            self.behaviors = behaviors
        }
    }

    private static let processID: Int32 = 4242

    var scripts: [SchemataSelectorToken: Script] = [:]
    /// A synchronous side effect run once, at the start of a token's *next*
    /// `runSchemataToken` call, then discarded — lets a test corrupt
    /// something in the real (non-faked) `WorkspaceManager`'s state (e.g.
    /// delete `projectRoot`) exactly between a primary run and the
    /// containment rebuild it triggers, to exercise a rebuild-time failure
    /// path no build-failure-shaped injection can reach (ADR-0008 §4(d)'s
    /// sandbox-recreation-failure sub-case).
    /// Guards every field below that is mutated *during* concurrent
    /// execution (as opposed to only during single-threaded test setup) —
    /// see the type's own doc comment for the write-before-run-only fields
    /// that don't need this.
    private let lock = NSLock()
    var beforeNextRun: [SchemataSelectorToken: () -> Void] = [:]
    /// Gate 3 Phase H15C: tokens whose *next* `runSchemataToken` dispatch
    /// should throw instead of producing a scripted result — simulates a
    /// launch failure on the individual retry path
    /// (`recoverAmbiguousBatchedPrimary`'s own `catch`), proving a second
    /// failure there is final (no recursive retry), without needing an
    /// `.infrastructureFailure`-producing `Behavior` case (which nothing
    /// about a real *individual* dispatch — as opposed to a batch's own
    /// attribution gap — can naturally produce).
    var throwOnNextRun: Set<SchemataSelectorToken> = []
    /// How many times each token has actually been dispatched (primary +
    /// every confirmation) — selects which `Script.behaviors` entry the next
    /// call gets.
    private var callCounts: [SchemataSelectorToken: Int] = [:]
    /// Every `RunID` actually dispatched for a given token, in order —
    /// direct evidence (Gate 3 Phase H5) that a confirmation gets a fresh
    /// `RunID` of its own rather than reusing its primary's, whether that
    /// primary was dispatched individually or as part of a batch.
    private(set) var runIDsSeenByToken: [SchemataSelectorToken: [RunID]] = [:]
    /// An artificial `Task.sleep` a test can script before a specific
    /// token's `runSchemataToken` call actually runs its scripted behavior —
    /// the deterministic knob concurrency tests need to force a controlled
    /// interleaving between two chunks running under a real `TaskGroup`
    /// (e.g. "chunk B's hang-triggering entry must still be mid-flight when
    /// chunk A finishes its own unrelated entry"), rather than relying on
    /// real wall-clock racing between fake, effectively-instant adapter
    /// calls. Nanoseconds, passed straight to `Task.sleep(nanoseconds:)`.
    var delayNanosecondsBeforeRun: [SchemataSelectorToken: UInt64] = [:]

    /// How many times `buildSchemataChunk` has been called for this
    /// adapter's whole lifetime — ADR-0008's direct evidence that a
    /// mid-chunk rebuild actually happened (a superset of confirmed-hang
    /// count, matching ADR Addendum 3: one rebuild per forced timeout-kill,
    /// not per `.verifiedTimeout`). Only ever read externally *after*
    /// `run()` has fully returned (the established assertion pattern in
    /// every existing test), so — unlike the write inside
    /// `buildSchemataChunk` itself — this external read needs no lock: by
    /// the time a test reads it, every concurrent chunk task has already
    /// completed.
    private(set) var buildCallCount = 0

    /// Every `timeoutSeconds` this adapter was actually handed, split by
    /// which kind of run asked for it — the direct evidence that schemata
    /// mode bounds a per-mutant token run by the *mutant* limit and the
    /// baseline by the *baseline* limit, rather than passing one number to
    /// both (the defect measured on the 2026-08 `swift-async-algorithms`
    /// run: every token run got the 600 s baseline budget).
    private(set) var baselineTimeoutSeconds: [Double] = []
    private(set) var tokenTimeoutSeconds: [Double] = []

    /// Injected failures for `buildSchemataChunk`/`resolveSchemataBuildReceipt`
    /// on a specific 1-based build-call index (ADR-0008 §4(d)) — unused
    /// until a Phase 6 test populates it; every earlier phase's tests leave
    /// this empty and get the unconditional success path below.
    var buildFailureScript: [Int: BuildFailureInjection] = [:]

    enum BuildFailureInjection {
        case throwBuildFailure(kind: BuildFailureKind, diagnosis: String)
        case throwUntypedError
        case nilProductHash
        case throwOnReceiptResolution
    }

    private struct UntypedFakeError: Error {}

    private static func imageUUID(forBuildCall callIndex: Int) -> ImageUUID {
        ImageUUID(rawValue: String(format: "%032x", callIndex))!
    }

    /// Recovers *this* build's own call index from the `productHash`
    /// `buildSchemataChunk` embedded in the `BuildArtifact` it returned
    /// (`"fake-hash-N"`) — the concurrency-safe replacement for reading a
    /// single shared "latest build" var: `resolveSchemataBuildReceipt` and
    /// `runSchemataToken` both already receive their own `artifact`
    /// parameter, so deriving identity from *that* value means two chunks'
    /// concurrent builds can never cross-contaminate each other's image
    /// UUID, regardless of how their calls interleave.
    private static func callIndex(from artifact: BuildArtifact) -> Int {
        guard let hash = artifact.productHash, hash.hasPrefix("fake-hash-"), let index = Int(hash.dropFirst("fake-hash-".count)) else {
            preconditionFailure("FakeSchemataAdapter artifact missing a parseable 'fake-hash-N' productHash: \(artifact.productHash ?? "nil")")
        }
        return index
    }

    private static let command = CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp")

    private func baselineArtifact() -> BuildArtifact {
        BuildArtifact(
            productsDirectory: URL(fileURLWithPath: "/tmp"), productHash: "fake-baseline-hash", xctestrunPath: nil, command: Self.command
        )
    }

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }
    func buildBaseline(in workspace: URL) async throws -> BuildArtifact { baselineArtifact() }
    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact { baselineArtifact() }

    func buildSchemataChunk(loweredSources: [SchemataSourceFile], in workspace: URL) async throws -> BuildArtifact {
        let callIndex: Int = lock.withLock {
            buildCallCount += 1
            return buildCallCount
        }

        // `buildFailureScript` itself is populated only during test setup
        // (before `run()` starts) and never mutated again, so reading it
        // here — unlocked, keyed by this call's own already-locked-and-
        // captured `callIndex` rather than a re-read of the shared counter —
        // is safe even when another chunk's build is running concurrently.
        switch buildFailureScript[callIndex] {
        case let .throwBuildFailure(kind, diagnosis):
            throw BuildFailure(kind: kind, diagnosis: diagnosis, command: Self.command, output: "")
        case .throwUntypedError:
            throw UntypedFakeError()
        case .nilProductHash:
            return BuildArtifact(
                productsDirectory: URL(fileURLWithPath: "/tmp"), productHash: nil, xctestrunPath: nil, command: Self.command
            )
        case .throwOnReceiptResolution, .none:
            return BuildArtifact(
                productsDirectory: URL(fileURLWithPath: "/tmp"), productHash: "fake-hash-\(callIndex)",
                xctestrunPath: nil, command: Self.command
            )
        }
    }

    func resolveSchemataBuildReceipt(
        for units: [SchemataCompilationUnitTargetRequest], artifact: BuildArtifact, in workspace: URL, context: SchemataBuildReceiptContext
    ) async throws -> SchemataBuildReceipt {
        // Derived from *this call's own* `artifact`, never a shared
        // "latest build" field: two chunks' builds/receipt resolutions can
        // run concurrently on this one adapter instance, and each must see
        // only its own build's identity, never whichever chunk happened to
        // build most recently.
        let callIndex = Self.callIndex(from: artifact)
        let imageUUID = Self.imageUUID(forBuildCall: callIndex)
        if case .throwOnReceiptResolution = buildFailureScript[callIndex] {
            throw UntypedFakeError()
        }
        var seenTargets: Set<BuildTargetIdentity> = []
        var images: [BuiltImageReceipt] = []
        for unit in units where seenTargets.insert(unit.buildTarget).inserted {
            let architecture = BuiltArchitectureIdentity(cpuType: 0x0100_000C, cpuSubtype: 0)
            let slice = BuiltImageSlice(architecture: architecture, imageUUID: imageUUID)
            images.append(try BuiltImageReceipt(
                buildTarget: unit.buildTarget, binaryPath: "/fake/binary", contentHash: SHA256Digest.of(Data("fake".utf8)), slices: [slice]
            ))
        }
        let compilationUnits = units.map {
            CompilationUnitReceipt(
                compilationUnitID: $0.compilationUnitID, sourceEmbeddingID: $0.sourceEmbeddingID, buildTarget: $0.buildTarget
            )
        }
        return try SchemataBuildReceipt(
            planID: context.planID, workUnitID: context.workUnitID, chunkID: context.chunkID,
            toolchainHash: context.toolchainHash, buildArgumentsHash: context.buildArgumentsHash,
            runtimeABIVersion: 3, images: images, compilationUnits: compilationUnits
        )
    }

    func runBaseline(_ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double) async throws -> TestRunResult {
        lock.withLock { baselineTimeoutSeconds.append(timeoutSeconds) }
        return TestRunResult(status: .passed, summary: nil, command: Self.command, resultArtifactPath: nil, diagnosis: "diag:passed")
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        fatalError("unused by SchemataMutationRunner")
    }

    // MARK: - TestSelecting (covering-tests attribution for schemata mode)

    /// Scripted return for `measurePerTestCoverage` — `nil` unless a test
    /// sets it, the same safe "no attribution" default every real adapter
    /// falls back to. Conforming this fake to `TestSelecting` (rather than
    /// building a separate fake) is what lets `SchemataMutationRunner`'s own
    /// `test as? any TestSelecting` cast succeed in test selection tests,
    /// the same discipline `MutationRunnerTestSelectionTests`'s
    /// `ScriptedSelectiveTestAdapter` uses for isolated mode.
    var perTestCoverageToReturn: PerTestCoverageMap?

    /// How many times the (expensive, on a real project ~85-minute)
    /// profiling pass was actually dispatched — the only direct evidence a
    /// `CoverageProfileCache` hit *skipped* it rather than merely producing
    /// the same map a fresh measurement would have. Read only after `run()`
    /// has fully returned, like `buildCallCount` above, so the unlocked
    /// external read is safe; the write itself takes `lock` because the
    /// baseline is not the only thing that could ever call this.
    private(set) var measurePerTestCoverageCallCount = 0

    func measurePerTestCoverage(
        artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        lock.withLock { measurePerTestCoverageCallCount += 1 }
        return perTestCoverageToReturn
    }

    /// `TestSelecting.runMutant` is never dispatched by
    /// `SchemataMutationRunner` — it only ever calls `runSchemataToken`,
    /// same as the unparameterised `runMutant` above.
    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        fatalError("unused by SchemataMutationRunner")
    }

    /// Every `selectedTests` this adapter was actually handed — direct
    /// evidence that `SchemataMutationRunner` threaded a covering-tests
    /// attribution down to the token run, when
    /// `SchemataMutationRunnerTestSelectionTests` sets one up.
    private(set) var selectedTestsSeen: [Set<TestIdentifier>?] = []
    /// `true` for the duration of `runSchemataTokenBatch`'s own internal
    /// per-item dispatch loop — lets `runSchemataToken` tell an individual
    /// (unbatched primary, or any confirmation — always individual, Phase
    /// H5 never batches those) dispatch apart from one made *as part of* a
    /// batch call, without threading a new parameter through the public
    /// `SchemataTestable` method signature itself.
    private var isInsideBatchDispatch = false
    /// How many times `runSchemataToken` was dispatched *outside* of
    /// `runSchemataTokenBatch` — direct evidence (Gate 3 Phase H5) that a
    /// batched entry's already-obtained primary result is never
    /// individually re-dispatched afterward (e.g. as an accidental side
    /// effect of a sibling's Trigger 1/2 rebuild): with N entries batched
    /// together and exactly one of them going on to a confirmation, this
    /// must equal exactly 1 (the confirmation alone), never N or more.
    private(set) var individualRunSchemataTokenCallCount = 0

    func runSchemataToken(
        _ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String],
        selectedTests: Set<TestIdentifier>?
    ) async throws -> TestRunResult {
        lock.withLock {
            tokenTimeoutSeconds.append(timeoutSeconds)
            selectedTestsSeen.append(selectedTests)
            if !isInsideBatchDispatch { individualRunSchemataTokenCallCount += 1 }
        }
        guard
            let tokenString = environment[SchemataEvidenceCollector.tokenEnvironmentVariable],
            let runIDHex = environment[SchemataEvidenceCollector.runIDEnvironmentVariable],
            let transcriptPathString = environment[SchemataEvidenceCollector.transcriptPathEnvironmentVariable]
        else {
            fatalError("FakeSchemataAdapter requires the schemata protocol env vars to be set")
        }
        let parts = tokenString.split(separator: ":")
        guard parts.count == 2, let namespace = UInt64(parts[0]), let localIndex = UInt32(parts[1]) else {
            fatalError("malformed token env var: \(tokenString)")
        }
        let token = SchemataSelectorToken(namespace: namespace, localIndex: localIndex)
        if lock.withLock({ throwOnNextRun.remove(token) }) != nil {
            struct ScriptedLaunchFailure: Error {}
            throw ScriptedLaunchFailure()
        }
        // `scripts` is populated only during test setup and never mutated
        // again, so this read is safe unlocked even while another chunk's
        // task concurrently reads a *different* key from the same dictionary.
        guard let script = scripts[token] else {
            fatalError("no script registered for token \(token)")
        }
        if let sideEffect = lock.withLock({ beforeNextRun.removeValue(forKey: token) }) {
            sideEffect()
        }
        // `delayNanosecondsBeforeRun`: same write-before-run-only discipline
        // as `scripts` above — safe to read unlocked here.
        if let delay = delayNanosecondsBeforeRun[token] {
            try? await Task.sleep(nanoseconds: delay)
        }
        let runID = RunID(rawValue: try #require(UUID(uuidString: Self.hyphenate(runIDHex))))

        let tokenCallIndex = lock.withLock { () -> Int in
            let index = callCounts[token, default: 0]
            callCounts[token] = index + 1
            runIDsSeenByToken[token, default: []].append(runID)
            return index
        }
        let behavior = script.behaviors[min(tokenCallIndex, script.behaviors.count - 1)]

        // `.timedOut`/`.crashed` always include HIT: both simulate a mutant
        // that was genuinely activated and only then hung/crashed — the
        // realistic shape, and the one ADR-0008's own confirmed-timeout
        // tests need (a `.verifiedTimeout` classification requires the
        // *confirming* run's own activation to be independently proven; see
        // `MutationVerdictVerifier.confirmTimeout`).
        let includeHit: Bool
        let status: TestRunStatus
        switch behavior {
        case let .passed(hit):
            includeHit = hit
            status = .passed
        case .timedOut:
            includeHit = true
            status = .timedOut
        case .crashed:
            includeHit = true
            status = .crashed
        }

        // Derived from *this call's own* `artifact`, never a shared
        // "latest build" field — see `resolveSchemataBuildReceipt`'s
        // identical rationale.
        let imageUUID = Self.imageUUID(forBuildCall: Self.callIndex(from: artifact))

        var data = Data()
        data.append(Self.record(eventType: 1, runID: runID, script: script, token: token, sequence: 0, imageUUID: imageUUID))
        if includeHit {
            data.append(Self.record(eventType: 2, runID: runID, script: script, token: token, sequence: 1, imageUUID: imageUUID))
        }
        try data.write(to: URL(fileURLWithPath: transcriptPathString))

        return TestRunResult(status: status, summary: nil, command: Self.command, resultArtifactPath: nil, diagnosis: "diag:\(status)")
    }

    // MARK: - SchemataBatchTestable (Gate 3 Phase H5)

    /// Every `nativeTimeoutAllowanceSeconds` a batch call actually received
    /// — direct evidence `SchemataMutationRunner` resolved and passed it
    /// through, the same role `tokenTimeoutSeconds` plays for the
    /// individual path.
    private(set) var schemataBatchNativeTimeoutAllowancesSeen: [Double?] = []
    /// How many times `runSchemataTokenBatch` was actually called — direct
    /// evidence a batch was attempted at all (as opposed to every item
    /// falling through to the individual `runSchemataToken` path).
    private(set) var schemataBatchCallCount = 0
    /// Gate 3 Phase H15C: mutations whose batch item should be dispatched
    /// normally (the script's own transcript-writing behavior still runs)
    /// but *omitted* from the returned results dictionary — simulating the
    /// real shape `prepareBatchedPrimaries` already has fallback code for
    /// ("the batch result dictionary has no result for the configuration"),
    /// which synthesizes `.infrastructureFailure` and is the same
    /// normalized "ambiguous batched primary" case a real `classifyBatch`
    /// per-configuration attribution gap produces. Populated only during
    /// test setup, read unlocked here for the same reason `scripts` is.
    var omitFromBatchResults: Set<MutationID> = []

    /// Reuses `runSchemataToken` per item, unchanged — the fake's own
    /// script/transcript-writing behavior must be identical whichever path
    /// dispatches it, the same "one variable, many origins" property the
    /// real adapter's `runSchemataTokenBatch` and `runSchemataToken` both
    /// hold via `BatchXCTestRunBuilder`/`XCResultAdapter.classifyBatch`.
    /// There is no real `xcodebuild` process here to actually contain a
    /// hang inside, so `nativeTimeoutAllowanceSeconds` is only recorded for
    /// assertions, never consulted — each item's own scripted `Behavior`
    /// (including `.timedOut`) already decides its result directly.
    func runSchemataTokenBatch(
        _ artifact: BuildArtifact, in workspace: URL, items: [SchemataBatchTokenItem], timeoutSeconds: Double,
        nativeTimeoutAllowanceSeconds: Double?
    ) async -> [MutationID: TestRunResult] {
        lock.withLock {
            schemataBatchCallCount += 1
            schemataBatchNativeTimeoutAllowancesSeen.append(nativeTimeoutAllowanceSeconds)
            isInsideBatchDispatch = true
        }
        var results: [MutationID: TestRunResult] = [:]
        for item in items {
            do {
                let result = try await runSchemataToken(
                    artifact, in: workspace, timeoutSeconds: timeoutSeconds, environment: item.environment,
                    selectedTests: item.selectedTests
                )
                if !omitFromBatchResults.contains(item.mutationID) {
                    results[item.mutationID] = result
                }
            } catch {
                results[item.mutationID] = TestRunResult(
                    status: .infrastructureFailure, summary: nil, command: Self.command, resultArtifactPath: nil,
                    diagnosis: "FakeSchemataAdapter batch item failed: \(error)"
                )
            }
        }
        lock.withLock { isInsideBatchDispatch = false }
        return results
    }

    // MARK: - v3 binary record encoding (mirrors SchemataEvidenceCollectorTests' own hand-crafted format)

    private static func hyphenate(_ hex32: String) -> String {
        guard hex32.count == 32 else { return hex32 }
        let chars = Array(hex32)
        return "\(String(chars[0 ..< 8]))-\(String(chars[8 ..< 12]))-\(String(chars[12 ..< 16]))-" +
            "\(String(chars[16 ..< 20]))-\(String(chars[20 ..< 32]))"
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        return bytes
    }

    private static func record(
        eventType: UInt8, runID: RunID, script: Script, token: SchemataSelectorToken, sequence: UInt64, imageUUID: ImageUUID
    ) -> Data {
        var data = Data()
        data.appendBE(UInt32(0x4D4B_5633)) // magic
        data.appendBE(UInt16(136)) // record_size
        data.appendBE(UInt16(3)) // protocol_version
        data.append(eventType)
        data.append(contentsOf: [0, 0, 0]) // reserved
        data.append(contentsOf: hexToBytes(runID.rawValue.uuidString.replacingOccurrences(of: "-", with: "").lowercased()))
        data.append(contentsOf: hexToBytes(script.sourceEmbeddingID.rawValue))
        data.append(contentsOf: hexToBytes(script.compilationUnitID.rawValue))
        data.appendBE(token.namespace)
        data.appendBE(token.localIndex)
        data.appendBE(UInt32(bitPattern: processID))
        data.appendBE(sequence)
        data.append(contentsOf: hexToBytes(imageUUID.rawValue))
        data.appendBE(UInt32(3)) // runtimeABIVersion
        precondition(data.count == 136)
        return data
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt64) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
