import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Regression: **discovery re-parses and applies nothing, yet the run exits
/// successfully.**
///
/// The failure being reproduced: mutations were located during discovery and
/// remembered by SwiftSyntax node identity. At apply time the file was parsed
/// again, producing a new tree whose nodes were different objects, so the
/// remembered identities matched nothing. No mutation was applied, every mutant
/// was recorded as survived-or-similar, and the run reported success against a
/// score that measured nothing at all.
///
/// The structural fix is that a `MutationPoint` is self-contained: byte range,
/// original text, fingerprints, declaration and file hash are copied out of the
/// tree at discovery and the tree is dropped. These tests hold that line by
/// forcing the full journey — discover, serialize, drop everything, re-read,
/// re-parse, apply — and demanding that every planned mutation still lands.
@Suite("Regression: plan survives a full re-parse round trip")
struct ReparseRoundTripTests {
    /// The whole journey a mutation makes in a real run, across what would be a
    /// process boundary, ending in the assertion the original defect failed:
    /// every planned mutation is actually applied.
    @Test("Every planned mutation still applies after a JSON round trip and a fresh parse")
    func planRoundTripsThroughJSONAndStillApplies() throws {
        let source = try Fixture.text("RealisticViewModel")
        let path = "Sources/CartViewModel.swift"
        let data = Data(source.utf8)

        // 1. Discover. The tree does not outlive this call.
        let discovered = try discover(source, path: path)
        #expect(!discovered.isEmpty)

        // 2. Write the plan to bytes, then throw away everything in memory.
        let planData = try makePlan(
            mutations: discovered,
            sourceFileHashes: [path: ContentHash.of(data)]
        ).encoded()

        // 3. A different process reads the plan back. It has no tree, no
        //    discovery state, and no memory of step 1.
        let plan = try MutationPlan.decode(from: planData)
        #expect(IntegrityChecker.validatePlan(plan).isEmpty)

        // 4. Re-read the file from bytes and apply every mutation at full depth,
        //    which re-parses the source from scratch for each one.
        var applied = 0
        for point in plan.mutations {
            let result = try MutationApplication.apply(point, to: data, depth: .full)
            #expect(result.evidence.provesSourceApplication)
            #expect(parsesWithoutError(result.mutatedSource))
            applied += 1
        }

        // The assertion the original defect could not satisfy: planned == applied.
        #expect(applied == plan.mutations.count)
        #expect(applied == discovered.count)
    }

    /// A plan is only useful if it survives leaving the machine that made it.
    /// The IDs must reproduce from the file alone, with nothing carried over.
    @Test("A plan decoded from bytes names the same mutations a fresh discovery finds")
    func decodedPlanAgreesWithFreshDiscovery() throws {
        let source = try Fixture.text("RealisticViewModel")
        let path = "Sources/CartViewModel.swift"

        let planData = try makePlan(mutations: try discover(source, path: path)).encoded()
        let plan = try MutationPlan.decode(from: planData)

        // A completely independent discovery run, as if on another machine.
        let rediscovered = try discover(source, path: path)

        #expect(plan.mutations.map(\.id) == rediscovered.map(\.id).sorted())
        #expect(Set(plan.mutations) == Set(rediscovered))
    }

    /// Anchors are content, not identity — so a fresh parse of identical bytes
    /// necessarily agrees with discovery. This is the property that makes
    /// re-parsing safe here where it was fatal before.
    @Test("Full-depth anchors re-derive from a fresh parse")
    func anchorsSurviveAFreshParse() throws {
        let source = try Fixture.text("UnicodeHeavy")
        let data = Data(source.utf8)
        let points = try discover(source, path: "Sources/UnicodeHeavy.swift")

        #expect(!points.isEmpty)
        for point in points {
            // `.full` throws away nothing and re-parses; it must still agree.
            let verification = SourceAnchorVerifier.verify(point, against: data, depth: .full)
            #expect(verification.isValid, "\(point.displayLocation): \(verification.diagnosis)")
        }
    }

    /// If applying silently did nothing, the mutated source would equal the
    /// original and the run would still "succeed". It must not be possible for
    /// that to go unnoticed.
    @Test("An applied mutation always changes the bytes")
    func applyingAlwaysChangesTheSource() throws {
        let source = try Fixture.text("RealisticViewModel")
        let data = Data(source.utf8)

        for point in try discover(source, path: "Sources/CartViewModel.swift") {
            let applied = try MutationApplication.apply(point, to: data)

            #expect(applied.mutatedSource != data)
            #expect(applied.evidence.sourceBeforeHash != applied.evidence.sourceAfterHash)
        }
    }
}
