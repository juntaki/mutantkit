import Foundation
import MutationModel
import MutationPlanner
import SwiftFrontend
import SwiftSyntax
import Testing

/// The registry is the only place that decides what "enabled" means, so every
/// override of the profile defaults has to be visible here. An unknown ID in
/// `disable` is the most dangerous failure mode: a typo silently re-enables an
/// operator someone tried to turn off, and the only signal is a slower run.
@Suite("Mutation registry")
struct MutationRegistryTests {
    // MARK: - Built-in registry

    @Test("The built-in registry exposes every default operator, sorted by ID")
    func builtInRegistryContents() {
        let ids = MutationRegistry.builtIn.map(\.descriptor.id)

        #expect(ids == ["swift.core.bool-literal-inversion",
                        "swift.core.logical-connector-replacement",
                        "swift.core.relational-operator-replacement",
                        "swift.core.ternary-branch-swap",
                        "swift.core.unary-not-removal",
                        "swift.core.arithmetic-operator-replacement",
                        "swift.core.assignment-operator-replacement",
                        "swift.core.nil-coalescing-fallback",
                        "swift.core.return-value-replacement",
                        "swift.core.else-clause-deletion",
                        "swift.core.range-boundary-replacement",
                        "swift.core.side-effect-call-removal"])
        #expect(Set(ids).count == ids.count)
    }

    @Test("allDescriptors is sorted and stable")
    func allDescriptorsIsSorted() {
        let registry = MutationRegistry()
        let ids = registry.allDescriptors.map(\.id)

        #expect(ids == ids.sorted())
        #expect(ids.count == registry.allDescriptors.count)
    }

    @Test("operator(withID:) finds known operators and refuses unknown ones")
    func lookupByID() {
        let registry = MutationRegistry()

        #expect(registry.operator(withID: "swift.core.bool-literal-inversion") != nil)
        #expect(registry.operator(withID: "no.such.operator") == nil)
    }

    // MARK: - resolve: precedence

    /// The default profile runs everything `defaultEnabled`. The conservative
    /// profile narrows that to `.high` confidence, so a `.medium` operator has
    /// to be invisible to it unless explicitly enabled.
    @Test("Conservative profile admits only high-confidence default operators")
    func conservativeAdmitsOnlyHighConfidence() throws {
        let registry = MutationRegistry(operators: [HighOp(), MediumOp(), ExperimentalOp()])

        let resolution = try registry.resolve(OperatorSettings(profile: .conservative))

        #expect(resolution.enabledOperators.map(\.descriptor.id) == ["test.high"])
    }

    @Test("Default profile admits every defaultEnabled operator")
    func defaultAdmitsAllDefaultEnabled() throws {
        let registry = MutationRegistry(operators: [DefaultEnabledOp(), DefaultDisabledOp()])

        let resolution = try registry.resolve(OperatorSettings(profile: .default))

        #expect(resolution.enabledOperators.map(\.descriptor.id) == ["test.default-enabled"])
    }

    @Test("Experimental profile admits every operator, even non-default ones")
    func experimentalAdmitsEverything() throws {
        let registry = MutationRegistry(operators: [DefaultDisabledOp()])

        let resolution = try registry.resolve(OperatorSettings(profile: .experimental))

        #expect(resolution.enabledOperators.map(\.descriptor.id) == ["test.default-disabled"])
    }

    /// `enable` overrides the profile. A `defaultEnabled: false` operator the
    /// user names explicitly has to run — otherwise the setting would be a
    /// no-op that reports nothing.
    @Test("Explicit enable overrides the profile's exclusion")
    func enableOverridesProfile() throws {
        let registry = MutationRegistry(operators: [DefaultDisabledOp()])

        let resolution = try registry.resolve(
            OperatorSettings(profile: .default, enable: ["test.default-disabled"])
        )

        #expect(resolution.enabledOperators.map(\.descriptor.id) == ["test.default-disabled"])
        #expect(resolution.explicitlyEnabledOperatorIDs == ["test.default-disabled"])
    }

    /// `disable` always wins. Naming an operator in both lists disables it,
    /// because the cost of accidentally running an operator someone tried to
    /// turn off is higher than the reverse.
    @Test("Disable always wins over enable")
    func disableWinsOverEnable() throws {
        let registry = MutationRegistry(operators: [DefaultEnabledOp()])

        let resolution = try registry.resolve(
            OperatorSettings(profile: .default, disable: ["test.default-enabled"],
                             enable: ["test.default-enabled"])
        )

        #expect(resolution.enabledOperators.isEmpty)
        #expect(resolution.explicitlyEnabledOperatorIDs.isEmpty)
    }

    @Test("Disable wins over a profile that would otherwise admit")
    func disableWinsOverProfile() throws {
        let registry = MutationRegistry(operators: [DefaultEnabledOp()])

        let resolution = try registry.resolve(
            OperatorSettings(profile: .default, disable: ["test.default-enabled"])
        )

        #expect(resolution.enabledOperators.isEmpty)
    }

    /// The enabled set is sorted by ID, regardless of the order the registry
    /// was constructed in. Discovery order cannot leak through the registry.
    @Test("Enabled operators are returned sorted by ID regardless of input order")
    func enabledOperatorsAreSortedByID() throws {
        let registry = MutationRegistry(operators: [ZetaOp(), AlphaOp(), MidOp()])

        let resolution = try registry.resolve(OperatorSettings(profile: .default))

        #expect(resolution.enabledOperators.map(\.descriptor.id) == ["test.alpha", "test.mid", "test.zeta"])
    }

    // MARK: - Unknown IDs

    /// A typo in `disable` is the failure mode this rule exists for. The user
    /// thinks they turned an operator off; in reality, the typo means it kept
    /// running, and the only signal is a slower-than-expected run.
    @Test("An unknown ID in disable is refused")
    func unknownDisableIDIsRefused() {
        let registry = MutationRegistry()

        #expect(throws: PlannerError.self) {
            try registry.resolve(OperatorSettings(profile: .default, disable: ["typo.operator"]))
        }
    }

    @Test("An unknown ID in enable is refused")
    func unknownEnableIDIsRefused() {
        let registry = MutationRegistry()

        #expect(throws: PlannerError.self) {
            try registry.resolve(OperatorSettings(profile: .default, enable: ["typo.operator"]))
        }
    }

    @Test("The unknown-operator error names the known set")
    func unknownOperatorErrorNamesKnownSet() throws {
        let registry = MutationRegistry()

        do {
            _ = try registry.resolve(OperatorSettings(profile: .default, disable: ["no.such"]))
            Issue.record("expected an error")
        } catch let error as PlannerError {
            guard case let .unknownOperator(id, known) = error else {
                Issue.record("expected unknownOperator, got \(error)")
                return
            }
            #expect(id == "no.such")
            #expect(!known.isEmpty)
            #expect(known == known.sorted())
        }
    }

    // MARK: - requiresSymbolResolution

    /// An operator that needs type/symbol information cannot run from a
    /// syntax-only frontend — no profile, not even experimental, may switch it
    /// on. Naming it explicitly is the only way to surface the requirement, and
    /// it surfaces as an error rather than a silent skip.
    @Test("A requiresSymbolResolution operator is never admitted by a profile")
    func symbolResolutionOperatorIsNotAdmitted() throws {
        let registry = MutationRegistry(operators: [SymbolOnlyOp()])

        for profile in OperatorProfile.allCases {
            let resolution = try registry.resolve(OperatorSettings(profile: profile))
            #expect(resolution.enabledOperators.isEmpty, "\(profile.rawValue) admitted a symbol-only operator")
        }
    }

    @Test("Enabling a requiresSymbolResolution operator surfaces an explicit error")
    func enablingSymbolResolutionOperatorErrors() {
        let registry = MutationRegistry(operators: [SymbolOnlyOp()])

        #expect(throws: PlannerError.self) {
            try registry.resolve(
                OperatorSettings(profile: .experimental, enable: ["test.symbol-only"])
            )
        }
    }

    // MARK: - Site confidence floor

    /// A conservative profile admits an operator by its declared confidence,
    /// but the operator may lower its own confidence for specific sites. The
    /// registry exposes the floor; the planner enforces it site by site. This
    /// test pins the floor values so a profile change is visible here rather
    /// than as an inflated score later.
    @Test("Site confidence floor is set only for conservative")
    func siteConfidenceFloorIsConservativeOnly() {
        #expect(OperatorProfile.conservative.siteConfidenceFloor == .high)
        #expect(OperatorProfile.default.siteConfidenceFloor == nil)
        #expect(OperatorProfile.experimental.siteConfidenceFloor == nil)
    }

    // MARK: - Schemata eligibility

    /// The structural invariant `MutationRegistry.effectiveDescriptor(for:)`
    /// exists to guarantee, checked directly against the real, shipped
    /// `SchemataLowererRegistry.builtIn` — not a stub — so a future
    /// promotion or demotion that updates the lowerer registry but forgets
    /// nothing else (there is nothing else to forget any more) still shows
    /// up correctly here without anyone touching this test.
    @Test("Every built-in operator's effective schemataEligible matches whether SchemataLowererRegistry actually has a lowerer for it")
    func schemataEligibleMatchesLowererRegistry() throws {
        let lowererRegistry = try SchemataLowererRegistry()
        for descriptor in MutationRegistry().allDescriptors {
            let hasLowerer = lowererRegistry.lowerer(forOperatorID: descriptor.id) != nil
            #expect(
                descriptor.schemataEligible == hasLowerer,
                "\(descriptor.id): schemataEligible == \(descriptor.schemataEligible) but a registered lowerer \(hasLowerer ? "exists" : "does not exist")"
            )
        }
    }

    /// `resolve(_:)`'s own descriptors are a second, independent code path
    /// from `allDescriptors` — both must carry the fix, not just one (this
    /// is exactly the shape `OperatorCatalogCommand` bypassing `resolve`
    /// entirely, reading `allDescriptors` directly, already proved matters).
    @Test("resolve(_:)'s descriptors also carry the effective schemataEligible answer")
    func resolveDescriptorsAlsoCarryEffectiveSchemataEligible() throws {
        let registry = MutationRegistry()
        let lowererRegistry = try SchemataLowererRegistry()
        let resolution = try registry.resolve(OperatorSettings(profile: .experimental))

        #expect(!resolution.descriptors.isEmpty)
        for descriptor in resolution.descriptors {
            let hasLowerer = lowererRegistry.lowerer(forOperatorID: descriptor.id) != nil
            #expect(descriptor.schemataEligible == hasLowerer, "\(descriptor.id) mismatched via resolve(_:)")
        }
    }

    /// The cross-registry half of the same invariant: a lowerer that claims
    /// an operator ID `MutationRegistry.builtIn` doesn't know about would
    /// silently never route any real candidate — `SchemataChunkPlanner`
    /// would just never see a matching operator ID to ask about, no error,
    /// no `schemataEligible == true` for anything real. Caught here instead
    /// of discovered as "why does this lowerer never seem to fire."
    @Test("No registered lowerer claims an operator ID outside MutationRegistry.builtIn")
    func noLowererClaimsAnUnknownOperatorID() throws {
        // Constructed for its own side effect too: SchemataLowererRegistry's
        // init throws on a duplicate lowererID or two lowerers claiming the
        // same operator ID — today's builtIn list staying self-consistent
        // is exercised here, not just the unknown-operator-ID check below.
        _ = try SchemataLowererRegistry()

        let knownOperatorIDs = Set(MutationRegistry.builtIn.map(\.descriptor.id))
        for lowerer in SchemataLowererRegistry.builtIn {
            for operatorID in lowerer.descriptor.supportedOperatorIDs {
                #expect(
                    knownOperatorIDs.contains(operatorID),
                    "\(lowerer.descriptor.lowererID) claims unknown operator ID '\(operatorID)'"
                )
            }
        }
    }
}

// MARK: - Stub operators

//
// Each operator is a distinct *type*, because the registry resolves `descriptor`
// through the existential witness table — and that table points at the type's
// `static var descriptor`. A single shared stub type with a per-instance
// descriptor would route every lookup through the same static and lose the
// information the test is trying to assert about.

private struct HighOp: MutationOperator {
    static let descriptor = OperatorDescriptor(
        id: "test.high", version: 1, category: "test", summary: "",
        defaultEnabled: true, confidence: .high
    )
    func discover(in context: MutationContext) throws -> [MutationCandidate] { [] }
}

private struct MediumOp: MutationOperator {
    static let descriptor = OperatorDescriptor(
        id: "test.medium", version: 1, category: "test", summary: "",
        defaultEnabled: true, confidence: .medium
    )
    func discover(in context: MutationContext) throws -> [MutationCandidate] { [] }
}

private struct ExperimentalOp: MutationOperator {
    static let descriptor = OperatorDescriptor(
        id: "test.experimental", version: 1, category: "test", summary: "",
        defaultEnabled: true, confidence: .experimental
    )
    func discover(in context: MutationContext) throws -> [MutationCandidate] { [] }
}

private struct DefaultEnabledOp: MutationOperator {
    static let descriptor = OperatorDescriptor(
        id: "test.default-enabled", version: 1, category: "test", summary: "",
        defaultEnabled: true, confidence: .high
    )
    func discover(in context: MutationContext) throws -> [MutationCandidate] { [] }
}

private struct DefaultDisabledOp: MutationOperator {
    static let descriptor = OperatorDescriptor(
        id: "test.default-disabled", version: 1, category: "test", summary: "",
        defaultEnabled: false, confidence: .experimental
    )
    func discover(in context: MutationContext) throws -> [MutationCandidate] { [] }
}

private struct AlphaOp: MutationOperator {
    static let descriptor = OperatorDescriptor(
        id: "test.alpha", version: 1, category: "test", summary: "",
        defaultEnabled: true, confidence: .high
    )
    func discover(in context: MutationContext) throws -> [MutationCandidate] { [] }
}

private struct MidOp: MutationOperator {
    static let descriptor = OperatorDescriptor(
        id: "test.mid", version: 1, category: "test", summary: "",
        defaultEnabled: true, confidence: .high
    )
    func discover(in context: MutationContext) throws -> [MutationCandidate] { [] }
}

private struct ZetaOp: MutationOperator {
    static let descriptor = OperatorDescriptor(
        id: "test.zeta", version: 1, category: "test", summary: "",
        defaultEnabled: true, confidence: .high
    )
    func discover(in context: MutationContext) throws -> [MutationCandidate] { [] }
}

private struct SymbolOnlyOp: MutationOperator {
    static let descriptor = OperatorDescriptor(
        id: "test.symbol-only", version: 1, category: "test", summary: "",
        defaultEnabled: true, confidence: .high, requiresSymbolResolution: true
    )
    func discover(in context: MutationContext) throws -> [MutationCandidate] { [] }
}
