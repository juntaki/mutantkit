// New in this session (`execution.profile`). A new project gets almost none
// of `ExecutionSettings`' real speed features by default — every one of them
// defaults off/nil, and each is documented, opted into and reasoned about
// independently (see `ExecutionSettings.swift`'s own doc comments). This
// file is the bundling layer on top of that: one setting that turns on
// ONLY the specific features this codebase already ships and already
// treats as safe/proof-preserving, and only when this exact project's own
// real, detected characteristics say the feature can actually do anything
// here — never a blind blanket-enable. See `ExecutionProfileResolver`'s own
// doc comment for the exact, grounded rule behind each feature, and
// `Sources/CLI/Commands/ExecutionProfileCommand.swift` for the
// project-specific report that shows what a given profile would do
// *before* anything runs.

/// The three supported values of `execution.profile`.
///
/// `reference` is the correctness oracle: today's real `ExecutionSettings`
/// defaults, completely unchanged, nothing auto-enabled. Every differential
/// proof that compares two runs for identical per-mutant verdicts is
/// entitled to assume this profile never moves anything.
///
/// `optimized` auto-enables only features this codebase has already
/// shipped and already treats as safe/proof-preserving *for this specific
/// project* — see `ExecutionProfileResolver.decisions(for:current:)`. By
/// itself (nothing else set), it is genuinely correctness-neutral: proven,
/// for a real fixture with both a covered and a genuinely-uncovered
/// mutable line, by `ExecutionProfileCoverageParityAcceptanceTests` —
/// identical per-mutant verdicts and identical `MutationScore.tested`
/// against `reference` on the same plan. Every feature it turns on by
/// default already degrades to reference behaviour on its own, per-mutant
/// or per-project, whenever its own precondition is not met (an
/// unattributed mutation still runs every test; an operator with no
/// registered schemata lowerer still falls back to isolated mode).
///
/// **This was not always true, and the history matters.** An earlier
/// revision of this resolver bundled `measureCoverage` +
/// `selectCoveringTests` into what `optimized` enabled by default too, on
/// the theory that both already degrade safely on their own precondition
/// (an adapter that cannot attribute coverage). That reasoning missed a
/// second, real precondition neither flag's own doc comment named at the
/// time: coverage data, once present at all, also feeds
/// `MutationRunner`'s `.noCoverage` fast path (`baseline.coverage`/
/// `.isKnownUncovered`), which reclassifies a real surviving mutant on a
/// genuinely-uncovered line as `.noCoverage` — excluded from
/// `MutationScore.tested`'s denominator — *without ever building or
/// testing it*, purely because the coverage map now exists. An
/// adversarial review reproduced this on a two-function fixture (one
/// covered, one genuinely never called): `reference` correctly built and
/// tested the uncovered mutation and reported `.survived`; `optimized`
/// reported the identical mutation `.noCoverage` and dropped it from
/// `tested`'s denominator entirely, inflating the score with zero change
/// to the actual test suite — a real, silent verdict change from choosing
/// a speed profile, which is exactly the class of bug this codebase's
/// `false-survivor-worse-than-false-error` invariant exists to prevent.
/// The fix was not to retract the claim — it was to stop bundling that
/// specific pair in by default: see `ExecutionSettings.profileCoverageSkip`,
/// the explicit, separately-named, off-by-default opt-in a project must
/// now choose deliberately to get this speedup back, with its own doc
/// comment naming the trade-off in full. `optimized` alone — the default,
/// with `profileCoverageSkip` left off — never turns `measureCoverage` or
/// `selectCoveringTests` on, so it can never reach that fast path at all.
///
/// Deliberately excluded from what `optimized`/`experimental` enable by
/// default, regardless of profile:
///
/// - **`incrementalBuild`.** It reuses one sandbox's build across every
///   mutant a worker evaluates instead of a fresh one per mutant — a real,
///   already-measured speedup (~40x on a real incremental rebuild — see
///   its own doc comment) — but it is also an execution setting carrying a
///   *named, unresolved* persistent-mutable-sandbox contamination risk
///   relative to `.isolated`'s fresh-sandbox-per-mutant reference
///   behaviour, flagged explicitly rather than proven safe the way every
///   feature `optimized` *does* enable by default has been.
/// - **`sharedModuleCache`.** Its own doc comment names a second, equally
///   real, equally unresolved risk on the same "named, not proven safe"
///   basis: it is not safe across two concurrent `mutantkit run`
///   invocations against the *same* project with *different* destinations
///   (a CI matrix job is the realistic shape this hits) — the second
///   invocation's constructor can wipe the first's in-flight module cache
///   out from under it. That failure mode manifests as a spurious build
///   failure, not a laundered survivor, but it is exactly as "not proven
///   safe as a silent default" as `incrementalBuild`'s risk, so it gets
///   the identical treatment.
///
/// `optimized`/`experimental` leave both exactly as `current` set them, on
/// or off — never touch either one either way. Both stay available only as
/// an explicit, manual `execution.incrementalBuild: true` /
/// `execution.sharedModuleCache: true` opt-in — `mutantkit execution-profile`
/// still reports whether this project's build shape could use
/// `sharedModuleCache`, purely informationally, exactly as it did before.
///
/// `experimental` is `optimized` plus features this codebase has
/// implemented but not yet proven safe for general use. That bucket is
/// honestly empty right now, not padded to look complete: the one real
/// candidate for it — mixing "safe" mutants into shared builds — has a
/// real, found soundness counterexample (mutation-induced control-flow
/// divergence) and is deliberately not wired in here, under any profile,
/// until that is resolved. `experimental` still exists as its own case,
/// resolving identically to `optimized` today
/// (`ExecutionProfileResolver.resolve`), so a project can opt into "give
/// me everything not-yet-proven" the moment such a feature is real,
/// without another config-format change.
public enum ExecutionProfile: String, Codable, Sendable, CaseIterable {
    case reference
    case optimized
    case experimental
}

/// Real, detected facts about *this* project that
/// `ExecutionProfileResolver` gates `optimized`/`experimental` decisions
/// on — every field here must be computed from something the codebase can
/// actually observe (a loaded `MutationPlan`, a resolved adapter, a real
/// filesystem probe), never guessed or hardcoded per project kind. The CLI
/// layer builds one of these (see `ExecutionProfileCommand` and
/// `RunCommand`) because the facts it needs — a decoded plan, a resolved
/// `ProjectAdapter`, a `WorkspaceManager` clone probe — live above this
/// module; `MutationModel` only defines the shape and the pure resolution
/// rule over it.
public struct ProjectExecutionCharacteristics: Sendable, Hashable {
    /// How many mutations in the loaded plan use an operator with a real,
    /// registered schemata lowerer, per `plan.json`
    /// (`OperatorDescriptor.schemataEligible` — already the effective
    /// answer `MutationRegistry.effectiveDescriptor` computed from
    /// `SchemataLowererRegistry.builtIn` at *plan* time, not a per-operator
    /// literal that can drift from it; see that field's own doc comment).
    /// This is a property of whichever build produced the plan file being
    /// read, not necessarily of the build currently running `mutantkit
    /// run`/`execution-profile` — a plan planned by an older or newer
    /// MutantKit than the one resolving it now can carry a stale answer;
    /// `PlanCompatibilityValidator` is what catches a toolchain mismatch
    /// between the two, not this field.
    ///
    /// This is the plan's own *operator-level* signal, not a re-run of
    /// `SchemataChunkPlanner`'s finer per-candidate classification (target
    /// resolution, control-flow/type-variance analysis). It is a
    /// *necessary* condition for a mutation to end up embedded, never a
    /// guarantee: zero here proves schemata mode could embed nothing from
    /// this plan (every operator it uses lacks a lowerer entirely) —
    /// nonzero means at least some mutations are eligible to *try*, with
    /// the existing per-mutant fallback machinery
    /// (`SchemataRunOrchestration`) already handling whatever still does
    /// not embed, exactly as it does today for a manually-configured
    /// `execution.strategy: schemata`.
    public let schemataEligibleMutationCount: Int
    public let totalMutationCount: Int
    /// Operator IDs backing `schemataEligibleMutationCount`, sorted, for a
    /// human-readable report — never used in the resolution decision itself.
    public let schemataEligibleOperatorIDs: [String]

    /// Whether the resolved build adapter is `SwiftPackageMacOSAdapter` —
    /// the one real precondition `ExecutionSettings.sharedModuleCache`'s own
    /// doc comment actually names ("Isolated-backend,
    /// `SwiftPackageMacOSAdapter` only for now"; confirmed by grep that
    /// `sharedModuleCache` is read only from that adapter's
    /// `buildBaseline`/`buildMutant`, via `-Xswiftc -module-cache-path`,
    /// never from any Xcode adapter or from `buildSchemataChunk`).
    ///
    /// **Not gated on `clonefile(2)`/APFS-clone support**, despite an
    /// earlier revision of this field claiming that as a second
    /// precondition: `moduleCacheArguments` only ever points a build flag
    /// at an external directory, with no dependency on cloning at all — the
    /// two mechanisms are unrelated (`WorkspaceManager`'s own
    /// `clonefile(2)` use is for cloning a sandbox's *source tree*, a
    /// completely different concern). That fabricated precondition also
    /// meant computing this field constructed a real `WorkspaceManager` —
    /// which unconditionally wipes any pre-existing module cache at its
    /// scratch root as a side effect of construction alone — purely to
    /// probe a filesystem property this flag never actually depended on;
    /// dropping it removes that probe (and its filesystem side effect)
    /// entirely, not just the doc claim.
    ///
    /// Purely informational now: `optimized`/`experimental` never read this
    /// field to decide anything (see `ExecutionProfile`'s own doc comment
    /// for why `sharedModuleCache` itself is excluded from what any profile
    /// enables) — `mutantkit execution-profile` reports it so a project
    /// considering the manual `execution.sharedModuleCache: true` opt-in
    /// knows upfront whether this project's build shape could use it at
    /// all, before reading that setting's own doc comment for whether its
    /// concurrent-multi-destination risk applies to them.
    public let sharedModuleCacheSupported: Bool

    /// Whether the resolved test adapter conforms to both
    /// `CoverageMeasuring` and `TestSelecting` — the two protocols
    /// `selectCoveringTests` actually needs
    /// (`SharedBaselineEstablisher.establish`). Both are *optional*
    /// conformances by design — an adapter lacking either makes the flag a
    /// safe no-op, never a correctness risk, per those protocols' own doc
    /// comments — so this is a real, resolved-adapter check (`is` against
    /// the concrete adapter instance), not a hardcoded per-project-kind
    /// table, and stays correct even if a future adapter ships without it.
    public let perTestCoverageAdapterCapable: Bool

    /// Whether the resolved test adapter conforms to `BatchTestable` — the
    /// one fact `ExecutionProfileResolver` needs to tell whether
    /// `RunCommand.resolveTestAdapter` would take the wave-based
    /// (`MutationRunner.testInWaves`) path or the `PrioritizingTestAdapter`
    /// wrapping path for a project that combines `selectCoveringTests` with
    /// `earlyAbortSelectedTests` and a `testBatchSize`. Only the wrapping
    /// path conflicts with `execution.strategy: schemata` — see
    /// `ExecutionProfileResolver.resolve`'s own doc comment on why this
    /// field exists.
    public let testAdapterBatchTestable: Bool

    public init(
        schemataEligibleMutationCount: Int,
        totalMutationCount: Int,
        schemataEligibleOperatorIDs: [String],
        sharedModuleCacheSupported: Bool,
        perTestCoverageAdapterCapable: Bool,
        testAdapterBatchTestable: Bool = false
    ) {
        self.schemataEligibleMutationCount = schemataEligibleMutationCount
        self.totalMutationCount = totalMutationCount
        self.schemataEligibleOperatorIDs = schemataEligibleOperatorIDs
        self.sharedModuleCacheSupported = sharedModuleCacheSupported
        self.perTestCoverageAdapterCapable = perTestCoverageAdapterCapable
        self.testAdapterBatchTestable = testAdapterBatchTestable
    }
}

/// One `ExecutionSettings` field (or small group of related fields)
/// `optimized`/`experimental` may enable.
public enum ExecutionProfileFeature: String, Sendable, Hashable, CaseIterable {
    /// `execution.strategy: schemata` — never a downgrade from an explicit
    /// `.schemata` a config already set, only ever an upgrade from
    /// `.isolated`. Withheld (see `ExecutionProfileResolver.resolve`) in
    /// exactly one combination: `selectCoveringTests` +
    /// `earlyAbortSelectedTests` on a test adapter `RunCommand
    /// .resolveTestAdapter` cannot batch, which wraps it in
    /// `PrioritizingTestAdapter` — not `SchemataTestable` — and would make
    /// schemata mode fail outright rather than run.
    case preferSchemataExecution
    /// `execution.selectCoveringTests: true` together with
    /// `execution.measureCoverage: true` — but **only when
    /// `ExecutionSettings.profileCoverageSkip` is also already `true` in
    /// `current`**. See that field's own doc comment for the full
    /// reasoning: this pair is the one exception to every other feature
    /// `optimized` enables, because turning it on can change a per-mutant
    /// verdict (`.survived` → `.noCoverage`) and `MutationScore.tested`,
    /// not merely how a verdict gets produced — so unlike every other
    /// decision in `decisions(for:current:)`, this one is never eligible
    /// on project characteristics alone.
    ///
    /// Bundled as one decision, not two, once eligible:
    /// `SharedBaselineEstablisher.establish` derives line coverage from
    /// `selectCoveringTests`' own per-test attribution whenever that
    /// attribution succeeds (`coverage = perTestCoverage?.aggregate()`),
    /// so `measureCoverage`'s own separate profiling pass only ever runs as
    /// a fallback (`if coverage == nil`) — turning it on alongside
    /// `selectCoveringTests` costs nothing extra when the attribution
    /// works, and makes the `.noCoverage` classification benefit explicit
    /// in the resolved configuration rather than an unlabeled side effect,
    /// matching `ConfigurationValidator`'s own stated preference for that
    /// combination.
    case perTestCoverageSelection
}

/// One resolver decision: whether `optimized`/`experimental` would enable
/// `feature` for this exact project, and why.
public struct ExecutionProfileDecision: Sendable, Hashable {
    public let feature: ExecutionProfileFeature
    /// Whether this project's own real characteristics support enabling
    /// `feature` at all. `ExecutionProfileResolver.resolve` enables exactly
    /// the features where this is `true`; the report command shows every
    /// decision, `eligible` or not, so a project that gets nothing from
    /// `optimized` can see *why*, not just that nothing changed.
    public let eligible: Bool
    public let rationale: String

    public init(feature: ExecutionProfileFeature, eligible: Bool, rationale: String) {
        self.feature = feature
        self.eligible = eligible
        self.rationale = rationale
    }
}

/// Turns `execution.profile` into a concrete `ExecutionSettings`, grounded
/// in one project's own real, detected characteristics — see
/// `ProjectExecutionCharacteristics`'s own doc comment for where each fact
/// comes from.
public enum ExecutionProfileResolver {
    /// What `optimized`/`experimental` would do for a project with
    /// `characteristics`, given the settings a run is otherwise starting
    /// from (`current` — needed only for `.perTestCoverageSelection`'s
    /// `profileCoverageSkip` gate and `.preferSchemataExecution`'s
    /// early-abort conflict check; every other decision depends on
    /// `characteristics` alone) — the single source of truth both
    /// `resolve(profile:current:characteristics:)` (real resolution) and
    /// `ExecutionProfileCommand` (the report) read from, so the report can
    /// never promise something `resolve` would not actually do.
    public static func decisions(
        for characteristics: ProjectExecutionCharacteristics, current: ExecutionSettings
    ) -> [ExecutionProfileDecision] {
        let schemataEligible = characteristics.schemataEligibleMutationCount > 0
        let earlyAbortConflict = Self.wouldConflictWithEarlyAbort(current: current, characteristics: characteristics)
        let schemataRationale = if schemataEligible {
            "\(characteristics.schemataEligibleMutationCount)/\(characteristics.totalMutationCount) planned " +
                "mutation(s) use an operator with a registered schemata lowerer per plan.json " +
                "(\(characteristics.schemataEligibleOperatorIDs.joined(separator: ", "))). Every other mutation " +
                "still gets a real isolated-mode verdict from the existing per-mutant fallback " +
                "(SchemataRunOrchestration) — schemata mode is never all-or-nothing for a plan." +
                (
                    earlyAbortConflict
                        ? " Not applied to this exact configuration, though: execution.selectCoveringTests + " +
                        "execution.earlyAbortSelectedTests, without a batchable test adapter and testBatchSize, " +
                        "wraps the test adapter in PrioritizingTestAdapter, which is not SchemataTestable — this " +
                        "run keeps execution.strategy: isolated instead of failing outright."
                        : ""
                )
        } else {
            "no planned mutation uses an operator with a registered schemata lowerer per plan.json " +
                "(SchemataLowererRegistry.builtIn as of whichever build produced that plan) — schemata mode " +
                "would embed nothing and only add its own target-resolution overhead."
        }

        let coverageEligible = characteristics.perTestCoverageAdapterCapable && current.profileCoverageSkip
        let coverageRationale = if !current.profileCoverageSkip {
            "requires execution.profileCoverageSkip: true (not set) — this pair can change a per-mutant verdict " +
                "and MutationScore.tested on a genuinely-uncovered line, so optimized/experimental never enable " +
                "it without that explicit, separate opt-in; see its own doc comment for the trade-off."
        } else if characteristics.perTestCoverageAdapterCapable {
            "execution.profileCoverageSkip is set, and the resolved test adapter can attribute baseline coverage " +
                "per test; a mutation whose attribution is unknown always falls back to the full configured test " +
                "list, never to an empty one."
        } else {
            "execution.profileCoverageSkip is set, but the resolved test adapter does not conform to both " +
                "CoverageMeasuring and TestSelecting — turning this on would be a pure no-op (no per-test " +
                "attribution is ever produced to select against)."
        }

        return [
            ExecutionProfileDecision(feature: .preferSchemataExecution, eligible: schemataEligible, rationale: schemataRationale),
            ExecutionProfileDecision(feature: .perTestCoverageSelection, eligible: coverageEligible, rationale: coverageRationale)
        ]
    }

    /// Whether resolving `execution.strategy: schemata` on top of `current`
    /// (as `.preferSchemataExecution` alone would) would collide with a
    /// `selectCoveringTests` + `earlyAbortSelectedTests` combination this
    /// exact run cannot batch around.
    ///
    /// `RunCommand.resolveTestAdapter` wraps the test adapter in
    /// `PrioritizingTestAdapter` — which conforms to `TestSelecting`, never
    /// `SchemataTestable` — whenever `selectCoveringTests` and
    /// `earlyAbortSelectedTests` are both on and either no `testBatchSize`
    /// is configured or the base adapter is not `BatchTestable` (the one
    /// combination that instead takes the wave-based
    /// `MutationRunner.testInWaves` path, leaving the adapter unwrapped).
    /// `SchemataRunOrchestration.run` requires the resolved test adapter to
    /// be `SchemataTestable`, so wrapping it here would turn a legitimate,
    /// ADR-0009-sanctioned `earlyAbortSelectedTests: true` into a hard
    /// "adapter does not support schemata execution" failure on every
    /// mutant — never a case where staying on `.isolated` (which already
    /// runs this exact combination correctly today) loses anything
    /// `optimized` would otherwise have proven safe.
    ///
    /// Reads `selectCoveringTests` from what it would resolve to under this
    /// same `optimized`/`experimental` pass, not only `current`'s own
    /// value, so this stays correct whether the user set
    /// `selectCoveringTests: true` directly or is relying on
    /// `profileCoverageSkip` to have this resolver turn it on.
    static func wouldConflictWithEarlyAbort(
        current: ExecutionSettings, characteristics: ProjectExecutionCharacteristics
    ) -> Bool {
        let selectCoveringTestsResolved = current.selectCoveringTests
            || (characteristics.perTestCoverageAdapterCapable && current.profileCoverageSkip)
        guard selectCoveringTestsResolved, current.earlyAbortSelectedTests else { return false }
        let wavePathAvailable = current.testBatchSize != nil && characteristics.testAdapterBatchTestable
        return !wavePathAvailable
    }

    /// Applies `decisions(for:current:)` on top of `current` when `profile`
    /// is `.optimized`/`.experimental`; returns `current` completely
    /// unchanged for `.reference`.
    ///
    /// Every change here is a monotonic upgrade, never a downgrade: a
    /// feature already on in `current` (the user configured it directly,
    /// or a prior resolution already ran) is never turned back off, even
    /// when this project's characteristics say it is not eligible —
    /// `optimized` only ever *adds* to what a config already asked for.
    /// `incrementalBuild`, `sharedModuleCache`, `workers`, `budget`,
    /// `diffBase`, `testBatchSize`, `simulatorPool`, `earlyAbortSelectedTests`,
    /// `noOpCanarySampleRate`, `retestKilledMutants`, `confirmCrashKills`
    /// and `confirmTimedOutMutants` are never touched by any profile — see
    /// `ExecutionProfile`'s own doc comment for why `incrementalBuild` and
    /// `sharedModuleCache` specifically are excluded even from
    /// `experimental`; the rest are either numeric knobs with no natural
    /// project-grounded "safe" value, already-deliberate trust/cost
    /// trade-offs the reference defaults already picked correctly, or
    /// (`simulatorPool`) documented as inert without `incrementalBuild`,
    /// which never turns on here.
    ///
    /// `.preferSchemataExecution` is the one decision this cannot apply
    /// purely by iterating `decisions(for:current:)` independently of the
    /// others: whether upgrading `strategy` to `.schemata` is safe depends
    /// on what `selectCoveringTests` is *about to resolve to* in this same
    /// pass, not only on `characteristics` — see
    /// `wouldConflictWithEarlyAbort`'s own doc comment. `selectCoveringTests`
    /// and `measureCoverage` are therefore resolved first.
    public static func resolve(
        profile: ExecutionProfile,
        current: ExecutionSettings,
        characteristics: ProjectExecutionCharacteristics
    ) -> ExecutionSettings {
        guard profile == .optimized || profile == .experimental else { return current }

        var resolved = current
        let applicable = Set(decisions(for: characteristics, current: current).filter(\.eligible).map(\.feature))

        if applicable.contains(.perTestCoverageSelection) {
            resolved.selectCoveringTests = true
            resolved.measureCoverage = true
        }
        if applicable.contains(.preferSchemataExecution), resolved.strategy == .isolated,
           !wouldConflictWithEarlyAbort(current: current, characteristics: characteristics) {
            resolved.strategy = .schemata
        }
        return resolved
    }
}
