import Foundation
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `SchemataChunkPlanner`: routes each mutation to isolated fallback or
/// a real, lowered chunk; groups only within the same lowerer/target/
/// module/product; respects a chunk-size cap; and produces a `SchemataPlan`
/// that survives `decodeAndValidate` against the `MutationPlan` it came
/// from — the actual, meaningful proof that the planner's output is
/// internally consistent, not just "didn't throw."
@Suite("SchemataChunkPlanner")
struct SchemataChunkPlannerTests {
    fileprivate static let backend = SchemataBackendInfo(
        backendID: "swiftpm-process-executor", backendVersion: 1,
        toolchainHash: "sha256:toolchain", buildArgumentsHash: "sha256:args"
    )

    fileprivate static let appTarget = SchemataTargetInfo(
        projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
    )

    private func discoverPoints(_ source: String, operatorID: String, relativePath: String) throws -> [MutationPoint] {
        try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID, relativePath: relativePath)
    }

    @Test("An all-eligible plan produces one chunk with no fallback entries")
    func allEligiblePlanProducesOneChunk() throws {
        let source = "func flag() -> Bool { true }\n"
        let points = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift")
        let mutationPlan = makePlan(mutations: points)
        let registry = try SchemataLowererRegistry()

        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["Widget.swift": Data(source.utf8)],
            targetInfo: ["Widget.swift": [Self.appTarget]],
            backend: Self.backend
        )

        #expect(result.programs.count == 1)
        #expect(result.schemataPlan.entries.count == 1)
        #expect(result.schemataPlan.entries.allSatisfy { $0.isEmbedded })
    }

    @Test("An unsupported operator's mutation falls back with operatorNotYetLowered")
    func unsupportedOperatorFallsBack() throws {
        let source = "func add(_ a: Int, _ b: Int) -> Int { a + b }\n"
        let points = try discoverPoints(
            source, operatorID: "swift.core.arithmetic-operator-replacement", relativePath: "Widget.swift"
        )
        let mutationPlan = makePlan(mutations: points)
        let registry = try SchemataLowererRegistry()

        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["Widget.swift": Data(source.utf8)],
            targetInfo: ["Widget.swift": [Self.appTarget]],
            backend: Self.backend
        )

        #expect(result.programs.isEmpty)
        let entry = try #require(result.schemataPlan.entries.first)
        #expect(!entry.isEmbedded)
        #expect(entry.fallbackReason == .operatorNotYetLowered(operatorID: "swift.core.arithmetic-operator-replacement"))
    }

    /// ADR-0005 PR F: a file compiled into more than one target — a shared
    /// model file added directly to two targets' own Compile Sources, say —
    /// embeds independently into *each* target's own build: two separate
    /// chunks, two separate selector namespaces, one merged
    /// `SchemataPlanEntry` carrying both placements (`SchemataPlan
    /// .decodeAndValidate` allows only one entry per `MutationID`).
    @Test("A file compiled into more than one target embeds independently into each")
    func multiTargetFileEmbedsIntoEachTarget() throws {
        let source = "func flag() -> Bool { true }\n"
        let points = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Shared.swift")
        let mutationPlan = makePlan(mutations: points)
        let registry = try SchemataLowererRegistry()

        let widgetTarget = SchemataTargetInfo(
            projectIdentity: "App.xcodeproj", target: "Widget", module: "Widget", product: "Widget.appex"
        )
        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["Shared.swift": Data(source.utf8)],
            targetInfo: ["Shared.swift": [Self.appTarget, widgetTarget]],
            backend: Self.backend
        )

        #expect(result.programs.count == 2, "each target is a genuinely separate build/chunk")
        #expect(result.schemataPlan.entries.count == 1, "one MutationID collapses to one merged entry")
        let entry = try #require(result.schemataPlan.entries.first)
        #expect(entry.isEmbedded)
        #expect(entry.fallbackReason == nil)
        #expect(entry.placements.count == 2, "one placement per target this mutation was embedded into")
        #expect(Set(entry.placements.map(\.target)) == ["App", "Widget"])
        #expect(
            Set(entry.placements.map(\.chunkID)).count == 2,
            "each target's embedding gets its own chunk, never sharing one across targets"
        )
        #expect(
            Set(entry.placements.map(\.selectorToken)).count == 2,
            "each target's embedding gets its own selector token/namespace"
        )
    }

    /// A multi-target file's independent embeddings must not disturb a
    /// *different*, single-membership file that shares one of its targets:
    /// the shared file still needs to be present in that target's own
    /// chunk (it's part of the real compile unit `filesByTarget` assembles
    /// `chunkSources` from) alongside its own embedded mutation. A bug in
    /// `filesByTarget`'s multi-membership rewrite could plausibly drop a
    /// membership (e.g. only recording a file under one target) without
    /// this test catching it.
    @Test("A multi-target file's own chunk still carries a sibling file's independent mutation for the shared target")
    func multiTargetFileSiblingChunkStillCarriesItsOwnMutation() throws {
        let sharedSource = "func sharedFlag() -> Bool { true }\n"
        let widgetSource = "func widgetFlag() -> Bool { true }\n"
        let sharedPoints = try discoverPoints(
            sharedSource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Shared.swift"
        )
        let widgetPoints = try discoverPoints(
            widgetSource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift"
        )
        let mutationPlan = makePlan(mutations: sharedPoints + widgetPoints)
        let registry = try SchemataLowererRegistry()

        let widgetTarget = SchemataTargetInfo(
            projectIdentity: "App.xcodeproj", target: "Widget", module: "Widget", product: "Widget.appex"
        )
        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["Shared.swift": Data(sharedSource.utf8), "Widget.swift": Data(widgetSource.utf8)],
            targetInfo: [
                "Shared.swift": [Self.appTarget, widgetTarget],
                "Widget.swift": [Self.appTarget]
            ],
            backend: Self.backend
        )

        // Shared.swift's App-target chunk and Widget.swift's own chunk are
        // the same chunk (both route to the App target's own group) —
        // Shared.swift's Widget-target embedding is a separate, third chunk.
        #expect(result.programs.count == 2, "App target's one chunk (both files) plus Widget target's own chunk")
        let appChunk = try #require(
            result.programs.first { $0.entries.count == 2 },
            "the App-target chunk embeds both Shared.swift's and Widget.swift's points together"
        )
        let sharedCopyInAppChunk = try #require(
            appChunk.loweredSources.first { $0.relativePath == "Shared.swift" }
        )
        #expect(
            sharedCopyInAppChunk.contents.contains("__mutantkitIsActive"),
            "Shared.swift's own point IS embedded in the App target's chunk now, unlike the old fallback behavior"
        )

        let entries = Dictionary(uniqueKeysWithValues: result.schemataPlan.entries.map { ($0.mutationID, $0) })
        let sharedEntry = try #require(entries[sharedPoints[0].id])
        #expect(sharedEntry.placements.count == 2, "Shared.swift's point embeds into both App and Widget targets")
        let widgetFileEntry = try #require(entries[widgetPoints[0].id])
        #expect(widgetFileEntry.placements.count == 1, "Widget.swift belongs only to the App target")
    }

    @Test("A chunk size cap splits eligible points across multiple chunks")
    func chunkSizeCapSplitsPoints() throws {
        let source = """
        func flags() -> [Bool] {
            [true, true, true]
        }
        """
        let points = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift")
        #expect(points.count == 3)
        let mutationPlan = makePlan(mutations: points)
        let registry = try SchemataLowererRegistry()

        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["Widget.swift": Data(source.utf8)],
            targetInfo: ["Widget.swift": [Self.appTarget]],
            backend: Self.backend,
            maxChunkSize: 2
        )

        #expect(result.programs.count == 2, "3 points at a cap of 2 must split into 2 chunks")
        #expect(Set(result.programs.map(\.entries.count)) == [1, 2])
        #expect(result.schemataPlan.entries.count == 3)
    }

    @Test("Points in different targets never share a chunk, even with the same operator")
    func differentTargetsNeverShareAChunk() throws {
        let source = "func flag() -> Bool { true }\n"
        let pointA = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "A.swift").first!
        let pointB = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "B.swift").first!
        let mutationPlan = makePlan(mutations: [pointA, pointB])
        let registry = try SchemataLowererRegistry()

        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["A.swift": Data(source.utf8), "B.swift": Data(source.utf8)],
            targetInfo: [
                "A.swift": [SchemataTargetInfo(
                    projectIdentity: "App.xcodeproj", target: "TargetA", module: "TargetA", product: "TargetA.framework"
                )],
                "B.swift": [SchemataTargetInfo(
                    projectIdentity: "App.xcodeproj", target: "TargetB", module: "TargetB", product: "TargetB.framework"
                )]
            ],
            backend: Self.backend
        )

        #expect(result.programs.count == 2)
        #expect(Set(result.programs.map(\.chunkID)).count == 2)
    }

    @Test("Two different projects with an identically-named target never share a chunk")
    func identicallyNamedTargetsInDifferentProjectsNeverShareAChunk() throws {
        let source = "func flag() -> Bool { true }\n"
        let pointA = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "A.swift").first!
        let pointB = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "B.swift").first!
        let mutationPlan = makePlan(mutations: [pointA, pointB])
        let registry = try SchemataLowererRegistry()

        // Same target/module/product name, deliberately — only
        // `projectIdentity` differs, which must still be enough to keep
        // these in separate chunks.
        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["A.swift": Data(source.utf8), "B.swift": Data(source.utf8)],
            targetInfo: [
                "A.swift": [SchemataTargetInfo(projectIdentity: "AppOne.xcodeproj", target: "App", module: "App", product: "App.app")],
                "B.swift": [SchemataTargetInfo(projectIdentity: "AppTwo.xcodeproj", target: "App", module: "App", product: "App.app")]
            ],
            backend: Self.backend
        )

        #expect(result.programs.count == 2, "identical target names in different projects must not be merged into one chunk")
        #expect(Set(result.programs.map(\.chunkID)).count == 2)
    }

    @Test("A non-positive maxChunkSize throws rather than silently producing one unbounded chunk")
    func nonPositiveMaxChunkSizeThrows() throws {
        let source = "func flag() -> Bool { true }\n"
        let points = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift")
        let mutationPlan = makePlan(mutations: points)
        let registry = try SchemataLowererRegistry()

        #expect(throws: SchemataChunkPlanningError.invalidMaxChunkSize(0)) {
            _ = try SchemataChunkPlanner.plan(
                mutationPlan: mutationPlan, registry: registry,
                sources: ["Widget.swift": Data(source.utf8)],
                targetInfo: ["Widget.swift": [Self.appTarget]],
                backend: Self.backend,
                maxChunkSize: 0
            )
        }
    }

    @Test("A missing source entry for a mutation's file throws")
    func missingSourceThrows() throws {
        let source = "let flag = true\n"
        let points = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift")
        let mutationPlan = makePlan(mutations: points)
        let registry = try SchemataLowererRegistry()

        #expect(throws: SchemataChunkPlanningError.missingSource(file: "Widget.swift")) {
            _ = try SchemataChunkPlanner.plan(
                mutationPlan: mutationPlan, registry: registry,
                sources: [:], targetInfo: ["Widget.swift": [Self.appTarget]], backend: Self.backend
            )
        }
    }

    @Test("A missing targetInfo entry for a mutation's file throws")
    func missingTargetInfoThrows() throws {
        let source = "let flag = true\n"
        let points = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift")
        let mutationPlan = makePlan(mutations: points)
        let registry = try SchemataLowererRegistry()

        #expect(throws: SchemataChunkPlanningError.missingTargetInfo(file: "Widget.swift")) {
            _ = try SchemataChunkPlanner.plan(
                mutationPlan: mutationPlan, registry: registry,
                sources: ["Widget.swift": Data(source.utf8)], targetInfo: [:], backend: Self.backend
            )
        }
    }

    @Test("The produced SchemataPlan round-trips through decodeAndValidate against its own MutationPlan")
    func producedPlanValidatesAgainstItsOwnMutationPlan() throws {
        let source = """
        let a = true
        let b = false
        """
        let points = try discoverPoints(source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift")
        let mutationPlan = makePlan(mutations: points)
        let registry = try SchemataLowererRegistry()

        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["Widget.swift": Data(source.utf8)],
            targetInfo: ["Widget.swift": [Self.appTarget]],
            backend: Self.backend
        )

        let data = try JSONEncoder().encode(result.schemataPlan)
        let validated = try SchemataPlan.decodeAndValidate(data, against: mutationPlan)
        #expect(validated.entries.count == mutationPlan.mutations.count)
    }

    @Test("A mixed plan (one eligible, one unsupported) still validates and accounts for both")
    func mixedPlanValidates() throws {
        let boolSource = "func flag() -> Bool { true }\n"
        let arithmeticSource = "func add(_ a: Int, _ b: Int) -> Int { a + b }\n"
        let boolPoint = try discoverPoints(
            boolSource, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift"
        ).first!
        let arithmeticPoint = try discoverPoints(
            arithmeticSource, operatorID: "swift.core.arithmetic-operator-replacement", relativePath: "Math.swift"
        ).first!
        let mutationPlan = makePlan(mutations: [boolPoint, arithmeticPoint])
        let registry = try SchemataLowererRegistry()

        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["Widget.swift": Data(boolSource.utf8), "Math.swift": Data(arithmeticSource.utf8)],
            targetInfo: ["Widget.swift": [Self.appTarget], "Math.swift": [Self.appTarget]],
            backend: Self.backend
        )

        #expect(result.schemataPlan.entries.filter(\.isEmbedded).count == 1)
        #expect(result.schemataPlan.entries.filter { !$0.isEmbedded }.count == 1)

        let data = try JSONEncoder().encode(result.schemataPlan)
        _ = try SchemataPlan.decodeAndValidate(data, against: mutationPlan)
    }
}

// Split into its own `@Suite` (rather than continuing
// `SchemataChunkPlannerTests`'s own body above) purely to keep
// `type_body_length` reviewable per declaration — still the same
// planner (`SchemataChunkPlanner.nonOverlappingWaves`) under test, no
// behavioral split.
@Suite("SchemataChunkPlanner: same-site overlapping candidates")
struct SchemataChunkPlannerSameSiteOverlapTests {
    private static let backend = SchemataChunkPlannerTests.backend
    private static let appTarget = SchemataChunkPlannerTests.appTarget

    private func discoverPoints(_ source: String, operatorID: String, relativePath: String) throws -> [MutationPoint] {
        try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID, relativePath: relativePath)
    }

    /// The real bug this suite exists to pin: `RelationalOperatorReplacementOperator`
    /// always offers *two* candidates per comparison (boundary and negation)
    /// anchored at the identical operator token, so they share a byte
    /// range. Before this test's fix, a naive size-capped `chunked(into:)`
    /// could place both in the same batch, `lower()` would throw
    /// `overlappingRewriteEnvelopes`, and — because `SchemataRunOrchestration
    /// .classify` treats *any* `SchemataChunkPlanner.plan` failure as
    /// "nothing is embeddable" — every mutation in the *entire* run would
    /// silently fall back to isolated, not just the two that actually
    /// conflicted. Confirmed against a real external project
    /// (swift-numerics) before this fix existed: the console read
    /// `"Schemata chunk planning failed (... claim overlapping byte
    /// ranges ...); every mutation will run in isolated mode this run."`
    @Test("Two same-site candidates (boundary + negation) never share a chunk, and every other point still embeds")
    func sameSiteOverlappingCandidatesSplitIntoSeparateChunks() throws {
        let source = "func isAtLeastTen(_ value: Int) -> Bool { value >= 10 }\n"
        let points = try discoverPoints(
            source, operatorID: RelationalOperatorReplacementOperator.descriptor.id, relativePath: "Widget.swift"
        )
        // The exact overlap: both anchor to the same `>=` token.
        #expect(points.count == 2)
        #expect(points[0].utf8Range == points[1].utf8Range)

        let mutationPlan = makePlan(mutations: points)
        let registry = try SchemataLowererRegistry(lowerers: [RelationalOperatorReplacementSchemataLowerer()])

        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["Widget.swift": Data(source.utf8)],
            targetInfo: ["Widget.swift": [Self.appTarget]],
            backend: Self.backend
        )

        #expect(result.programs.count == 2, "same-site candidates must land in two separate builds, not fail to lower at all")
        let fallenBack = result.schemataPlan.entries.filter { !$0.isEmbedded }
        #expect(fallenBack.isEmpty, "\(fallenBack.map(\.fallbackReason))")
        #expect(result.schemataPlan.entries.count == 2)

        let data = try JSONEncoder().encode(result.schemataPlan)
        _ = try SchemataPlan.decodeAndValidate(data, against: mutationPlan)
    }

    /// A same-site conflict must stay scoped to the two points that
    /// actually conflict — every *other*, unrelated point in the same
    /// group still gets embedded. Regression test for the exact failure
    /// mode described above: before the fix, one conflicting pair sank the
    /// entire group (or entire run), not just itself.
    @Test("A same-site conflict never drags down an unrelated mutation in the same group")
    func sameSiteConflictDoesNotAffectUnrelatedMutation() throws {
        let source = """
        func isAtLeastTen(_ value: Int) -> Bool { value >= 10 }
        func isPositive() -> Bool { true }
        """
        let relationalPoints = try discoverPoints(
            source, operatorID: RelationalOperatorReplacementOperator.descriptor.id, relativePath: "Widget.swift"
        )
        let boolPoints = try discoverPoints(
            source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Widget.swift"
        )
        #expect(relationalPoints.count == 2)
        #expect(boolPoints.count == 1)

        let mutationPlan = makePlan(mutations: relationalPoints + boolPoints)
        let registry = try SchemataLowererRegistry(lowerers: [
            BoolLiteralSchemataLowerer(), RelationalOperatorReplacementSchemataLowerer()
        ])

        let result = try SchemataChunkPlanner.plan(
            mutationPlan: mutationPlan, registry: registry,
            sources: ["Widget.swift": Data(source.utf8)],
            targetInfo: ["Widget.swift": [Self.appTarget]],
            backend: Self.backend
        )

        // All 3 points (the 2 conflicting relational candidates, split
        // across chunks, plus the 1 unrelated bool-literal point) embed —
        // nothing falls back.
        let fallenBack = result.schemataPlan.entries.filter { !$0.isEmbedded }
        #expect(fallenBack.isEmpty, "\(fallenBack.map(\.fallbackReason))")
        #expect(result.schemataPlan.entries.count == 3)
    }
}
