import MutationModel
import Testing

/// Pure, no-toolchain tests for `ExecutionProfileResolver` — the resolution
/// logic behind `execution.profile`. Every case here is deliberately about
/// the *rule*, not about any one project's real facts (that real-project
/// proof is `ExecutionProfileParityAcceptanceTests`/
/// `ExecutionProfileCoverageParityAcceptanceTests`, which run the actual
/// `mutantkit` binary against a real fixture under `reference` and
/// `optimized` and diff per-mutant verdicts).
@Suite("ExecutionProfileResolver")
struct ExecutionProfileResolverTests {
    private func characteristics(
        schemataEligible: Int = 0,
        total: Int = 0,
        operatorIDs: [String] = [],
        sharedModuleCache: Bool = false,
        perTestCoverage: Bool = false,
        batchTestable: Bool = false
    ) -> ProjectExecutionCharacteristics {
        ProjectExecutionCharacteristics(
            schemataEligibleMutationCount: schemataEligible,
            totalMutationCount: total,
            schemataEligibleOperatorIDs: operatorIDs,
            sharedModuleCacheSupported: sharedModuleCache,
            perTestCoverageAdapterCapable: perTestCoverage,
            testAdapterBatchTestable: batchTestable
        )
    }

    // MARK: - reference is inert

    @Test("reference never changes ExecutionSettings, regardless of how favorable the characteristics are")
    func referenceIsAlwaysInert() {
        var current = ExecutionSettings()
        current.profileCoverageSkip = true
        let everythingEligible = characteristics(
            schemataEligible: 5, total: 5, operatorIDs: ["a"], sharedModuleCache: true, perTestCoverage: true
        )
        let resolved = ExecutionProfileResolver.resolve(profile: .reference, current: current, characteristics: everythingEligible)
        #expect(resolved == current)
    }

    // MARK: - optimized enables exactly what is eligible, coverage pair excepted

    @Test("optimized enables schemata, but never the coverage pair or sharedModuleCache, with profileCoverageSkip left off")
    func optimizedNeverBundlesCoveragePairOrSharedModuleCacheByDefault() {
        let current = ExecutionSettings(profile: .optimized)
        let allEligible = characteristics(
            schemataEligible: 3, total: 5, operatorIDs: ["swift.core.bool-literal-inversion"],
            sharedModuleCache: true, perTestCoverage: true
        )
        let resolved = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: allEligible)

        #expect(resolved.strategy == .schemata)
        #expect(resolved.selectCoveringTests == false)
        #expect(resolved.measureCoverage == false)
        #expect(resolved.sharedModuleCache == false)
    }

    @Test("optimized enables the coverage pair only when profileCoverageSkip is also set, on an otherwise-eligible project")
    func optimizedEnablesCoveragePairOnlyWithExplicitOptIn() {
        let allEligible = characteristics(perTestCoverage: true)

        var withoutOptIn = ExecutionSettings(profile: .optimized)
        withoutOptIn.profileCoverageSkip = false
        let resolvedWithoutOptIn = ExecutionProfileResolver.resolve(
            profile: .optimized, current: withoutOptIn, characteristics: allEligible
        )
        #expect(resolvedWithoutOptIn.selectCoveringTests == false)
        #expect(resolvedWithoutOptIn.measureCoverage == false)

        var withOptIn = ExecutionSettings(profile: .optimized)
        withOptIn.profileCoverageSkip = true
        let resolvedWithOptIn = ExecutionProfileResolver.resolve(
            profile: .optimized, current: withOptIn, characteristics: allEligible
        )
        #expect(resolvedWithOptIn.selectCoveringTests == true)
        #expect(resolvedWithOptIn.measureCoverage == true)
    }

    @Test("profileCoverageSkip alone, without a capable adapter, enables nothing")
    func profileCoverageSkipWithoutCapableAdapterEnablesNothing() {
        var current = ExecutionSettings(profile: .optimized)
        current.profileCoverageSkip = true
        let incapable = characteristics(perTestCoverage: false)
        let resolved = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: incapable)
        #expect(resolved.selectCoveringTests == false)
        #expect(resolved.measureCoverage == false)
    }

    @Test("optimized never enables sharedModuleCache, even when this project's characteristics say it is supported")
    func optimizedNeverEnablesSharedModuleCache() {
        let current = ExecutionSettings(profile: .optimized)
        let cacheSupported = characteristics(sharedModuleCache: true)
        let resolved = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: cacheSupported)
        #expect(resolved.sharedModuleCache == false)
    }

    @Test("optimized enables nothing when no characteristic is favorable")
    func optimizedEnablesNothingWhenIneligible() {
        let current = ExecutionSettings(profile: .optimized)
        let noneEligible = characteristics()
        let resolved = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: noneEligible)

        #expect(resolved.strategy == .isolated)
        #expect(resolved.selectCoveringTests == false)
        #expect(resolved.measureCoverage == false)
        #expect(resolved.sharedModuleCache == false)
    }

    @Test("optimized turns schemata on only when at least one mutation is operator-level eligible")
    func schemataStrategyGatedOnEligibleCount() {
        let zeroEligible = characteristics(schemataEligible: 0, total: 5)
        let resolvedZero = ExecutionProfileResolver.resolve(
            profile: .optimized, current: ExecutionSettings(), characteristics: zeroEligible
        )
        #expect(resolvedZero.strategy == .isolated)

        let oneEligible = characteristics(schemataEligible: 1, total: 5)
        let resolvedOne = ExecutionProfileResolver.resolve(
            profile: .optimized, current: ExecutionSettings(), characteristics: oneEligible
        )
        #expect(resolvedOne.strategy == .schemata)
    }

    // MARK: - the schemata / earlyAbortSelectedTests conflict

    @Test("optimized refuses schemata when selectCoveringTests + earlyAbortSelectedTests would wrap the adapter in PrioritizingTestAdapter")
    func schemataWithheldOnEarlyAbortConflict() {
        var current = ExecutionSettings(profile: .optimized)
        current.selectCoveringTests = true
        current.earlyAbortSelectedTests = true
        let eligible = characteristics(schemataEligible: 1, total: 1, batchTestable: false)

        let resolved = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: eligible)
        #expect(resolved.strategy == .isolated, "schemata must not conflict with PrioritizingTestAdapter")
    }

    @Test("the conflict check also fires when profileCoverageSkip is what enables selectCoveringTests, not a direct setting")
    func schemataWithheldWhenCoverageSkipWouldEnableTheConflictingCombination() {
        var current = ExecutionSettings(profile: .optimized)
        current.profileCoverageSkip = true
        current.earlyAbortSelectedTests = true
        // selectCoveringTests itself is NOT set directly here — only
        // profileCoverageSkip, which (with a capable adapter) is what
        // resolves it to true.
        let eligible = characteristics(schemataEligible: 1, total: 1, perTestCoverage: true, batchTestable: false)

        let resolved = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: eligible)
        #expect(resolved.selectCoveringTests == true, "profileCoverageSkip should have enabled the coverage pair")
        #expect(resolved.strategy == .isolated, "schemata must not enable once selectCoveringTests resolved true")
    }

    @Test("the conflict is avoided when a batchable adapter and testBatchSize make the wave-based path available instead")
    func schemataStillEnabledWhenWavePathAvailable() {
        var current = ExecutionSettings(profile: .optimized)
        current.selectCoveringTests = true
        current.earlyAbortSelectedTests = true
        current.testBatchSize = 8
        let eligible = characteristics(schemataEligible: 1, total: 1, batchTestable: true)

        let resolved = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: eligible)
        #expect(resolved.strategy == .schemata, "a batchable adapter + testBatchSize takes the wave path, never wrapping the adapter")
    }

    @Test("without earlyAbortSelectedTests, selectCoveringTests alone never withholds schemata")
    func selectCoveringTestsAloneDoesNotWithholdSchemata() {
        var current = ExecutionSettings(profile: .optimized)
        current.selectCoveringTests = true
        let eligible = characteristics(schemataEligible: 1, total: 1)

        let resolved = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: eligible)
        #expect(resolved.strategy == .schemata)
    }

    // MARK: - experimental resolves identically to optimized (today)

    @Test("experimental resolves the same ExecutionSettings as optimized for identical inputs")
    func experimentalMatchesOptimized() {
        // `resolve` never writes `.profile` itself — it only ever reads
        // `current.profile` through, unchanged (see that property's own
        // doc comment: only the CLI layer, comparing against the
        // *requested* profile, ever decides what the resolved value
        // means) — so calling both variants against the same `current`
        // must produce genuinely identical `ExecutionSettings`, `.profile`
        // field included, with no override needed on either side.
        for characteristics in [
            characteristics(),
            characteristics(schemataEligible: 2, total: 4, sharedModuleCache: true),
            characteristics(perTestCoverage: true)
        ] {
            var current = ExecutionSettings()
            current.profileCoverageSkip = true
            let optimized = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: characteristics)
            let experimental = ExecutionProfileResolver.resolve(profile: .experimental, current: current, characteristics: characteristics)
            #expect(experimental == optimized)
        }
    }

    // MARK: - never a downgrade, never touches anything outside the bundle

    @Test("optimized never turns an already-on field off, even when this project's characteristics no longer support it")
    func neverDowngradesAnAlreadyOnField() {
        var current = ExecutionSettings()
        current.strategy = .schemata
        current.selectCoveringTests = true
        current.measureCoverage = true
        current.sharedModuleCache = true

        let noneEligible = characteristics()
        let resolved = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: noneEligible)

        #expect(resolved.strategy == .schemata)
        #expect(resolved.selectCoveringTests == true)
        #expect(resolved.measureCoverage == true)
        #expect(resolved.sharedModuleCache == true)
    }

    @Test("optimized/experimental never touch incrementalBuild, in either direction")
    func neverTouchesIncrementalBuild() {
        let favorable = characteristics(schemataEligible: 1, total: 1, sharedModuleCache: true, perTestCoverage: true)

        var offCurrent = ExecutionSettings()
        offCurrent.incrementalBuild = false
        for profile: ExecutionProfile in [.optimized, .experimental] {
            let resolved = ExecutionProfileResolver.resolve(profile: profile, current: offCurrent, characteristics: favorable)
            #expect(resolved.incrementalBuild == false, "profile \(profile) must not turn incrementalBuild on")
        }

        var onCurrent = ExecutionSettings()
        onCurrent.incrementalBuild = true
        for profile: ExecutionProfile in [.optimized, .experimental] {
            let resolved = ExecutionProfileResolver.resolve(profile: profile, current: onCurrent, characteristics: favorable)
            #expect(resolved.incrementalBuild == true, "profile \(profile) must not turn incrementalBuild off either")
        }
    }

    @Test("optimized never touches workers, budget, diffBase, testBatchSize, simulatorPool, or the trust/verification flags")
    func neverTouchesUnrelatedFields() {
        var current = ExecutionSettings()
        current.workers = 3
        current.budget.maxMutants = 42
        current.diffBase = "origin/main"
        current.testBatchSize = 5
        current.simulatorPool = true
        current.retestKilledMutants = true
        current.confirmCrashKills = false
        current.confirmTimedOutMutants = false
        current.earlyAbortSelectedTests = true
        current.noOpCanarySampleRate = 0.1

        let favorable = characteristics(schemataEligible: 1, total: 1, sharedModuleCache: true, perTestCoverage: true)
        let resolved = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: favorable)

        #expect(resolved.workers == 3)
        #expect(resolved.budget.maxMutants == 42)
        #expect(resolved.diffBase == "origin/main")
        #expect(resolved.testBatchSize == 5)
        #expect(resolved.simulatorPool == true)
        #expect(resolved.retestKilledMutants == true)
        #expect(resolved.confirmCrashKills == false)
        #expect(resolved.confirmTimedOutMutants == false)
        #expect(resolved.earlyAbortSelectedTests == true)
        #expect(resolved.noOpCanarySampleRate == 0.1)
    }

    // MARK: - decisions(for:current:) is the single source of truth resolve() reads

    @Test("decisions(for:current:) reports eligible=true for every feature exactly when resolve() would enable it")
    func decisionsAgreeWithResolve() {
        var current = ExecutionSettings()
        current.profileCoverageSkip = true
        let mixed = characteristics(schemataEligible: 1, total: 2, sharedModuleCache: false, perTestCoverage: true)
        let decisions = ExecutionProfileResolver.decisions(for: mixed, current: current)
        let resolved = ExecutionProfileResolver.resolve(profile: .optimized, current: current, characteristics: mixed)

        let schemataDecision = decisions.first { $0.feature == .preferSchemataExecution }
        let coverageDecision = decisions.first { $0.feature == .perTestCoverageSelection }

        #expect(schemataDecision?.eligible == true)
        #expect(resolved.strategy == .schemata)
        #expect(coverageDecision?.eligible == true)
        #expect(resolved.selectCoveringTests == true)
    }

    @Test("decisions(for:current:) reports perTestCoverageSelection ineligible without profileCoverageSkip, even on a capable adapter")
    func decisionsReportCoverageIneligibleWithoutOptIn() {
        let current = ExecutionSettings()
        let capable = characteristics(perTestCoverage: true)
        let decisions = ExecutionProfileResolver.decisions(for: capable, current: current)
        let coverageDecision = decisions.first { $0.feature == .perTestCoverageSelection }
        #expect(coverageDecision?.eligible == false)
        #expect(coverageDecision?.rationale.contains("profileCoverageSkip") == true)
    }
}
