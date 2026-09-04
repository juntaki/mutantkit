import Foundation

// Split out of Configuration.swift (which was pushing past the repo's own
// `file_length` threshold) along an existing `// MARK: - Execution` boundary
// that was already a self-contained struct — see .swiftlint.yml's own note
// on `file_length`/`type_body_length` concentrating in a handful of large
// files; this keeps that debt from growing rather than baselining it.

public struct ExecutionSettings: Codable, Sendable, Hashable {
    /// See `ExecutionProfile`'s own doc comment. `.reference` (the default)
    /// leaves every field below exactly as written here/in config — this
    /// struct's `init`/decode defaults are themselves the reference
    /// behaviour, unconditionally. Resolving `.optimized`/`.experimental`
    /// into concrete field values is `ExecutionProfileResolver.resolve`'s
    /// job, not this struct's own — a `Configuration` on disk or freshly
    /// decoded always reports the *requested* profile here; only the CLI
    /// layer (which alone has the project characteristics a resolution
    /// needs — a loaded plan, a resolved adapter, a filesystem probe) ever
    /// produces the *resolved* `ExecutionSettings` a run actually executes
    /// with.
    public var profile: ExecutionProfile
    public var strategy: ExecutionMode
    /// `nil` means "auto": derived from active processor count.
    public var workers: Int?
    public var budget: BudgetSettings
    /// Only mutate declarations touched by this diff base (e.g. `origin/main`).
    public var diffBase: String?
    /// Measure line coverage on the baseline run and use it to classify mutants
    /// on unexercised lines as `.noCoverage` without building them.
    ///
    /// Off by default for v0.1: instrumentation changes the baseline binary,
    /// and the activation check that depends on the binary hash is something
    /// the acceptance suites have to re-prove empirically whenever the
    /// toolchain changes. Turning this on is a one-shot baseline cost for a
    /// large per-mutant speedup, plus a more honest Effective Mutation Score
    /// that names "uncovered" rather than reporting it as "survived".
    public var measureCoverage: Bool
    /// Re-runs a mutant's tests a second time before trusting a `killedByAssertion`
    /// verdict, and reclassifies it as `.flaky` if the second run does not fail
    /// the same way.
    ///
    /// Off by default, matching `TestSettings.parallel`: the risk this exists to
    /// catch is the same one described there — a suite that is not parallel-safe
    /// flakes, and a flaky failure during a mutant's run is indistinguishable
    /// from the mutant being caught. Left off, that flake is recorded as
    /// `killedByAssertion` and silently inflates the score by one.
    ///
    /// Turning this on doubles the test invocation for every mutant that looks
    /// killed, which is the common case in a well-tested project — the cost is
    /// real and scales with the kill rate, not with how flaky the suite actually
    /// is. It only re-runs tests, never the build: the artifact is already known
    /// good, and rebuilding would not change whether the suite agrees with
    /// itself.
    public var retestKilledMutants: Bool
    /// Re-confirms a `killedByCrash` verdict with a full, independent
    /// rebuild in a fresh sandbox before trusting it, and reclassifies it as
    /// `.flaky` if the confirmation does not crash the same way.
    ///
    /// On by default, unlike `retestKilledMutants`: a crash is a claim about
    /// the test *runner*, not about an assertion the mutation broke, and it
    /// has no equivalent of "the diff shows exactly what failed" to check it
    /// against. Found necessary on a real project — a `killedByCrash`
    /// verdict whose crash was attributed to test methods with no logical
    /// connection to the mutated file did not reproduce when the identical
    /// mutant sandbox was rebuilt and tested by hand. A same-sandbox retest
    /// (what `retestKilledMutants` does) was not enough to catch that class
    /// of failure, which is why this rebuilds from scratch rather than
    /// re-running tests against the artifact already on disk.
    public var confirmCrashKills: Bool
    /// Re-confirms a `.timedOut` verdict with a full, independent rebuild in
    /// a fresh sandbox before trusting it, and reclassifies it — to
    /// `.verifiedTimeout` if it times out again, to `.flaky` if it doesn't,
    /// to `.infrastructureFailure` if the confirmation itself could not run.
    /// The timeout twin of `confirmCrashKills`, same reasoning: a plain
    /// `.timedOut` is a claim about the test *runner* hanging, not about an
    /// assertion the mutation broke, and a hang is just as capable of being
    /// an artifact of *this* run's conditions as a crash is.
    ///
    /// On by default, matching `confirmCrashKills` rather than
    /// `retestKilledMutants`. Found necessary on a real project — the same
    /// mutant that reported `killedByCrash` on one machine reported
    /// `.timedOut` on another (and on a third run, `.flaky`), all under
    /// identical plan, commit, and timeout — proof that manifestation is not
    /// a stable property of a mutant across execution context, while
    /// whether the suite catches it at all can still be proven stable by
    /// confirming it, the same way `confirmCrashKills` already does for
    /// crashes. Confirms under the *same* timeout limit as the original
    /// attempt: a longer limit proves nothing about whether the original
    /// one was legitimately exceeded again.
    public var confirmTimedOutMutants: Bool
    /// Attributes baseline coverage to individual tests, and narrows each
    /// mutant's test invocation to only the tests that cover the mutated
    /// line, instead of running every configured test target.
    ///
    /// Off by default, and implies coverage instrumentation the same way
    /// `measureCoverage` does — see its doc comment for why that is opt-in.
    /// The dominant per-mutant cost on a real Xcode project is not the
    /// build, it is re-running a full test suite that mostly has nothing to
    /// do with the line that changed; this is the fix for that, at the cost
    /// of a one-time baseline pass that runs every test individually to
    /// build the attribution. A mutation whose covering tests are unknown —
    /// coverage was not measured, or the map has nothing to say about that
    /// line — always falls back to the full configured test list, never to
    /// an empty one: an empty `-only-testing:` selection would run nothing
    /// and could be mistaken for a pass.
    public var selectCoveringTests: Bool
    /// Reuses one sandbox per worker across every mutant that worker
    /// evaluates, instead of a fresh one per mutant, so `xcodebuild`'s own
    /// incremental build can recompile only the one file a mutation
    /// touched rather than the whole target from scratch.
    ///
    /// Off by default: `.isolated`'s per-mutant fresh sandbox is the
    /// reference implementation this tool's correctness is measured
    /// against, and this reuses that same sandbox's *build* across mutants
    /// while keeping everything else about it — application, build,
    /// activation-hash comparison against baseline, test, classification,
    /// and confirmation reruns, which always still get their own
    /// independent sandbox — identical. Verified empirically on a real
    /// project: an incremental rebuild after a single-line change measured
    /// ~40x faster than a fresh sandbox's build, and the build product's
    /// activation hash correctly tracked the mutation being applied and
    /// reverted with no false positives or negatives, because
    /// `MachOCodeHash` already hashes only code, not the load-command
    /// timestamps/UUIDs a rebuild always changes. The mutant's build is
    /// still compared only against the baseline's hash — never against
    /// another mutant's — so reusing the sandbox path across mutants adds
    /// no new correctness surface beyond what an incremental compiler
    /// itself has to get right, and a compiler that got it wrong would
    /// show up as an unproven-activation `.survived`, not a silent pass —
    /// see `MutationRunner.activationEvidence`.
    public var incrementalBuild: Bool
    /// Runs a mutant's covering tests one at a time, in historical
    /// kill-priority order, stopping at the first one that detects it,
    /// instead of the whole covering-test selection in one invocation.
    ///
    /// What "one at a time" costs depends on whether the resolved test
    /// adapter also conforms to `BatchTestable` and `testBatchSize` is set:
    ///
    /// - **Batchable adapter + `testBatchSize`**: wave-based early kill
    ///   (`MutationRunner.testInWaves`) — every surviving mutant's next
    ///   prioritised test runs together in one shared `xcodebuild`
    ///   invocation per wave, so the fixed per-invocation overhead
    ///   (simulator install/launch) is paid once per wave across every
    ///   mutant still alive, not once per mutant. A mutant killed early
    ///   drops out of later waves; killed mutants' confirmation reruns are
    ///   narrowed to the single test that produced the detection.
    /// - **Otherwise**: `PrioritizingTestAdapter` wraps the adapter and runs
    ///   one `xcodebuild` invocation per test per mutant, serially — the
    ///   fixed overhead is paid on every test, for every mutant,
    ///   independently.
    ///
    /// Off by default, and deliberately a *separate* flag from
    /// `selectCoveringTests` rather than automatic behaviour bundled into
    /// it: `selectCoveringTests` alone already narrows a mutant's tests to
    /// one batched `-only-testing:` invocation, whose cost is dominated by
    /// that same fixed per-invocation overhead (measured on a real project
    /// at roughly the same ~30s whether the batch is one test or several).
    /// Splitting that batch into one invocation per test only comes out
    /// ahead when the ordering reliably detects a kill on an early test —
    /// something `TestPriorityStore` has no history for on a project's first
    /// run, and never has any signal for on a mutant that survives (every
    /// covering test still has to run, at the full per-test price, before
    /// either strategy can conclude that). Left on the batched default until
    /// a project has enough run history for the ordering to pay for itself.
    public var earlyAbortSelectedTests: Bool
    /// Builds every mutant as usual, but tests up to this many of them per
    /// `xcodebuild` invocation instead of one invocation per mutant — see
    /// `BatchTestable`/`BatchXCTestRunBuilder`.
    ///
    /// `nil` (the default) means unbatched: every mutant tests alone, the
    /// reference behaviour. Confirmed empirically on a real project:
    /// `xcodebuild test-without-building` pays its dominant cost (device
    /// install/launch, tens of seconds) once per *invocation*, not once per
    /// test — batching several mutants' already-independent, already-built
    /// artifacts into one `.xctestrun` with several `TestConfigurations`
    /// pays that cost once for the whole batch, and `xcodebuild` recovers on
    /// its own from a configuration whose test process crashes, continuing
    /// to the rest. Nothing about *what* is built or *how* a verdict is
    /// proven changes: each mutant still has its own build, own binary, own
    /// activation hash, and its own crash/timeout confirmation in an
    /// independent sandbox if its outcome calls for one — batching only
    /// changes how many `xcodebuild` processes the already-built artifacts
    /// are tested through. A mutant whose covering tests are not known
    /// (`selectCoveringTests` off, or attribution unknown for its line) is
    /// never batched: a batched invocation reports a failure per
    /// `TestConfiguration`, and that failure is attributed back to the one
    /// mutant it belongs to only when this mutant's tests were narrowed to a
    /// known, per-mutant selection ahead of time. Different mutants routinely
    /// *share* covering tests — that is expected and supported — so "narrowed"
    /// here means each configuration is pinned to a known test selection, not
    /// that two mutants' selections must be disjoint. Without a known
    /// selection the runner cannot tell which mutant a batch failure belongs
    /// to, so such a mutant still tests correctly, just alone.
    public var testBatchSize: Int?
    /// The fraction (0...1) of isolated-mode, hash-matched "no-op" mutants
    /// (`MutationRunner.prepare`'s build-product-identical-to-baseline
    /// short-circuit) that skip the short-circuit and run the real suite
    /// anyway, as a canary check on `MachOCodeHash` itself.
    ///
    /// The short-circuit trusts `MachOCodeHash`'s "identical to baseline"
    /// claim completely, and that claim has been wrong before: issue #3 (see
    /// `MachOCodeHash`'s own doc comment) was a real, CI-confirmed false
    /// positive where a mutation that genuinely reached the binary and
    /// genuinely failed a test still hashed identical to baseline, because
    /// the difference lived in linkage rather than in any hashed section's
    /// bytes. Before the short-circuit existed, running the suite on every
    /// mutant was what surfaced that — a hash-identical mutant whose tests
    /// still failed was a visible contradiction. The short-circuit removes
    /// that net for every hash-matched mutant, since it now never runs their
    /// tests at all: a future linkage-shaped (or otherwise) gap in
    /// `MachOCodeHash` — v2 fixed issue #3's specific shape, nothing
    /// guarantees it is the last one — would hash "identical" and go
    /// straight to a silent `.infrastructureFailure` with no test ever run
    /// to contradict it.
    ///
    /// This reopens a narrow, low-cost slice of that net rather than
    /// reverting the short-circuit outright: membership is a deterministic
    /// function of the mutation's own stable ID (see
    /// `MutationRunner.isNoOpCanarySample`), never a random draw, so the
    /// same plan always samples the same canaries — "two runs of the same
    /// plan produce the same report" (`MutationRunner`'s own doc comment)
    /// still holds. A sampled mutant that reports anything other than
    /// `.passed` is exactly issue #3's fingerprint and is logged distinctly
    /// to `RunReport.operationalIssues` rather than silently absorbed into
    /// the same `.infrastructureFailure` bucket a genuine no-op would also
    /// land in.
    ///
    /// `0` (the default) disables the canary entirely — the short-circuit
    /// behaves exactly as it did before this existed. `1` runs every
    /// hash-matched mutant's tests for real, i.e. no short-circuit at all.
    /// Left off by default because the cost is the same per-mutant
    /// wall-clock the short-circuit exists to avoid, paid on every sampled
    /// mutant; a project that wants the safety net back sets this to a small
    /// nonzero fraction (e.g. `0.05`) rather than paying it on every mutant.
    public var noOpCanarySampleRate: Double
    /// Phase C4 (competitive-parity program): when `true`, `workers > 1`
    /// against an Xcode/iOS-Simulator destination provisions one real
    /// simulator slot per worker (the base device for worker 0, a fresh
    /// `simctl clone` of it for each additional worker) instead of every
    /// worker contending for the single run-wide destination.
    ///
    /// **Off by default.** Scoped narrowly, on purpose, to exactly the
    /// configuration this has been benchmarked against:
    /// `incrementalBuild: true` with `testBatchSize` unset. Batched/
    /// pipelined test execution (`testBatchSize` set) intentionally
    /// consolidates multiple workers' completed builds into one shared
    /// test lane — extending that to multiple lanes, one per simulator, is
    /// a materially different, larger change this phase does not attempt;
    /// `simulatorPool: true` together with a `testBatchSize` has no effect
    /// beyond today's single-device behavior, silently, until that follow-
    /// on work exists. Ignored entirely for `incrementalBuild: false`
    /// (per-mutant, non-persistent sandboxes have no stable worker
    /// identity to assign a device to) and for schemata execution (a
    /// different execution strategy with its own chunk-based concurrency
    /// model, not addressed by this flag).
    ///
    /// **Real, non-trivial local disk cost — budget for it.** Each
    /// additional worker beyond the first is a full `simctl clone` of the
    /// base simulator, not a lightweight reference. Observed directly
    /// during this flag's own benchmarking (`Research/competitive-parity-
    /// 2026-08/PROGRESS.md`'s C4 entry): a single clone reached 1.6-2.6GB
    /// partway through one 100-mutant real-project run, so `workers: 4`
    /// (3 clones) can add several GB on top of whatever the base device
    /// and the run's own `.mutantkit` sandboxes already use — real
    /// pressure a disk-exhaustion incident during that same benchmarking
    /// actually hit. `releaseWorkerPool` deletes every clone it created
    /// once a run ends (and `cleanupOrphanClones` sweeps any a killed
    /// prior run left behind, on the next run that provisions a pool), so
    /// this cost does not accumulate run-over-run on its own — but
    /// `~/Library/Developer/CoreSimulator/Devices` (every simulator's own
    /// data, not just this tool's clones) and a project's own
    /// `.mutantkit/sandboxes` are both worth checking before a `workers >
    /// 1` run on a machine that has been running many simulator-heavy
    /// workloads without ever clearing either.
    public var simulatorPool: Bool
    /// Routes every isolated-backend build's Clang/Swift module cache
    /// (`.build/<triple>/debug/ModuleCache`, which holds precompiled
    /// Foundation/XCTest/SwiftShims modules -- not project code, and 150+ MB
    /// of it even for a two-file fixture) to one external, shared directory
    /// outside any sandbox, instead of each sandbox's own private cache
    /// nested inside its own `.build`.
    ///
    /// Off by default. `Research/isolated-build-reuse-2026-09` is the
    /// measurement behind this: a fresh sandbox pointed at a pre-warmed
    /// external cache built its `--build-tests` step in 7.5s real / 3.9s
    /// user versus 24.4s real / 13.4s user cold (private cache) on that
    /// probe's fixture -- system-framework compilation dominates a small
    /// project's cold build, so most of that gap is Foundation/XCTest/
    /// SwiftShims recompilation this flag lets every sandbox after the
    /// first skip. What this does *not* buy: SwiftPM's own incremental
    /// build state (`.build`'s build-state/incremental records, separate
    /// from the module cache) is path-keyed the same way the module cache
    /// is and does not survive relocation between sandboxes either -- the
    /// same research ruled that out by reproduction (row 4 of its S1
    /// table) -- so every sandbox still fully recompiles the project's own
    /// sources; only system-framework recompilation is skipped.
    ///
    /// Safe by construction, not merely by observation: mutation testing
    /// only ever changes a line a plan already reaches (an operator, a
    /// condition), never an import, so the set of modules any mutant's
    /// build could need is always a subset of what the baseline build --
    /// which always runs first, alone, before any mutant sandbox exists,
    /// for every backend this flag applies to -- already populated. Every
    /// mutant sandbox therefore finds the cache already warm for anything
    /// it needs; the two-worker concurrent-cold race in the same research
    /// (S1 #5) additionally confirms concurrent *misses* against the same
    /// empty cache do not corrupt or error either, backed by Clang's own
    /// documented per-module lock file (`llvm::LockFileManager`: a build
    /// either owns a module's lock and builds it, or finds it already
    /// shared-locked and waits for the owner) -- concurrent access to a
    /// shared module cache is a case Clang's own module system is designed
    /// to make safe, not an assumption this flag rests on unverified.
    /// `WorkspaceManager.init` wipes any pre-existing cache at this
    /// directory before every process that touches this scratch root runs
    /// a single build, so a cache from a previous invocation -- built by a
    /// possibly different toolchain -- is never reused stale; see that
    /// type's own doc comment.
    ///
    /// Hardening pass (`next/s1-module-cache-hardening`): the directory
    /// itself is now namespaced by a real toolchain fingerprint -- see
    /// `SharedModuleCacheFingerprint`/`SharedModuleCacheNamespace` -- as a
    /// second, independent layer on top of the wipe above. That wipe is
    /// `try?`-guarded best-effort (a permission-denied or file-busy removal
    /// is silently swallowed, not surfaced) and only ever runs once, at
    /// construction; namespacing by fingerprint means a toolchain change
    /// can never collide with an old cache's own contents even when that
    /// wipe silently fails, because a different toolchain resolves to a
    /// different directory outright -- there is no shared name left for a
    /// stale entry to survive under. A build whose shared cache directory
    /// fails for cache-implicated reasons (evidence-based, not a blanket
    /// retry -- see `SwiftPackageMacOSAdapter
    /// .isLikelySharedModuleCacheCorruption`) also gets one automatic
    /// delete-and-retry against a fresh, empty cache before the build is
    /// reported as a real failure.
    ///
    /// Isolated-backend, `SwiftPackageMacOSAdapter` only for now
    /// (`buildBaseline`/`buildMutant`, never `buildSchemataChunk`): the
    /// safety case above was only checked against that adapter's build
    /// shape.  Activation evidence is unaffected -- the same research
    /// reproduced `otool -s`'s `MachOCodeHash`-relevant sections
    /// byte-identical between a private-cache and an external-cache build
    /// of the same source at equal-length paths, now pinned as
    /// `SharedModuleCacheActivationEvidenceTests`.
    ///
    /// **Known limitation: not safe across concurrent runs on the same
    /// project with different destinations -- unchanged by the fingerprint
    /// namespacing above.** `WorkspaceManager.init`'s wipe is unconditional
    /// and keyed only on `scratchRoot` (`<projectRoot>/.mutantkit`, stable
    /// across runs, not per-run), while `RunIsolationLock` is keyed on
    /// `(projectRoot, destination)`, not on the module-cache path itself.
    /// Two concurrent `mutantkit run` invocations against the *same*
    /// project but *different* destinations therefore do not contend for
    /// the same lock, and the second one's constructor can wipe this cache
    /// out from under the first one's in-flight build. Namespacing by
    /// toolchain fingerprint does not fix this: both processes share the
    /// identical toolchain and therefore resolve the identical
    /// fingerprinted directory, and `SharedModuleCacheNamespace`'s own
    /// once-per-scratch-root reset is tracked in-process, so a *second*
    /// process's first resolution still cannot see the *first* process's
    /// already-completed reset and can still race it -- this closes the
    /// toolchain-*version* collision, not the concurrent-process one,
    /// which would need a cross-process lock (like `RunIsolationLock`
    /// itself) keyed on the cache path to fix. Do not enable this flag for
    /// a CI setup that runs multiple concurrent destinations against one
    /// project/scratch root; it is safe for the common case of one
    /// destination per project run.
    ///
    /// One half of that missing cross-process lock now exists:
    /// `SharedModuleCacheNamespace.forceRemove(_:)` -- the corruption-
    /// recovery delete `SwiftPackageMacOSAdapter.buildWithSharedCacheRecovery`
    /// falls back to -- refuses to delete a cache path unless this process
    /// itself won the exact `RunIsolationLock`-keyed-on-the-cache-path claim
    /// this paragraph originally called for, so a *second* concurrent
    /// process's corruption-recovery retry can no longer delete a directory
    /// the *first* process's build is still actively using. The reset-at-
    /// first-resolution race described above is a different code path
    /// (`WorkspaceManager.init`'s own wipe, and `SharedModuleCacheNamespace
    /// .moduleCachePath(forSandbox:workingDirectory:)`'s once-per-scratch-
    /// root reset) and is not covered by that claim -- both still run
    /// unconditionally on first use, regardless of whether the claim was
    /// won -- so the limitation above still holds for that path, and the
    /// same guidance (one destination per project run) still applies.
    public var sharedModuleCache: Bool
    /// Builds a one-time index, per `WorkspaceManager` instance (so once
    /// per run, not once per sandbox), of which directories under
    /// `projectRoot` contain zero content matching
    /// `WorkspaceManager.defaultExcludes` anywhere inside them, and reuses
    /// it across every sandbox that run creates: a directory the index
    /// proves clean is cloned with one whole-directory `clonefile(2)` call
    /// instead of `WorkspaceManager.populate`'s existing per-file walk. A
    /// directory the index cannot prove clean — because something inside
    /// it, at any depth, matches an exclude pattern — always falls back to
    /// that same per-file walk, unchanged; this flag only ever adds a
    /// faster path for content that would have been copied in full either
    /// way, it never changes what a sandbox ends up containing.
    ///
    /// Off by default, deliberately, though the case for it is stronger
    /// than `ExecutionSettings.sharedModuleCache`'s: this is *not* the
    /// "clone everything, then delete the excluded parts" approach
    /// `Research/isolated-build-reuse-2026-09`'s S2 follow-up measured and
    /// rejected outright (that one loses 3-11x on any project with real
    /// build output or an actively-committed `.git`, because deleting a
    /// cloned exclusion costs one syscall per entry that this flag's
    /// design never pays at all — it never clones excluded content in the
    /// first place). `WorkspaceManagerCleanSubtreeCloningTests` proves the
    /// output this flag produces has identical content and directory layout
    /// to today's default across several real project shapes, including one
    /// with a deeply nested excluded file and one with an internal symlink
    /// inside an otherwise clean subtree — but *not* identical POSIX
    /// permission bits on directories; see that suite's own doc comment for
    /// why not, and `CleanSubtreeIndex`'s for the mechanism. The 16x/4.09x
    /// speedup figures reported in `Research/isolated-build-reuse-2026-09/
    /// S2-clean-subtree-index-implementation.md` come from
    /// `probes/s2-clean-subtree-index-production.sh`'s Python
    /// reimplementation of the classification algorithm, not a timing of
    /// this Swift `CleanSubtreeIndex`/`WorkspaceManager` code — see that
    /// script's and that doc's own notes for the distinction.
    ///
    /// What keeps this an opt-in rather than the default anyway: the index
    /// is a *snapshot*, taken once, of directories that are clean as of
    /// the moment they are first classified. `WorkspaceManager.populate`'s
    /// existing per-entry walk re-checks every file against the exclude
    /// list fresh, on every single sandbox, so it always reflects
    /// `projectRoot`'s live state; a cached index does not. If something
    /// outside this tool's own control drops new excluded content into a
    /// directory this index already classified clean — a stray `.log` from
    /// a build run by hand in another terminal while a multi-hour
    /// mutation-testing run is still in progress, say — a sandbox created
    /// *after* that happens would clone it in, where today's design would
    /// not have. `WorkspaceManager` never writes into `projectRoot` itself
    /// (see that type's own doc comment — narrowly scoped to
    /// `WorkspaceManager`, since `retestKilledMutants`'s dependency-
    /// resolution preflight is a real, separate, intentional exception to
    /// the wider claim this comment used to make here), so nothing *this
    /// flag* does can trigger that gap — but nothing prevents something
    /// else on the machine (or another part of this tool, for an unrelated
    /// reason) from doing so during a run long enough for it to matter, and
    /// that is not a risk this pass found a way to prove away, only to
    /// reason about. A project root nobody else is touching during the run
    /// — the common case — sees no difference in output either way.
    public var cleanSubtreeCloning: Bool

    /// Whether `execution.profile: optimized`/`experimental` are *permitted*
    /// to bundle `measureCoverage` + `selectCoveringTests` into what those
    /// profiles auto-enable for an eligible project (see
    /// `ExecutionProfileFeature.perTestCoverageSelection` and
    /// `ExecutionProfileResolver.resolve`).
    ///
    /// **Off by default, and deliberately independent of `measureCoverage`/
    /// `selectCoveringTests` themselves.** Setting either of *those* two
    /// directly, by name, in `mutantkit.yml` already works exactly as their
    /// own doc comments describe, with or without this flag or any
    /// `execution.profile` — this flag changes nothing about what they do,
    /// only whether `optimized`/`experimental` are allowed to flip them on
    /// *for you*. An adversarial review found that `execution.profile:
    /// optimized` alone silently enabled both, which activates
    /// `MutationRunner`'s coverage fast path
    /// (`baseline.coverage`/`.isKnownUncovered`) and reclassifies a real
    /// surviving mutant on a genuinely-uncovered line as `.noCoverage` —
    /// excluded from `MutationScore.tested`'s denominator — without ever
    /// building or testing it, purely because a *speed* profile was chosen,
    /// with zero change to the actual test suite. `reference` (and
    /// `optimized` with this left off) still builds and tests that same
    /// mutant and correctly reports `.survived`, which does count against
    /// `tested`. That is a real, silent verdict and score change from
    /// choosing a profile alone — the opposite of every other feature
    /// `optimized` enables, each of which degrades to `reference` behaviour
    /// on its own whenever its precondition is not met (see
    /// `ExecutionProfile`'s own doc comment).
    ///
    /// `true` accepts that trade explicitly: a project that wants
    /// `optimized`'s per-test coverage speedup, and is fine treating a
    /// genuinely-uncovered mutant as `.noCoverage` (a more honest "this
    /// line was never exercised" signal — see `measureCoverage`'s own doc
    /// comment) rather than `.survived` (a real, if uninteresting, gap),
    /// sets this once, deliberately, alongside `execution.profile:
    /// optimized`. Never flips `measureCoverage`/`selectCoveringTests` on by
    /// itself with `execution.profile: reference` — it only ever relaxes
    /// what `optimized`/`experimental` are *permitted* to enable, exactly
    /// like every other eligibility check in
    /// `ExecutionProfileResolver.decisions(for:current:)`.
    public var profileCoverageSkip: Bool

    public init(
        profile: ExecutionProfile = .reference,
        strategy: ExecutionMode = .isolated,
        workers: Int? = nil,
        budget: BudgetSettings = BudgetSettings(),
        diffBase: String? = nil,
        measureCoverage: Bool = false,
        retestKilledMutants: Bool = false,
        confirmCrashKills: Bool = true,
        confirmTimedOutMutants: Bool = true,
        selectCoveringTests: Bool = false,
        incrementalBuild: Bool = false,
        earlyAbortSelectedTests: Bool = false,
        testBatchSize: Int? = nil,
        noOpCanarySampleRate: Double = 0,
        simulatorPool: Bool = false,
        sharedModuleCache: Bool = false,
        cleanSubtreeCloning: Bool = false,
        profileCoverageSkip: Bool = false
    ) {
        self.profile = profile
        self.strategy = strategy
        self.workers = workers
        self.budget = budget
        self.diffBase = diffBase
        self.measureCoverage = measureCoverage
        self.retestKilledMutants = retestKilledMutants
        self.confirmCrashKills = confirmCrashKills
        self.confirmTimedOutMutants = confirmTimedOutMutants
        self.selectCoveringTests = selectCoveringTests
        self.incrementalBuild = incrementalBuild
        self.earlyAbortSelectedTests = earlyAbortSelectedTests
        self.testBatchSize = testBatchSize
        self.noOpCanarySampleRate = noOpCanarySampleRate
        self.simulatorPool = simulatorPool
        self.sharedModuleCache = sharedModuleCache
        self.cleanSubtreeCloning = cleanSubtreeCloning
        self.profileCoverageSkip = profileCoverageSkip
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(ExecutionProfile.self, forKey: .profile) ?? .reference
        strategy = try container.decodeIfPresent(ExecutionMode.self, forKey: .strategy) ?? .isolated
        // `workers: auto` is friendlier YAML than omitting the key, so accept it.
        if let count = try? container.decodeIfPresent(Int.self, forKey: .workers) {
            workers = count
        } else {
            workers = nil
        }
        budget = try container.decodeIfPresent(BudgetSettings.self, forKey: .budget) ?? BudgetSettings()
        diffBase = try container.decodeIfPresent(String.self, forKey: .diffBase)
        measureCoverage = try container.decodeIfPresent(Bool.self, forKey: .measureCoverage) ?? false
        retestKilledMutants = try container.decodeIfPresent(Bool.self, forKey: .retestKilledMutants) ?? false
        confirmCrashKills = try container.decodeIfPresent(Bool.self, forKey: .confirmCrashKills) ?? true
        confirmTimedOutMutants = try container.decodeIfPresent(Bool.self, forKey: .confirmTimedOutMutants) ?? true
        selectCoveringTests = try container.decodeIfPresent(Bool.self, forKey: .selectCoveringTests) ?? false
        incrementalBuild = try container.decodeIfPresent(Bool.self, forKey: .incrementalBuild) ?? false
        earlyAbortSelectedTests = try container.decodeIfPresent(Bool.self, forKey: .earlyAbortSelectedTests) ?? false
        testBatchSize = try container.decodeIfPresent(Int.self, forKey: .testBatchSize)
        noOpCanarySampleRate = try container.decodeIfPresent(Double.self, forKey: .noOpCanarySampleRate) ?? 0
        simulatorPool = try container.decodeIfPresent(Bool.self, forKey: .simulatorPool) ?? false
        sharedModuleCache = try container.decodeIfPresent(Bool.self, forKey: .sharedModuleCache) ?? false
        cleanSubtreeCloning = try container.decodeIfPresent(Bool.self, forKey: .cleanSubtreeCloning) ?? false
        profileCoverageSkip = try container.decodeIfPresent(Bool.self, forKey: .profileCoverageSkip) ?? false
    }

    public func resolvedWorkerCount() -> Int {
        // Builds are the bottleneck and they are themselves parallel; more
        // workers than half the cores mostly buys contention.
        workers ?? max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
}
