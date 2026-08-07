import MutationModel
import MutationPlanner
import Testing

@Suite("Core operator expansion registry contract")
struct CoreOperatorRegistryExpansionTests {
    private static let ternary = "swift.core.ternary-branch-swap"
    private static let unaryNot = "swift.core.unary-not-removal"
    private static let arithmetic = "swift.core.arithmetic-operator-replacement"
    private static let assignment = "swift.core.assignment-operator-replacement"
    private static let nilCoalescing = "swift.core.nil-coalescing-fallback"
    private static let returnValue = "swift.core.return-value-replacement"

    private static let expandedIDs: Set<String> = [
        ternary,
        unaryNot,
        arithmetic,
        assignment,
        nilCoalescing,
        returnValue
    ]

    /// Enabled out of the box: syntax-only, well-typed wherever the original
    /// was, and — as of the `validation/core-operator-corpus` run against
    /// a real project — not shown to dominate a mutant budget with
    /// low-value survivors the way `nilCoalescing` did.
    ///
    /// **Provisional, not corpus-validated.** All three are measured against
    /// exactly one real project so far, not the multiple project shapes the
    /// operator catalog's own promotion bar calls for. Targeted
    /// single-operator follow-up runs found `returnValue` at 29.4% kill rate
    /// and `unaryNot` at a healthy 40.0%, but `ternary` at only 13.3% — in
    /// the same low range that got `nilCoalescing` demoted. `ternary` was
    /// deliberately NOT demoted alongside it: one corpus's low kill rate
    /// isn't enough evidence on its own, and that call is left open pending
    /// a second corpus. See the internal corpus-validation notes (not part
    /// of this public repo) and the operator catalog's item 7 for the full
    /// evidence and the open question.
    private static let defaultEnabledIDs: Set<String> = [ternary, unaryNot, returnValue]

    /// Not proven safe to compile by default — see
    /// `ArithmeticOperatorReplacementOperator`/
    /// `AssignmentOperatorReplacementOperator`'s doc comments and
    /// `CoreOperatorCompileViabilityAcceptanceTests`: neither operator has
    /// symbol resolution, and Swift's arithmetic protocols/compound-
    /// assignment operators are not guaranteed to come in matched pairs
    /// (`Numeric` has no `/`, `String` has no `-=`, ...). Reachable only via
    /// `experimental` or an explicit `enable` until a real project corpus's
    /// compile-failure rate has been measured.
    private static let notYetDefaultEnabledIDs: Set<String> = [arithmetic, assignment]

    /// Demoted from default, but for a different reason than the two above:
    /// every candidate is compile-viable (0 unviable in the corpus run),
    /// but the operator alone occupied half of a 100-mutant stratified
    /// sample while killing only ~8% of its buildable mutants — the rest
    /// re-stated the same known, low-value "defensive `?? fallback`, never
    /// exercised non-nil-vs-fallback" gap. See
    /// `NilCoalescingFallbackOperator`'s doc comment for the full corpus
    /// evidence. Reachable via `experimental` or an explicit `enable`.
    private static let signalDensityDemotedIDs: Set<String> = [nilCoalescing]

    @Test("The production registry exposes every operator in the first expansion slice")
    func registryContainsExpandedOperators() {
        let descriptors = MutationRegistry().allDescriptors
        let IDs = Set(descriptors.map(\.id))

        #expect(Self.expandedIDs.isSubset(of: IDs), "Missing operator IDs: \(Self.expandedIDs.subtracting(IDs).sorted())")
    }

    @Test("Default profile is ternary/unary-not/return-value; arithmetic/assignment/nil-coalescing are experimental-only")
    func profilesMatchTheQualityTiers() throws {
        let registry = MutationRegistry()
        let conservative = try registry.resolve(OperatorSettings(profile: .conservative))
        let defaultProfile = try registry.resolve(OperatorSettings(profile: .default))
        let experimental = try registry.resolve(OperatorSettings(profile: .experimental))

        let conservativeIDs = Set(conservative.descriptors.map(\.id))
        let defaultIDs = Set(defaultProfile.descriptors.map(\.id))
        let experimentalIDs = Set(experimental.descriptors.map(\.id))

        #expect(conservativeIDs.contains(Self.ternary))
        for id in Self.expandedIDs.subtracting([Self.ternary]) {
            #expect(!conservativeIDs.contains(id), "\(id) must not be admitted by the conservative profile")
        }

        #expect(Self.defaultEnabledIDs.isSubset(of: defaultIDs))
        let notDefault = Self.notYetDefaultEnabledIDs.union(Self.signalDensityDemotedIDs)
        for id in notDefault {
            #expect(!defaultIDs.contains(id), "\(id) is not in the default profile")
        }

        // Still reachable — just not by default — via `experimental`.
        #expect(notDefault.isSubset(of: experimentalIDs))

        // And via an explicit `enable`, bypassing the profile gate entirely.
        for id in notDefault {
            let explicit = try registry.resolve(OperatorSettings(profile: .conservative, enable: [id]))
            #expect(Set(explicit.descriptors.map(\.id)).contains(id))
        }
    }

    @Test("All first-slice operators are syntax-local and honestly confidence-rated")
    func descriptorsDeclareTheIntendedSafetyContract() throws {
        let descriptors = Dictionary(uniqueKeysWithValues: MutationRegistry().allDescriptors.map { ($0.id, $0) })

        let ternary = try #require(descriptors[Self.ternary])
        #expect(ternary.defaultEnabled)
        #expect(ternary.confidence == .high)
        #expect(!ternary.requiresSymbolResolution)

        for id in [Self.unaryNot, Self.returnValue] {
            let descriptor = try #require(descriptors[id], "Missing descriptor for \(id)")
            #expect(descriptor.defaultEnabled, "\(id) is expected to be default-enabled")
            #expect(descriptor.confidence == .medium)
            #expect(!descriptor.requiresSymbolResolution)
        }

        for id in Self.notYetDefaultEnabledIDs.union(Self.signalDensityDemotedIDs) {
            let descriptor = try #require(descriptors[id], "Missing descriptor for \(id)")
            #expect(!descriptor.defaultEnabled, "\(id) is not in the default profile")
            #expect(descriptor.confidence == .medium)
            #expect(!descriptor.requiresSymbolResolution)
        }
    }
}
