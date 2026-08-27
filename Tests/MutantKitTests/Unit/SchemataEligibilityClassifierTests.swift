import Foundation
import MutationModel
import MutationPlanner
@testable import SchemataEligibilityClassifier
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `EligibilityClassifier`: `MutationPlan.decode(from:)` (not a raw
/// permissive decoder) rejects a structurally-invalid plan; a source whose
/// on-disk content no longer matches the plan's recorded hash is a
/// run-level failure, never a per-mutant classification; `plannerEmbedded`
/// reflects `SchemataChunkPlanner.plan`'s own authoritative decision, which
/// can diverge from a lowerer's own `analyze()` (a batch-local `lower()`
/// failure — the same shape `SchemataChunkPlannerBatchFailureRecoveryTests`
/// already pins at the planner level); classification is deterministic;
/// and cross-arm comparison fails closed on any mismatch.
@Suite("EligibilityClassifier")
struct SchemataEligibilityClassifierTests {
    private static let appTarget = SchemataTargetInfo(
        projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
    )

    private func discoverPoints(_ source: String, operatorID: String, relativePath: String) throws -> [MutationPoint] {
        try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID, relativePath: relativePath)
    }

    /// A fresh temp directory with `files` written to it, used as
    /// `projectRoot` — `EligibilityClassifier.classify` reads real files
    /// from disk (matching the real formal run's own behavior), so every
    /// test needs an actual directory, not just in-memory fixtures.
    private func makeProjectRoot(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, content) in files {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: fileURL)
        }
        return root
    }

    private func literalTargetResolver(
        _ targetInfo: [String: [SchemataTargetInfo]]
    ) -> @Sendable (URL) async throws -> [String: [SchemataTargetInfo]] {
        { _ in targetInfo }
    }

    @Test("An invalid plan (duplicate MutationID) is rejected, not silently accepted by a permissive decoder")
    func invalidPlanRejected() async throws {
        let source = "func add(_ a: Int, _ b: Int) -> Int { a + b }\n"
        let points = try discoverPoints(source, operatorID: ArithmeticOperatorReplacementOperator.descriptor.id, relativePath: "Widget.swift")
        let point = try #require(points.first)
        // Two distinct plan entries sharing one MutationID — exactly what
        // `IntegrityChecker.validatePlan`'s `.duplicateMutationID` case
        // exists to catch, and what a raw `JSONDecoder().decode(MutationPlan
        // .self, from:)` would let through silently (a structurally valid
        // `Codable` shape, not a JSON syntax error).
        let mutationPlan = makePlan(mutations: [point, point], sourceFileHashes: ["Widget.swift": ContentHash.of(source)])
        let planData = try MutationPlan.encoder().encode(mutationPlan)
        let root = try makeProjectRoot(files: ["Widget.swift": source])
        let registry = try SchemataLowererRegistry()

        do {
            _ = try await EligibilityClassifier.classify(
                planData: planData, planPath: "plan.json", projectRoot: root,
                operatorID: ArithmeticOperatorReplacementOperator.descriptor.id, registry: registry,
                resolveTargetInfo: self.literalTargetResolver(["Widget.swift": [Self.appTarget]])
            )
            Issue.record("expected classify to throw on a plan with a duplicate MutationID")
        } catch is PlanError {
            // Expected: MutationPlan.decode's own integrity check caught it.
        }
    }

    @Test("A source file whose on-disk content no longer matches the plan's recorded hash is a run-level failure")
    func sourceDriftRejected() async throws {
        let originalSource = "func add(_ a: Int, _ b: Int) -> Int { a + b }\n"
        let points = try discoverPoints(originalSource, operatorID: ArithmeticOperatorReplacementOperator.descriptor.id, relativePath: "Widget.swift")
        let mutationPlan = makePlan(mutations: points, sourceFileHashes: ["Widget.swift": ContentHash.of(originalSource)])
        let planData = try MutationPlan.encoder().encode(mutationPlan)

        // The file on disk has drifted since the plan was written — a
        // different comment appended, still syntactically valid, but no
        // longer what the plan's own `sourceFileHashes` recorded.
        let driftedSource = originalSource + "// drifted\n"
        let root = try makeProjectRoot(files: ["Widget.swift": driftedSource])
        let registry = try SchemataLowererRegistry()

        do {
            _ = try await EligibilityClassifier.classify(
                planData: planData, planPath: "plan.json", projectRoot: root,
                operatorID: ArithmeticOperatorReplacementOperator.descriptor.id, registry: registry,
                resolveTargetInfo: self.literalTargetResolver(["Widget.swift": [Self.appTarget]])
            )
            Issue.record("expected classify to throw on source drift")
        } catch let EligibilityClassificationError.sourceDrift(file, _, _) {
            #expect(file == "Widget.swift")
        }
    }

    @Test("A mutation candidate file with no entry in sourceFileHashes is a run-level failure, not silently unverified")
    func missingSourceHashRejected() async throws {
        let source = "func add(_ a: Int, _ b: Int) -> Int { a + b }\n"
        let points = try discoverPoints(source, operatorID: ArithmeticOperatorReplacementOperator.descriptor.id, relativePath: "Widget.swift")
        // sourceFileHashes deliberately omits "Widget.swift" — legal under
        // MutationPlan.decode's own integrity check, which does not require
        // full coverage there.
        let mutationPlan = makePlan(mutations: points, sourceFileHashes: [:])
        let planData = try MutationPlan.encoder().encode(mutationPlan)
        let root = try makeProjectRoot(files: ["Widget.swift": source])
        let registry = try SchemataLowererRegistry()

        do {
            _ = try await EligibilityClassifier.classify(
                planData: planData, planPath: "plan.json", projectRoot: root,
                operatorID: ArithmeticOperatorReplacementOperator.descriptor.id, registry: registry,
                resolveTargetInfo: self.literalTargetResolver(["Widget.swift": [Self.appTarget]])
            )
            Issue.record("expected classify to throw on a candidate file missing from sourceFileHashes")
        } catch let EligibilityClassificationError.missingSourceHash(file) {
            #expect(file == "Widget.swift")
        }
    }

    @Test("A target-resolution failure surfaces as a thrown error before any classification is produced")
    func targetResolutionFailureSurfaces() async throws {
        let source = "func add(_ a: Int, _ b: Int) -> Int { a + b }\n"
        let points = try discoverPoints(source, operatorID: ArithmeticOperatorReplacementOperator.descriptor.id, relativePath: "Widget.swift")
        let mutationPlan = makePlan(mutations: points, sourceFileHashes: ["Widget.swift": ContentHash.of(source)])
        let planData = try MutationPlan.encoder().encode(mutationPlan)
        let root = try makeProjectRoot(files: ["Widget.swift": source])
        let registry = try SchemataLowererRegistry()

        struct FakeResolutionFailure: Error {}

        do {
            _ = try await EligibilityClassifier.classify(
                planData: planData, planPath: "plan.json", projectRoot: root,
                operatorID: ArithmeticOperatorReplacementOperator.descriptor.id, registry: registry,
                resolveTargetInfo: { _ in throw FakeResolutionFailure() }
            )
            Issue.record("expected classify to throw on target resolution failure")
        } catch EligibilityClassificationError.targetResolutionFailed {
            // Expected — matches a real production app checkout's own failure mode
            // (SwiftPMTargetResolver requiring a Package.swift an Xcode
            // project does not have), surfaced loudly here rather than
            // silently degrading to an empty, indistinguishable-from-
            // "everything ineligible" result the way the real formal run's
            // own classify(_:) does.
        }
    }

    /// Always `analyze()`-eligible; `lower(_:sources:)` throws iff the
    /// chunk contains `poisonedMutationID` — the same shape
    /// `SchemataChunkPlannerBatchFailureRecoveryTests.FailingBatchFakeLowerer`
    /// already pins at the planner level, reused here to prove the
    /// classifier's `plannerEmbedded` field reflects that planner-level
    /// outcome rather than re-deriving from `analyze()` alone.
    private struct FailingBatchFakeLowerer: SchemataLowerer {
        static let lowererID = "test.classifier-batch-failure-fake"
        let poisonedMutationID: MutationID

        var descriptor: SchemataLowererDescriptor {
            SchemataLowererDescriptor(
                lowererID: Self.lowererID, lowererVersion: 1, runtimeABIVersion: 1,
                supportedOperatorIDs: [BoolLiteralInversionOperator.descriptor.id]
            )
        }

        func analyze(_: MutationPoint, source _: Data) -> SchemataEligibility {
            .eligible(loweringKind: .literalSelection, rewriteEnvelope: ByteRange(start: 0, end: 0), conflictKeys: [])
        }

        func lower(_ chunk: SchemataChunk, sources: [SchemataSourceFile]) throws -> SchemataProgram {
            guard !chunk.points.contains(where: { $0.id == poisonedMutationID }) else {
                struct FakeLoweringFailure: Error {}
                throw FakeLoweringFailure()
            }
            let entries = chunk.points.enumerated().map { index, point in
                let token = SchemataSelectorToken(namespace: chunk.namespace, localIndex: UInt32(index + 1))
                let placement = SchemataEmbeddedPlacement(
                    chunkID: chunk.chunkID, selectorToken: token, sourceEmbeddingID: "fake",
                    lowererID: Self.lowererID, lowererVersion: 1,
                    projectIdentity: chunk.projectIdentity, target: chunk.target, module: chunk.module, product: chunk.product,
                    expectedImages: []
                )
                return SchemataPlanEntry(
                    mutationID: point.id, placement: .embedded(placements: [placement]), conflictGroup: nil,
                    projectIdentity: chunk.projectIdentity, target: chunk.target, module: chunk.module, product: chunk.product
                )
            }
            return SchemataProgram(chunkID: chunk.chunkID, sourceEmbeddingID: "fake", loweredSources: sources, entries: entries)
        }
    }

    @Test("A mutation that analyze() clears but whose batch fails to lower is NOT reported plannerEmbedded")
    func analyzeEligibleButPlannerFallbackNotReportedEmbedded() async throws {
        let source = """
        func flagA() -> Bool { true }
        func flagB() -> Bool { true }
        """
        let points = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift")
        #expect(points.count == 2)
        let poisoned = try #require(points.first)
        let healthy = try #require(points.dropFirst().first)

        let mutationPlan = makePlan(mutations: points, sourceFileHashes: ["Widget.swift": ContentHash.of(source)])
        let planData = try MutationPlan.encoder().encode(mutationPlan)
        let root = try makeProjectRoot(files: ["Widget.swift": source])
        let registry = try SchemataLowererRegistry(lowerers: [FailingBatchFakeLowerer(poisonedMutationID: poisoned.id)])

        // maxChunkSize: 1 forces each point into its own batch — poisoned
        // and healthy never share a batch, matching
        // `SchemataChunkPlannerBatchFailureRecoveryTests`'s own setup, so
        // this isolates the recovery to exactly the batch that failed.
        let result = try await EligibilityClassifier.classify(
            planData: planData, planPath: "plan.json", projectRoot: root,
            operatorID: BoolLiteralInversionOperator.descriptor.id, registry: registry, maxChunkSize: 1,
            resolveTargetInfo: self.literalTargetResolver(["Widget.swift": [Self.appTarget]])
        )

        let byID = Dictionary(uniqueKeysWithValues: result.classifications.map { ($0.mutationID, $0) })
        let poisonedClassification = try #require(byID[poisoned.id.rawValue])
        #expect(poisonedClassification.lowererEligible, "analyze() always clears this fake lowerer's points")
        #expect(
            !poisonedClassification.plannerEmbedded,
            "the planner's own batch-lowering failure must be reflected, not masked by analyze()'s optimism"
        )

        let healthyClassification = try #require(byID[healthy.id.rawValue])
        #expect(healthyClassification.lowererEligible)
        #expect(
            healthyClassification.plannerEmbedded,
            "an unrelated batch's point must still embed even though a sibling batch failed to lower"
        )
    }

    @Test("Classifying the same plan twice produces the identical plannerEmbedded set")
    func embeddedMembershipIsDeterministic() async throws {
        let source = "func flag() -> Bool { true }\n"
        let points = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift")
        let mutationPlan = makePlan(mutations: points, sourceFileHashes: ["Widget.swift": ContentHash.of(source)])
        let planData = try MutationPlan.encoder().encode(mutationPlan)
        let root = try makeProjectRoot(files: ["Widget.swift": source])
        let registry = try SchemataLowererRegistry()

        func classifyOnce() async throws -> Set<String> {
            try await EligibilityClassifier.classify(
                planData: planData, planPath: "plan.json", projectRoot: root,
                operatorID: BoolLiteralInversionOperator.descriptor.id, registry: registry,
                resolveTargetInfo: self.literalTargetResolver(["Widget.swift": [Self.appTarget]])
            ).plannerEmbeddedMutationIDs
        }

        let first = try await classifyOnce()
        let second = try await classifyOnce()
        #expect(first == second)
        #expect(!first.isEmpty, "sanity: this fixture is genuinely embeddable, not vacuously equal empty sets")
    }

    @Test("Cross-arm comparison fails closed when the present/absent plannerEmbedded sets differ")
    func crossArmComparisonFailsClosedOnMismatch() {
        let present: Set = ["mut_a", "mut_b"]
        let absent: Set = ["mut_a"]

        #expect(throws: EligibilityClassifier.CrossArmMismatchError.self) {
            try EligibilityClassifier.assertIdenticalAcrossArms(present: present, absent: absent)
        }
    }

    @Test("Cross-arm comparison passes silently when the sets are identical")
    func crossArmComparisonPassesOnMatch() throws {
        let ids: Set = ["mut_a", "mut_b"]
        try EligibilityClassifier.assertIdenticalAcrossArms(present: ids, absent: ids)
    }

    // MARK: - Regression: the sync-bridge sync/async deadlock this suite once caused

    /// `EligibilityClassification.swift`'s sync-bridge helper exists for exactly one
    /// legitimate caller: `SchemataEligibilityClassifier/main.swift`, a plain synchronous
    /// CLI entry point that has no other way to call into `async` code. This suite used to
    /// call that same helper from inside its own test bodies to avoid marking them `async`
    /// — but Swift Testing schedules test bodies onto its own cooperative thread pool, and
    /// the helper parks its *calling* thread on a semaphore until an inner `Task` it spawns
    /// signals it. With enough tests reaching the helper concurrently (trivially reached on
    /// a CI runner with few cores), every pool thread ends up parked on that semaphore
    /// simultaneously, leaving no thread free to ever run the pending inner `Task`s — a
    /// permanent deadlock. That was the actual, confirmed cause of a real public-CI hang
    /// (a stack sample of the stuck worker process showed every thread waiting inside the
    /// helper). The fix was simply to make the test functions `async` and call the `async`
    /// API directly; this test pins that nothing under `Tests/` regresses back to the
    /// sync-bridge pattern.
    @Test("Nothing under Tests/ calls the production-only sync-bridge helper that once deadlocked CI")
    func nothingUnderTestsCallsTheProductionOnlySyncBridge() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let testsRoot = testFileURL
            .deletingLastPathComponent() // Unit/
            .deletingLastPathComponent() // MutantKitTests/
            .deletingLastPathComponent() // Tests/
        let forbiddenCallSyntax = "blocking" + " {" // split so this very file doesn't self-match the scan below
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.path != testFileURL.path else { continue }
            let contents = try String(contentsOf: url, encoding: .utf8)
            if contents.contains(forbiddenCallSyntax) {
                offenders.append(url.path)
            }
        }
        #expect(
            offenders.isEmpty,
            """
            found the sync-bridge trailing-closure call pattern under Tests/ — this deadlocks Swift Testing's \
            cooperative thread pool under load; use an async test function and call the async API directly \
            instead: \(offenders)
            """
        )
    }
}
