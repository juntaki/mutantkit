import Foundation
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Pins `SchemataLowererRegistry`: routes an operator to the one lowerer
/// that claims it, and refuses to construct at all when two lowerers would
/// disagree about who owns a `lowererID` or an operator.
@Suite("SchemataLowererRegistry")
struct SchemataLowererRegistryTests {
    @Test("The built-in registry routes bool-literal-inversion to BoolLiteralSchemataLowerer")
    func routesBuiltInOperator() throws {
        let registry = try SchemataLowererRegistry()
        let lowerer = registry.lowerer(forOperatorID: BoolLiteralInversionOperator.descriptor.id)
        #expect(lowerer?.descriptor.lowererID == BoolLiteralSchemataLowerer.lowererID)
    }

    @Test("The built-in registry routes relational-operator-replacement to RelationalOperatorReplacementSchemataLowerer")
    func routesRelationalOperator() throws {
        let registry = try SchemataLowererRegistry()
        let lowerer = registry.lowerer(forOperatorID: RelationalOperatorReplacementOperator.descriptor.id)
        #expect(lowerer?.descriptor.lowererID == RelationalOperatorReplacementSchemataLowerer.lowererID)
    }

    @Test("The built-in registry routes logical-connector-replacement to LogicalConnectorReplacementSchemataLowerer")
    func routesLogicalConnectorOperator() throws {
        let registry = try SchemataLowererRegistry()
        let lowerer = registry.lowerer(forOperatorID: LogicalConnectorReplacementOperator.descriptor.id)
        #expect(lowerer?.descriptor.lowererID == LogicalConnectorReplacementSchemataLowerer.lowererID)
    }

    @Test("An operator no lowerer supports routes to nil")
    func unsupportedOperatorRoutesToNil() throws {
        let registry = try SchemataLowererRegistry()
        #expect(registry.lowerer(forOperatorID: "swift.core.arithmetic-operator-replacement") == nil)
    }

    /// ADR-0006 Stage 3: the lowerer registry is the *entire* per-operator
    /// scoring gate — no separate `SchemataOperatorGate` type exists.
    /// `SchemataChunkPlanner` reads `registry.lowerer(forOperatorID:) == nil`
    /// as `.isolatedFallback(reason: .operatorNotYetLowered)`, so this one
    /// assertion is what makes every operator besides bool-literal-inversion
    /// and relational-operator-replacement fall back to isolated mode,
    /// permanently, until a real `SchemataLowerer` is registered and proven
    /// for it. If this test ever needs to change, a new operator's schemata
    /// scoring is being turned on — that must never happen silently as a
    /// side effect of an unrelated change to `SchemataLowererRegistry.builtIn`.
    @Test("Exactly three operators are schemata-eligible: bool-literal-inversion, relational-operator-replacement, logical-connector-replacement")
    func exactlyThreeOperatorsAreEligible() throws {
        let registry = try SchemataLowererRegistry()
        let eligible = MutationRegistry.builtIn.filter { registry.lowerer(forOperatorID: $0.descriptor.id) != nil }
        #expect(
            Set(eligible.map(\.descriptor.id)) == [
                BoolLiteralInversionOperator.descriptor.id, RelationalOperatorReplacementOperator.descriptor.id,
                LogicalConnectorReplacementOperator.descriptor.id
            ],
            "only bool-literal-inversion, relational-operator-replacement, and logical-connector-replacement may score under schemata mode today"
        )
    }

    /// The complement of the above, pinned separately rather than inferred:
    /// every *other* registered operator — not just one arbitrary example —
    /// routes to `nil` (isolated fallback), so a new operator silently
    /// picking up schemata eligibility (e.g. by accidentally matching an
    /// existing `lowererID`'s `supportedOperatorIDs` glob, if one were ever
    /// introduced) would fail this test even if `exactlyTwoOperatorsAreEligible`
    /// above somehow still passed.
    @Test("Every operator other than bool-literal-inversion/relational-operator-replacement/logical-connector-replacement always routes to isolated fallback")
    func everyOtherOperatorRoutesToIsolatedFallback() throws {
        let registry = try SchemataLowererRegistry()
        let others = MutationRegistry.builtIn.filter {
            $0.descriptor.id != BoolLiteralInversionOperator.descriptor.id
                && $0.descriptor.id != RelationalOperatorReplacementOperator.descriptor.id
                && $0.descriptor.id != LogicalConnectorReplacementOperator.descriptor.id
        }
        #expect(!others.isEmpty, "this test is meaningless if there is nothing else registered to check")
        for other in others {
            #expect(
                registry.lowerer(forOperatorID: other.descriptor.id) == nil,
                "\(other.descriptor.id) must have no registered schemata lowerer"
            )
        }
    }

    private struct StubLowerer: SchemataLowerer {
        let descriptor: SchemataLowererDescriptor

        func analyze(_ point: MutationPoint, source: Data) -> SchemataEligibility {
            .isolatedOnly(reason: .operatorNotYetLowered(operatorID: point.operatorID))
        }

        func lower(_ chunk: SchemataChunk, sources: [SchemataSourceFile]) throws -> SchemataProgram {
            SchemataProgram(chunkID: chunk.chunkID, sourceEmbeddingID: "stub", loweredSources: sources, entries: [])
        }
    }

    @Test("Two lowerers claiming the same lowererID make construction throw")
    func duplicateLowererIDThrows() throws {
        let descriptor = SchemataLowererDescriptor(
            lowererID: "dup", lowererVersion: 1, runtimeABIVersion: 1, supportedOperatorIDs: ["op.a"]
        )
        let other = SchemataLowererDescriptor(
            lowererID: "dup", lowererVersion: 1, runtimeABIVersion: 1, supportedOperatorIDs: ["op.b"]
        )
        #expect(throws: SchemataLowererRegistry.RegistrationError.duplicateLowererID("dup")) {
            _ = try SchemataLowererRegistry(lowerers: [StubLowerer(descriptor: descriptor), StubLowerer(descriptor: other)])
        }
    }

    @Test("Two lowerers both claiming the same operator ID make construction throw")
    func ambiguousOperatorRegistrationThrows() throws {
        let first = SchemataLowererDescriptor(
            lowererID: "first", lowererVersion: 1, runtimeABIVersion: 1, supportedOperatorIDs: ["op.shared"]
        )
        let second = SchemataLowererDescriptor(
            lowererID: "second", lowererVersion: 1, runtimeABIVersion: 1, supportedOperatorIDs: ["op.shared"]
        )
        do {
            _ = try SchemataLowererRegistry(lowerers: [StubLowerer(descriptor: first), StubLowerer(descriptor: second)])
            Issue.record("expected construction to throw")
        } catch let error as SchemataLowererRegistry.RegistrationError {
            #expect(error == .ambiguousOperatorRegistration(operatorID: "op.shared", first: "first", second: "second"))
        }
    }
}
