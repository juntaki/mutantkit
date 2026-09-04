import AppleBuildAdapters
import MutationExecution
import MutationModel

/// Computes `ProjectExecutionCharacteristics` for a real, resolved project —
/// the CLI-layer half of `ExecutionProfileResolver` (see that type's own doc
/// comment for why the split exists: `MutationModel` cannot itself resolve
/// an adapter or probe a filesystem). Shared by `RunCommand` (which applies
/// the resolution before executing) and `ExecutionProfileCommand` (which
/// only reports it) so the two can never compute two different answers for
/// the same project — one function, read by both.
enum ExecutionProfileSupport {
    /// No filesystem probe (and so no `WorkspaceManager`, no scratch-root
    /// parameter) is needed here: `sharedModuleCacheSupported` used to
    /// construct one purely to probe `clonefile(2)` support, but that was a
    /// fabricated precondition `ExecutionSettings.sharedModuleCache` never
    /// actually depended on — see `ProjectExecutionCharacteristics
    /// .sharedModuleCacheSupported`'s own doc comment. Removing it also
    /// removes the one thing this function used to touch a real, on-disk
    /// scratch root for at all, so callers no longer need to give it one
    /// (or, for `RunCommand`, worry about the ordering that mattered only
    /// because of it).
    static func characteristics(
        plan: MutationPlan,
        resolution: AppleAdapterFactory.Resolution
    ) async -> ProjectExecutionCharacteristics {
        // `OperatorDescriptor.schemataEligible` is already the *effective*
        // answer `MutationRegistry.effectiveDescriptor` computed from
        // `SchemataLowererRegistry.builtIn` at plan time — not a per-
        // operator literal that could have drifted from it (see that
        // field's own doc comment) — so this is a real, plan-time signal
        // (see that field's own doc comment on `ProjectExecutionCharacteristics`
        // for why "plan time" and "this build" are not always the same
        // build), not a guess about which operators a schemata backend
        // happens to support.
        //
        // Intersected against the operators the plan's own mutations
        // actually use, not just what `operators.profile` enabled for this
        // plan: an enabled-but-unused schemata-eligible operator (no
        // candidate for it exists in this project's source) would otherwise
        // pad `schemataEligibleOperatorIDs`' reported list with a name that
        // backs zero planned mutations. `usedOperatorIDs` is trivially a
        // superset check here — every mutation counted by `eligibleCount`
        // already has its own `operatorID` in `usedOperatorIDs` by
        // construction — so this narrows only the human-readable list, not
        // the count itself.
        let usedOperatorIDs = Set(plan.mutations.map(\.operatorID))
        let eligibleOperatorIDs = Set(plan.operators.filter(\.schemataEligible).map(\.id)).intersection(usedOperatorIDs)
        let eligibleCount = plan.mutations.count { eligibleOperatorIDs.contains($0.operatorID) }

        // The one real precondition (see `sharedModuleCacheSupported`'s own
        // doc comment for why `clonefile(2)` is deliberately not checked
        // here anymore).
        let sharedModuleCacheSupported = resolution.detection.kind == .swiftPackageMacOS

        // Both protocols are optional conformances by design (see their own
        // doc comments in `MutationExecution/Adapters.swift`) — checking the
        // *concrete resolved adapter instance*, not `resolution.detection
        // .kind`, means this stays correct even for a future adapter that
        // ships without either conformance, with no lookup table to keep in
        // sync.
        let perTestCoverageAdapterCapable = resolution.adapter.test is any CoverageMeasuring
            && resolution.adapter.test is any TestSelecting
        let testAdapterBatchTestable = resolution.adapter.test is any BatchTestable

        return ProjectExecutionCharacteristics(
            schemataEligibleMutationCount: eligibleCount,
            totalMutationCount: plan.mutations.count,
            schemataEligibleOperatorIDs: eligibleOperatorIDs.sorted(),
            sharedModuleCacheSupported: sharedModuleCacheSupported,
            perTestCoverageAdapterCapable: perTestCoverageAdapterCapable,
            testAdapterBatchTestable: testAdapterBatchTestable
        )
    }

    /// Resolves `settings.execution.profile` in place and returns the terse
    /// status line `RunCommand` should print — `nil` for `.reference` (the
    /// common case: a plain `mutantkit run` with no `execution.profile` in
    /// config prints nothing new). Pulled out of `RunCommand.run()` itself,
    /// the same way that already-large function pulls other steps into
    /// their own helpers, so this one addition does not push its own line
    /// count (or `RunCommand`'s own struct body) past the project's lint
    /// thresholds.
    ///
    /// Call this *before* simulator preparation and worker-pool
    /// provisioning: both branch on `settings.execution.strategy`/
    /// `.simulatorPool`, so resolving after either would mean part of a
    /// run already acted on the pre-resolution settings. See
    /// `ExecutionProfileResolver`'s own doc comment for exactly what this
    /// can and cannot change; `mutantkit execution-profile` reports the
    /// same decisions for a project without running anything.
    ///
    /// `RunCommand` calls this *after* `RunIsolationLock.acquire` even
    /// though nothing here still touches the filesystem (see
    /// `characteristics(...)`'s own doc comment) — a run that is about to
    /// lose the lock race should fail at the lock, not do any other work
    /// first, and keeping this call on the lock's far side means that stays
    /// true regardless of what a future characteristic needs to probe.
    static func resolveProfile(
        settings: inout Configuration,
        plan: MutationPlan,
        resolution: AppleAdapterFactory.Resolution
    ) async -> String? {
        guard settings.execution.profile != .reference else { return nil }

        let requested = settings.execution
        let characteristics = await characteristics(plan: plan, resolution: resolution)
        settings.execution = ExecutionProfileResolver.resolve(
            profile: requested.profile, current: requested, characteristics: characteristics
        )
        let enabled = ExecutionProfileResolver.decisions(for: characteristics, current: requested)
            .filter(\.eligible).map(\.feature.rawValue)
        return enabled.isEmpty
            ? "Execution profile: \(settings.execution.profile.rawValue) — nothing eligible for this project; running with today's defaults."
            : "Execution profile: \(settings.execution.profile.rawValue) — enabled \(enabled.joined(separator: ", "))."
    }
}
