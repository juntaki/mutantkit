import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `SchemataMutationRunner`'s Group 2 routing (ADR-0006): a mutation
/// whose schemata attempt has a passing test but no runtime activation
/// proof (`MutationVerdictVerifier.schemataIsolatedFallbackReason`) is
/// dropped from `Outcome.results`/`.multiTargetVerdicts` entirely and
/// surfaced in `Outcome.isolatedFallbacks` instead — never scored as
/// `infrastructureFailure` from schemata evidence alone. `SchemataRunOrchestration`
/// (untested here) is what actually re-runs these through isolated mode;
/// this suite only pins the runner's own half: what it keeps, what it drops.
///
/// A fake `SchemataBuildable`/`SchemataTestable` writes real v3 binary
/// transcript records (the same wire format `SchemataEvidenceCollectorTests`
/// pins) so `MutationVerdictVerifier.verifySchemataChain` runs unmodified
/// against genuine bytes, never a shortcut that assumes what the runner
/// will decide.
@Suite("SchemataMutationRunner: Group 2 dynamic isolated fallback")
struct SchemataMutationRunnerDynamicFallbackTests {
    // MARK: - Fixture: one real MutationPoint (BoolLiteralInversion, simplest discoverable candidate)

    private static let source = "func flag() -> Bool { true }\n"
    private static let relativePath = "Widget.swift"

    private func point() throws -> MutationPoint {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        return try #require(points.first, "expected a bool-literal candidate")
    }

    private static let projectIdentity = "App.xcodeproj"
    private static let lowererID = "bool-literal"
    private static let lowererVersion = 1

    private func entry(
        mutationID: MutationID, target: String, chunkID: String, localIndex: UInt32, namespace: UInt64
    ) -> SchemataPlanEntry {
        SchemataPlanEntry(
            mutationID: mutationID,
            placement: .embedded(placements: [
                SchemataEmbeddedPlacement(
                    chunkID: chunkID, selectorToken: SchemataSelectorToken(namespace: namespace, localIndex: localIndex),
                    sourceEmbeddingID: Self.sourceEmbeddingID.rawValue, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion,
                    projectIdentity: Self.projectIdentity, target: target, module: target, product: "\(target).app", expectedImages: []
                )
            ]),
            conflictGroup: nil, projectIdentity: Self.projectIdentity, target: target, module: target, product: "\(target).app"
        )
    }

    private static let sourceEmbeddingID = SHA256Digest.of(Data(source.utf8))

    private func program(chunkID: String, entry: SchemataPlanEntry) -> SchemataProgram {
        SchemataProgram(
            chunkID: chunkID, sourceEmbeddingID: Self.sourceEmbeddingID.rawValue,
            loweredSources: [SchemataSourceFile(relativePath: Self.relativePath, contents: Self.source)],
            entries: [entry]
        )
    }

    private func compilationUnitID(target: String, point: MutationPoint) -> CompilationUnitID {
        CompilationUnitID.derive(
            projectIdentity: Self.projectIdentity, target: target, module: target,
            sourcePath: point.file, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
        )
    }

    // MARK: - Running

    private func run(
        _ mutationID: MutationID, programs: [SchemataProgram], adapter: FakeSchemataAdapter
    ) async throws -> SchemataMutationRunner.Outcome {
        let mutationPoint = try point()
        let runner = SchemataMutationRunner(
            planID: "plan-1", workUnitID: "wu-1", programs: programs, points: [mutationID: mutationPoint],
            originalSources: [Self.relativePath: Data(Self.source.utf8)],
            build: adapter, test: adapter,
            workspaces: try WorkspaceManager(
                projectRoot: Self.makeTempDir(prefix: "mutantkit-fallback-project"),
                scratchRoot: Self.makeTempDir(prefix: "mutantkit-fallback-scratch")
            ),
            timeoutSeconds: 30, toolchainHash: "toolchain", buildArgumentsHash: "args",
            policy: .permissive
        )
        return try await runner.run()
    }

    private static func makeTempDir(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Tests

    @Test("A single-target mutation with no runtime HIT falls back to isolated, never scored as schemata infrastructureFailure")
    func singleTargetNoHitFallsBackDynamically() async throws {
        let mutationPoint = try point()
        let mutationID = mutationPoint.id
        let target = "App"
        let unit = compilationUnitID(target: target, point: mutationPoint)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: unit, sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: false
        )

        let entry = entry(mutationID: mutationID, target: target, chunkID: "chunk-A", localIndex: 1, namespace: 1)
        let outcome = try await run(mutationID, programs: [program(chunkID: "chunk-A", entry: entry)], adapter: adapter)

        #expect(outcome.results.isEmpty, "a no-HIT mutation must never appear in results")
        #expect(outcome.multiTargetVerdicts.isEmpty)
        let fallback = try #require(outcome.isolatedFallbacks.first)
        #expect(fallback.mutationID == mutationID)
        #expect(fallback.reason == .noHit)
    }

    @Test("A single-target mutation with a valid chain scores normally, no fallback")
    func singleTargetValidChainNeedsNoFallback() async throws {
        let mutationPoint = try point()
        let mutationID = mutationPoint.id
        let target = "App"
        let unit = compilationUnitID(target: target, point: mutationPoint)
        let adapter = FakeSchemataAdapter()
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: unit, sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )

        let entry = entry(mutationID: mutationID, target: target, chunkID: "chunk-A", localIndex: 1, namespace: 1)
        let outcome = try await run(mutationID, programs: [program(chunkID: "chunk-A", entry: entry)], adapter: adapter)

        #expect(outcome.isolatedFallbacks.isEmpty)
        #expect(outcome.results.count == 1)
        #expect(outcome.multiTargetVerdicts.count == 1)
    }

    /// The Group 2 multi-target regression (Step 16): the same MutationID
    /// embedded into two targets, one with a valid chain, the other
    /// passing but with no HIT. All-or-nothing — the *whole* MutationID
    /// falls back, including the target that individually verified fine,
    /// never a partial schemata/isolated split for the same MutationID.
    @Test("Multi-target: one target's no-HIT drags the whole MutationID to fallback, even though the other target verified fine")
    func multiTargetAllOrNothingFallback() async throws {
        let mutationPoint = try point()
        let mutationID = mutationPoint.id
        let targetA = "App"
        let targetB = "Widget"
        let unitA = compilationUnitID(target: targetA, point: mutationPoint)
        let unitB = compilationUnitID(target: targetB, point: mutationPoint)

        let adapter = FakeSchemataAdapter()
        adapter.scripts[SchemataSelectorToken(namespace: 1, localIndex: 1)] = .init(
            compilationUnitID: unitA, sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: true
        )
        adapter.scripts[SchemataSelectorToken(namespace: 2, localIndex: 1)] = .init(
            compilationUnitID: unitB, sourceEmbeddingID: Self.sourceEmbeddingID, includeHit: false
        )

        let entryA = entry(mutationID: mutationID, target: targetA, chunkID: "chunk-A", localIndex: 1, namespace: 1)
        let entryB = entry(mutationID: mutationID, target: targetB, chunkID: "chunk-B", localIndex: 1, namespace: 2)
        let outcome = try await run(
            mutationID, programs: [program(chunkID: "chunk-A", entry: entryA), program(chunkID: "chunk-B", entry: entryB)], adapter: adapter
        )

        #expect(outcome.results.isEmpty, "no partial schemata result may survive for a MutationID with any fallback placement")
        #expect(outcome.multiTargetVerdicts.isEmpty)
        #expect(outcome.isolatedFallbacks.count == 1)
        let fallback = try #require(outcome.isolatedFallbacks.first)
        #expect(fallback.mutationID == mutationID)
        #expect(fallback.reason == .noHit)
    }
}

// MARK: - Fake SchemataBuildable/SchemataTestable

/// Writes real v3 binary transcript records (`mutantkit_protocol_v3.c`'s
/// wire format) rather than short-circuiting `MutationVerdictVerifier
/// .verifySchemataChain` — the same discipline `SchemataEvidenceCollectorTests`
/// uses to pin the parser itself, applied here so the runner-level fallback
/// routing is proven against genuine bytes.
private final class FakeSchemataAdapter: BuildAdapter, SchemataBuildable, TestAdapter, SchemataTestable, @unchecked Sendable {
    struct Script {
        let compilationUnitID: CompilationUnitID
        let sourceEmbeddingID: SHA256Digest
        let includeHit: Bool
    }

    private static let imageUUID = ImageUUID(rawValue: String(repeating: "cc", count: 16))!
    private static let processID: Int32 = 4242

    var scripts: [SchemataSelectorToken: Script] = [:]

    private static let command = CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp")

    private func artifact() -> BuildArtifact {
        BuildArtifact(productsDirectory: URL(fileURLWithPath: "/tmp"), productHash: "fake-hash", xctestrunPath: nil, command: Self.command)
    }

    func diagnose() async throws -> BuildDiagnosis { BuildDiagnosis(items: []) }
    func buildBaseline(in workspace: URL) async throws -> BuildArtifact { artifact() }
    func buildMutant(_ mutation: AppliedMutation, in workspace: URL) async throws -> BuildArtifact { artifact() }
    func buildSchemataChunk(loweredSources: [SchemataSourceFile], in workspace: URL) async throws -> BuildArtifact { artifact() }

    func resolveSchemataBuildReceipt(
        for units: [SchemataCompilationUnitTargetRequest], artifact: BuildArtifact, in workspace: URL, context: SchemataBuildReceiptContext
    ) async throws -> SchemataBuildReceipt {
        var seenTargets: Set<BuildTargetIdentity> = []
        var images: [BuiltImageReceipt] = []
        for unit in units where seenTargets.insert(unit.buildTarget).inserted {
            let architecture = BuiltArchitectureIdentity(cpuType: 0x0100_000C, cpuSubtype: 0)
            let slice = BuiltImageSlice(architecture: architecture, imageUUID: Self.imageUUID)
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
        TestRunResult(status: .passed, summary: nil, command: Self.command, resultArtifactPath: nil, diagnosis: "diag:passed")
    }

    func runMutant(
        _ point: MutationPoint, artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double
    ) async throws -> TestRunResult {
        fatalError("unused by SchemataMutationRunner")
    }

    func runSchemataToken(
        _ artifact: BuildArtifact, in workspace: URL, timeoutSeconds: Double, environment: [String: String]
    ) async throws -> TestRunResult {
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
        guard let script = scripts[token] else {
            fatalError("no script registered for token \(token)")
        }
        let runID = RunID(rawValue: try #require(UUID(uuidString: Self.hyphenate(runIDHex))))

        var data = Data()
        data.append(Self.record(eventType: 1, runID: runID, script: script, token: token, sequence: 0))
        if script.includeHit {
            data.append(Self.record(eventType: 2, runID: runID, script: script, token: token, sequence: 1))
        }
        try data.write(to: URL(fileURLWithPath: transcriptPathString))

        return TestRunResult(status: .passed, summary: nil, command: Self.command, resultArtifactPath: nil, diagnosis: "diag:passed")
    }

    // MARK: - v3 binary record encoding (mirrors SchemataEvidenceCollectorTests' own hand-crafted format)

    private static func hyphenate(_ hex32: String) -> String {
        guard hex32.count == 32 else { return hex32 }
        let chars = Array(hex32)
        return "\(String(chars[0 ..< 8]))-\(String(chars[8 ..< 12]))-\(String(chars[12 ..< 16]))-\(String(chars[16 ..< 20]))-\(String(chars[20 ..< 32]))"
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

    private static func record(eventType: UInt8, runID: RunID, script: Script, token: SchemataSelectorToken, sequence: UInt64) -> Data {
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
