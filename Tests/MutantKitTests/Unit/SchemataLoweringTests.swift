import Foundation
import MutationModel
import Testing

/// Pins the S0 `SchemataEligibility`/`SchemataUnsupportedReason` contract
/// from ADR-0003 — the per-candidate (not per-operator) eligibility model
/// P0-1 requires, and its `Codable` round trip for `schemata-plan.json`.
@Suite("Schemata lowering eligibility contract")
struct SchemataLoweringTests {
    @Test("eligible reports isEligible true")
    func eligibleReportsTrue() {
        let eligibility = SchemataEligibility.eligible(
            loweringKind: .literalSelection,
            rewriteEnvelope: ByteRange(start: 10, end: 14),
            conflictKeys: []
        )
        #expect(eligibility.isEligible)
    }

    @Test("isolatedOnly reports isEligible false, for every unsupported reason")
    func isolatedOnlyReportsFalse() {
        let reasons: [SchemataUnsupportedReason] = [
            .resultBuilderBody,
            .typeVarianceUnproven,
            .processStartRequired,
            .operatorNotYetLowered(operatorID: "swift.core.ternary-branch-swap"),
            .structuralConflict(reason: "shares a parent expression with mut_b"),
            .platformUnsupported(reason: "UI test target")
        ]
        for reason in reasons {
            #expect(!SchemataEligibility.isolatedOnly(reason: reason).isEligible)
        }
    }

    @Test("SchemataEligibility round-trips through JSON for both cases and every unsupported reason")
    func eligibilityRoundTrips() throws {
        var cases: [SchemataEligibility] = [
            .eligible(
                loweringKind: .expressionTernary,
                rewriteEnvelope: ByteRange(start: 0, end: 9),
                conflictKeys: ["file.swift:0-9"]
            )
        ]
        cases += [
            SchemataUnsupportedReason.resultBuilderBody,
            .typeVarianceUnproven,
            .processStartRequired,
            .operatorNotYetLowered(operatorID: "swift.core.nil-coalescing-fallback"),
            .structuralConflict(reason: "overlapping rewrite envelope"),
            .platformUnsupported(reason: "app extension")
        ].map(SchemataEligibility.isolatedOnly)

        for original in cases {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(SchemataEligibility.self, from: data)
            #expect(decoded == original)
        }
    }

    @Test("SchemataLoweringKind's raw values are stable, since they persist in schemata-plan.json")
    func loweringKindRawValuesAreStable() {
        #expect(SchemataLoweringKind.literalSelection.rawValue == "literalSelection")
        #expect(SchemataLoweringKind.expressionTernary.rawValue == "expressionTernary")
        #expect(SchemataLoweringKind.statementBranch.rawValue == "statementBranch")
        #expect(SchemataLoweringKind.returnExpression.rawValue == "returnExpression")
        #expect(SchemataLoweringKind.declarationInitializer.rawValue == "declarationInitializer")
    }
}
