import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Mutation ID stability is the property the whole tool rests on.
///
/// A mutation is discovered in one process and applied in another, after the
/// syntax tree that found it has been thrown away and the file re-parsed from
/// bytes. If an ID is not reproducible from content alone, then the plan cannot
/// be trusted to name the same mutation twice — and a tool that cannot name a
/// mutation twice cannot honestly report on it.
@Suite("Mutation ID stability")
struct MutationIDTests {
    @Test("The same source discovered twice produces identical mutations")
    func discoveryIsDeterministic() throws {
        let source = try Fixture.text("RealisticViewModel")

        let first = try discover(source, path: "Sources/CartViewModel.swift")
        let second = try discover(source, path: "Sources/CartViewModel.swift")

        #expect(!first.isEmpty, "the fixture must produce mutations for this test to mean anything")
        #expect(first == second)
        #expect(first.map(\.id) == second.map(\.id))
    }

    /// The defect this tool exists to prevent: discovery held onto SwiftSyntax
    /// node identity, the file was re-parsed before applying, the identities no
    /// longer matched anything, so no mutation was ever applied — and the run
    /// still reported success. Nothing here may survive a parse boundary except
    /// content.
    @Test("Re-parsing the same bytes yields identical IDs")
    func reparsingTheSameBytesIsIdentity() throws {
        let source = try Fixture.text("RealisticViewModel")
        let path = "Sources/CartViewModel.swift"

        // Two entirely separate discovery runs: fresh operator instances, fresh
        // discovery object, fresh parse. Nothing is shared but the bytes.
        let fromMemory = try MutationDiscovery(operators: Operators.all)
            .discover(source: Data(source.utf8), relativePath: path)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reparse-\(UUID().uuidString).swift")
        try Data(source.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromDisk = try MutationDiscovery(operators: Operators.all)
            .discover(fileAt: url, relativePath: path)

        #expect(fromMemory.map(\.id) == fromDisk.map(\.id))
        // Not just the IDs: every anchor must be re-derived identically, or the
        // ID agreeing would be luck rather than design.
        #expect(fromMemory == fromDisk)
    }

    /// Occurrence index is scoped to the enclosing declaration rather than being
    /// a file-wide counter. A file-wide counter would renumber every mutation
    /// below an insertion point, invalidating IDs — and therefore caches, shards
    /// and baselines — on an edit that changed nothing about those mutations.
    @Test("Inserting an unrelated declaration does not change existing IDs")
    func unrelatedEditsDoNotDisturbIDs() throws {
        let before = """
        struct Cart {
            func isEmpty() -> Bool { return true }
            func hasItems() -> Bool { return false }
        }
        """
        let after = """
        struct Cart {
            func unrelated() -> Int { return 42 }
            func isEmpty() -> Bool { return true }
            func hasItems() -> Bool { return false }
        }
        """

        let beforePoints = try discover(before, path: "Sources/Cart.swift")
        let afterPoints = try discover(after, path: "Sources/Cart.swift")

        #expect(beforePoints.count == 2)
        #expect(Set(beforePoints.map(\.id)) == Set(afterPoints.map(\.id)))

        // The byte offsets *must* have moved — otherwise the insertion did not
        // happen where this test assumes and the assertion above proves nothing.
        let beforeRanges = Set(beforePoints.map(\.utf8Range))
        let afterRanges = Set(afterPoints.map(\.utf8Range))
        #expect(beforeRanges != afterRanges)
    }

    @Test("Changing the operator version changes the ID")
    func operatorVersionParticipatesInIdentity() throws {
        let inputs = (
            filePath: "Sources/Cart.swift",
            declaration: DeclarationIdentity(path: ["Cart", "isEmpty()"]),
            operatorID: "swift.core.bool-literal-inversion",
            fingerprint: ContentHash.shortDigest(of: "true"),
            occurrenceIndex: 0
        )

        let v1 = MutationID.compute(
            filePath: inputs.filePath,
            declaration: inputs.declaration,
            operatorID: inputs.operatorID,
            operatorVersion: 1,
            originalTokenFingerprint: inputs.fingerprint,
            occurrenceIndex: inputs.occurrenceIndex
        )
        let v2 = MutationID.compute(
            filePath: inputs.filePath,
            declaration: inputs.declaration,
            operatorID: inputs.operatorID,
            operatorVersion: 2,
            originalTokenFingerprint: inputs.fingerprint,
            occurrenceIndex: inputs.occurrenceIndex
        )

        // A changed operator produces a different mutation, so old IDs, caches
        // and golden results must not silently carry over.
        #expect(v1 != v2)
    }

    @Test("Every ID input changes the ID when it changes", arguments: [
        "filePath", "declaration", "operatorID", "fingerprint", "occurrenceIndex"
    ])
    func everyInputParticipatesInIdentity(changing input: String) {
        func id(
            filePath: String = "Sources/Cart.swift",
            declaration: DeclarationIdentity = DeclarationIdentity(path: ["Cart", "isEmpty()"]),
            operatorID: String = "swift.core.bool-literal-inversion",
            fingerprint: String = ContentHash.shortDigest(of: "true"),
            occurrenceIndex: Int = 0
        ) -> MutationID {
            MutationID.compute(
                filePath: filePath,
                declaration: declaration,
                operatorID: operatorID,
                operatorVersion: 1,
                originalTokenFingerprint: fingerprint,
                occurrenceIndex: occurrenceIndex
            )
        }

        let baseline = id()
        let changed = switch input {
        case "filePath": id(filePath: "Sources/Other.swift")
        case "declaration": id(declaration: DeclarationIdentity(path: ["Cart", "hasItems()"]))
        case "operatorID": id(operatorID: "swift.core.relational-operator-replacement")
        case "fingerprint": id(fingerprint: ContentHash.shortDigest(of: "false"))
        default: id(occurrenceIndex: 1)
        }

        #expect(baseline != changed)
    }

    /// `verify` recomputes every ID from the plan's own components and refuses
    /// the run if any of them fails to reproduce. That check is worthless unless
    /// discovery genuinely produces IDs that survive it.
    @Test("Every discovered point's ID recomputes from its own components")
    func discoveredIDsRecompute() throws {
        for name in ["RealisticViewModel", "UnicodeHeavy"] {
            let points = try discover(try Fixture.text(name), path: "Sources/\(name).swift")
            #expect(!points.isEmpty)
            for point in points {
                #expect(point.recomputedID == point.id, "\(point.displayLocation) does not reproduce its own ID")
            }
        }
    }

    @Test("IDs are unique within a file")
    func idsAreUniqueWithinAFile() throws {
        for name in ["RealisticViewModel", "UnicodeHeavy"] {
            let points = try discover(try Fixture.text(name), path: "Sources/\(name).swift")
            #expect(Set(points.map(\.id)).count == points.count, "\(name) produced colliding IDs")
        }
    }

    /// Two mutations of the same literal in the same declaration are told apart
    /// only by occurrence index — the one ID input that depends on position.
    @Test("Repeated identical literals in one declaration get distinct IDs")
    func repeatedLiteralsAreDistinguishedByOccurrence() throws {
        let source = """
        struct S {
            func pair() -> (Bool, Bool) {
                return (true, true)
            }
        }
        """

        let points = try discover(source, using: Operators.boolLiteral)

        #expect(points.count == 2)
        #expect(points.map(\.occurrenceIndex) == [0, 1])
        #expect(points[0].id != points[1].id)
        #expect(points[0].enclosingDeclaration == points[1].enclosingDeclaration)
    }

    /// Two mutations that differ only by which declaration encloses them must
    /// not collide, even though both are occurrence 0 of an identical literal.
    @Test("Identical literals in different declarations get distinct IDs")
    func identicalLiteralsInDifferentDeclarationsDoNotCollide() throws {
        let source = """
        struct S {
            func first() -> Bool { return true }
            func second() -> Bool { return true }
        }
        """

        let points = try discover(source, using: Operators.boolLiteral)

        #expect(points.count == 2)
        #expect(points.map(\.occurrenceIndex) == [0, 0])
        #expect(points[0].id != points[1].id)
    }

    /// One operator emits several candidates at one site (`<` becomes both `<=`
    /// and `>=`). Those share offset, operator and original text, so only a
    /// total ordering keeps their occurrence indices — and therefore their IDs —
    /// independent of the order the operator happened to emit them in.
    @Test("Multiple candidates at one site get stable, distinct IDs")
    func multipleCandidatesAtOneSiteAreOrderedDeterministically() throws {
        let source = "func lt(_ a: Int, _ b: Int) -> Bool { a < b }"

        let first = try discover(source, using: Operators.relational)
        let second = try discover(source, using: Operators.relational)

        #expect(first.count == 2)
        #expect(first[0].id != first[1].id)
        #expect(first.map(\.replacementText) == second.map(\.replacementText))
        #expect(first.map(\.id) == second.map(\.id))
    }
}
