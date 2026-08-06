import Foundation
import MutationModel
import SwiftCoreOperators
import Testing

/// Pins the `SchemataPlan`/`schemataPlanID` contract from ADR-0003: content-
/// addressed (never sequential/positional, never truncated), deterministic
/// regardless of input order, bound to a specific parent `MutationPlan`,
/// sensitive to every field of every entry, and validated on decode rather
/// than trusted as plain `Decodable` output.
@Suite("Schemata plan contract")
struct SchemataPlanTests {
    static func point(id: String) -> MutationPoint {
        MutationPoint(
            id: MutationID(rawValue: id),
            file: "Sources/Widgets/Widget.swift",
            enclosingDeclaration: DeclarationIdentity(path: ["Widget", "isEnabled"]),
            operatorID: BoolLiteralInversionOperator.descriptor.id,
            operatorVersion: 1,
            occurrenceIndex: 0,
            utf8Range: ByteRange(start: 0, end: 4),
            originalText: "true",
            replacementText: "false",
            prefixTokenFingerprint: "prefix",
            suffixTokenFingerprint: "suffix",
            sourceFileHash: "sha256:source",
            expectedSyntaxKind: "BooleanLiteralExprSyntax",
            confidence: .high,
            executionMode: .isolated,
            line: 1,
            column: 1
        )
    }

    static func entry(
        id: String,
        chunk: String? = "chunk-1",
        localIndex: UInt32? = 1,
        sourceEmbeddingID: String? = "embedding-1",
        lowererVersion: Int = 1
    ) -> SchemataPlanEntry {
        let placement: SchemataPlacement = if let chunk, let localIndex, let sourceEmbeddingID {
            .embedded(placements: [
                SchemataEmbeddedPlacement(
                    chunkID: chunk,
                    selectorToken: SchemataSelectorToken(namespace: 42, localIndex: localIndex),
                    sourceEmbeddingID: sourceEmbeddingID,
                    lowererID: "core-expression-lowerer",
                    lowererVersion: lowererVersion,
                    projectIdentity: "Widgets.xcodeproj",
                    target: "Widgets",
                    module: "Widgets",
                    product: "Widgets.framework",
                    expectedImages: ["Widgets"]
                )
            ])
        } else {
            .isolatedFallback(reason: .operatorNotYetLowered(operatorID: "swift.core.ternary-branch-swap"))
        }
        return SchemataPlanEntry(
            mutationID: MutationID(rawValue: id),
            placement: placement,
            conflictGroup: nil,
            projectIdentity: "Widgets.xcodeproj",
            target: "Widgets",
            module: "Widgets",
            product: "Widgets.framework"
        )
    }

    static func mutationPlan(ids: [String]) -> MutationPlan {
        makePlan(mutations: ids.map(point(id:)))
    }

    static func plan(mutationPlan: MutationPlan, entries: [SchemataPlanEntry]) -> SchemataPlan {
        SchemataPlan(
            mutationPlan: mutationPlan,
            backendID: "swiftpm-process-executor",
            backendVersion: 1,
            toolchainHash: "sha256:toolchain",
            buildArgumentsHash: "sha256:args",
            entries: entries
        )
    }

    // MARK: - Construction

    @Test("entries are sorted by MutationID regardless of construction order")
    func entriesAreSortedByMutationID() {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a", "mut_b", "mut_c"])
        let unsorted = [Self.entry(id: "mut_c"), Self.entry(id: "mut_a"), Self.entry(id: "mut_b")]
        let result = Self.plan(mutationPlan: mutationPlan, entries: unsorted)
        #expect(result.entries.map(\.mutationID.rawValue) == ["mut_a", "mut_b", "mut_c"])
    }

    @Test("schemataPlanID is identical for the identical input set regardless of entry order")
    func schemataPlanIDIsOrderIndependent() {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a", "mut_b"])
        let a = Self.plan(mutationPlan: mutationPlan, entries: [Self.entry(id: "mut_a"), Self.entry(id: "mut_b")])
        let b = Self.plan(mutationPlan: mutationPlan, entries: [Self.entry(id: "mut_b"), Self.entry(id: "mut_a")])
        #expect(a.schemataPlanID == b.schemataPlanID)
    }

    @Test("schemataPlanID changes when the mutation set changes")
    func schemataPlanIDChangesWithMutationSet() {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a", "mut_b"])
        let a = Self.plan(mutationPlan: mutationPlan, entries: [Self.entry(id: "mut_a")])
        let b = Self.plan(mutationPlan: mutationPlan, entries: [Self.entry(id: "mut_a"), Self.entry(id: "mut_b")])
        #expect(a.schemataPlanID != b.schemataPlanID)
    }

    @Test("schemataPlanID changes when a chunk assignment changes, even with the identical mutation set")
    func schemataPlanIDChangesWithChunkAssignment() {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a"])
        let a = Self.plan(mutationPlan: mutationPlan, entries: [Self.entry(id: "mut_a", chunk: "chunk-1")])
        let b = Self.plan(mutationPlan: mutationPlan, entries: [Self.entry(id: "mut_a", chunk: "chunk-2")])
        #expect(a.schemataPlanID != b.schemataPlanID)
    }

    @Test("schemataPlanID changes when the lowerer version changes, even with identical mutation IDs and chunks")
    func schemataPlanIDChangesWithLowererVersion() {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a"])
        let a = Self.plan(mutationPlan: mutationPlan, entries: [Self.entry(id: "mut_a", lowererVersion: 1)])
        let b = Self.plan(mutationPlan: mutationPlan, entries: [Self.entry(id: "mut_a", lowererVersion: 2)])
        #expect(a.schemataPlanID != b.schemataPlanID)
    }

    @Test("schemataPlanID changes when the toolchain hash changes, even with an identical entry set")
    func schemataPlanIDChangesWithToolchain() {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a"])
        let entries = [Self.entry(id: "mut_a")]
        let a = SchemataPlan(
            mutationPlan: mutationPlan, backendID: "swiftpm-process-executor", backendVersion: 1,
            toolchainHash: "sha256:toolchain-a", buildArgumentsHash: "sha256:args", entries: entries
        )
        let b = SchemataPlan(
            mutationPlan: mutationPlan, backendID: "swiftpm-process-executor", backendVersion: 1,
            toolchainHash: "sha256:toolchain-b", buildArgumentsHash: "sha256:args", entries: entries
        )
        #expect(a.schemataPlanID != b.schemataPlanID)
    }

    @Test("schemataPlanID changes when only a fallback entry's reason changes")
    func schemataPlanIDChangesWithFallbackReason() {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a"])
        let resultBuilderFallback = SchemataPlanEntry(
            mutationID: MutationID(rawValue: "mut_a"),
            placement: .isolatedFallback(reason: .resultBuilderBody),
            conflictGroup: nil, projectIdentity: "Widgets.xcodeproj",
            target: "Widgets", module: "Widgets", product: "Widgets.framework"
        )
        let platformFallback = SchemataPlanEntry(
            mutationID: MutationID(rawValue: "mut_a"),
            placement: .isolatedFallback(reason: .platformUnsupported(reason: "UI test target")),
            conflictGroup: nil, projectIdentity: "Widgets.xcodeproj",
            target: "Widgets", module: "Widgets", product: "Widgets.framework"
        )
        let a = Self.plan(mutationPlan: mutationPlan, entries: [resultBuilderFallback])
        let b = Self.plan(mutationPlan: mutationPlan, entries: [platformFallback])
        #expect(a.schemataPlanID != b.schemataPlanID, "distinct fallback reasons must not collide on plan identity")
    }

    @Test("schemataPlanID is a full, untruncated SHA-256, not a short human-facing digest")
    func schemataPlanIDIsFullHash() {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a"])
        let plan = Self.plan(mutationPlan: mutationPlan, entries: [Self.entry(id: "mut_a")])
        #expect(plan.schemataPlanID.hasPrefix("sha256:"))
        #expect(plan.schemataPlanID.count == "sha256:".count + 64)
    }

    @Test("an isolated-fallback entry carries its fallback reason, and no embedding identity")
    func fallbackEntryCarriesReason() {
        let entry = Self.entry(id: "mut_a", chunk: nil, localIndex: nil, sourceEmbeddingID: nil)
        #expect(!entry.isEmbedded)
        #expect(entry.fallbackReason != nil)
        #expect(entry.sourceEmbeddingID == nil)
        #expect(entry.selectorToken == nil)
    }

    @Test("an embedded entry is reported as embedded, with no fallback reason")
    func embeddedEntryIsReportedAsEmbedded() {
        let entry = Self.entry(id: "mut_a")
        #expect(entry.isEmbedded)
        #expect(entry.fallbackReason == nil)
        #expect(entry.selectorToken != nil)
    }

    @Test("two entries in different chunks with identical mutation content still carry distinct embedding IDs")
    func distinctChunksCarryDistinctEmbeddingIDs() {
        let a = Self.entry(id: "mut_a", chunk: "chunk-1", sourceEmbeddingID: "embedding-1")
        let b = Self.entry(id: "mut_a", chunk: "chunk-2", sourceEmbeddingID: "embedding-2")
        #expect(a.sourceEmbeddingID != b.sourceEmbeddingID)
    }

    @Test("SchemataPlan round-trips through JSON")
    func planRoundTrips() throws {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a", "mut_b"])
        let original = Self.plan(mutationPlan: mutationPlan, entries: [
            Self.entry(id: "mut_a"),
            Self.entry(id: "mut_b", chunk: nil, localIndex: nil, sourceEmbeddingID: nil)
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SchemataPlan.self, from: data)
        #expect(decoded.schemataPlanID == original.schemataPlanID)
        #expect(decoded.entries == original.entries)
        #expect(decoded.schemaVersion == SchemaVersion.schemataPlan)
    }

    // MARK: - Decoding a `SchemataSelectorToken` with a reserved localIndex

    @Test("decoding a selector token with localIndex 0 fails, even though 0 is a valid UInt32")
    func decodingReservedSentinelLocalIndexFails() throws {
        let json = """
        {"namespace": 42, "localIndex": 0}
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SchemataSelectorToken.self, from: Data(json.utf8))
        }
    }

    // MARK: - decodeAndValidate

    @Test("decodeAndValidate accepts a plan that genuinely matches its parent MutationPlan")
    func decodeAndValidateAcceptsMatchingPlan() throws {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a"])
        let original = Self.plan(mutationPlan: mutationPlan, entries: [Self.entry(id: "mut_a")])
        let data = try JSONEncoder().encode(original)
        let validated = try SchemataPlan.decodeAndValidate(data, against: mutationPlan)
        #expect(validated.schemataPlanID == original.schemataPlanID)
    }

    @Test("decodeAndValidate rejects a plan whose mutationPlanID does not match the given plan")
    func decodeAndValidateRejectsWrongMutationPlanID() throws {
        let mutationPlanA = Self.mutationPlan(ids: ["mut_a"])
        // A distinct, explicitly differently-IDed plan — `makePlan` always
        // stamps the same fixed `planID`, so this test constructs one
        // directly to actually exercise a planID mismatch.
        let mutationPlanB = MutationPlan(
            planID: "plan-0002-distinct",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projectRoot: "/tmp/project",
            toolchain: makeToolchain(),
            configurationHash: Configuration().configurationHash,
            sourceFileHashes: [:],
            mutations: [Self.point(id: "mut_a")],
            skipped: [],
            operators: [BoolLiteralInversionOperator.descriptor]
        )
        let original = Self.plan(mutationPlan: mutationPlanA, entries: [Self.entry(id: "mut_a")])
        let data = try JSONEncoder().encode(original)

        #expect(throws: SchemataPlan.ValidationError.self) {
            _ = try SchemataPlan.decodeAndValidate(data, against: mutationPlanB)
        }
    }

    @Test("decodeAndValidate rejects a hand-edited plan whose schemataPlanID no longer matches its contents")
    func decodeAndValidateRejectsTamperedID() throws {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a"])
        let original = Self.plan(mutationPlan: mutationPlan, entries: [Self.entry(id: "mut_a")])
        var json = try #require(String(data: JSONEncoder().encode(original), encoding: .utf8))
        json = json.replacingOccurrences(of: original.schemataPlanID, with: "sha256:" + String(repeating: "0", count: 64))

        #expect(throws: SchemataPlan.ValidationError.self) {
            _ = try SchemataPlan.decodeAndValidate(Data(json.utf8), against: mutationPlan)
        }
    }

    @Test("decodeAndValidate rejects a plan missing an entry for one of the parent plan's mutations")
    func decodeAndValidateRejectsMissingEntry() throws {
        let mutationPlan = Self.mutationPlan(ids: ["mut_a", "mut_b"])
        // Only one entry for a two-mutation plan — mut_b has no entry at all.
        let malformed = SchemataPlan(
            mutationPlan: mutationPlan, backendID: "swiftpm-process-executor", backendVersion: 1,
            toolchainHash: "sha256:toolchain", buildArgumentsHash: "sha256:args",
            entries: [Self.entry(id: "mut_a")]
        )
        let data = try JSONEncoder().encode(malformed)

        #expect(throws: SchemataPlan.ValidationError.self) {
            _ = try SchemataPlan.decodeAndValidate(data, against: mutationPlan)
        }
    }
}
