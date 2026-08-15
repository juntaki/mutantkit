import Foundation

/// User configuration, as written in `mutantkit.yml`.
///
/// `Codable` and format-agnostic: the CLI decodes it with Yams, tests decode the
/// same type from JSON. Every field has a default so a minimal config file stays
/// minimal, and `configurationHash` over the *resolved* value is what gets
/// recorded in the plan.
public struct Configuration: Codable, Sendable, Hashable {
    public var version: Int
    public var project: ProjectSettings
    public var sources: SourceSettings
    public var tests: TestSettings
    public var operators: OperatorSettings
    public var execution: ExecutionSettings
    public var timeouts: TimeoutSettings
    public var reports: [ReportKind]
    /// CI merge-decision policy. Not read by `plan`/`run`, only by `gate` —
    /// see `QualityGateSettings`'s own comment for why it is excluded from
    /// `configurationHash`.
    public var qualityGate: QualityGateSettings

    public init(
        version: Int = 1,
        project: ProjectSettings = ProjectSettings(),
        sources: SourceSettings = SourceSettings(),
        tests: TestSettings = TestSettings(),
        operators: OperatorSettings = OperatorSettings(),
        execution: ExecutionSettings = ExecutionSettings(),
        timeouts: TimeoutSettings = TimeoutSettings(),
        reports: [ReportKind] = [.console, .json],
        qualityGate: QualityGateSettings = QualityGateSettings()
    ) {
        self.version = version
        self.project = project
        self.sources = sources
        self.tests = tests
        self.operators = operators
        self.execution = execution
        self.timeouts = timeouts
        self.reports = reports
        self.qualityGate = qualityGate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        project = try container.decodeIfPresent(ProjectSettings.self, forKey: .project) ?? ProjectSettings()
        sources = try container.decodeIfPresent(SourceSettings.self, forKey: .sources) ?? SourceSettings()
        tests = try container.decodeIfPresent(TestSettings.self, forKey: .tests) ?? TestSettings()
        operators = try container.decodeIfPresent(OperatorSettings.self, forKey: .operators) ?? OperatorSettings()
        execution = try container.decodeIfPresent(ExecutionSettings.self, forKey: .execution) ?? ExecutionSettings()
        timeouts = try container.decodeIfPresent(TimeoutSettings.self, forKey: .timeouts) ?? TimeoutSettings()
        reports = try container.decodeIfPresent([ReportKind].self, forKey: .reports) ?? [.console, .json]
        qualityGate = try container.decodeIfPresent(QualityGateSettings.self, forKey: .qualityGate) ?? QualityGateSettings()
    }

    /// Hash of the canonical JSON encoding. Goes into the plan so that a plan
    /// executed under different settings is detectable rather than merely
    /// surprising. `qualityGate` is deliberately zeroed out first: it is pure
    /// CI merge policy, checked only at `gate` time, and must not make an
    /// otherwise-identical plan look different just because a threshold
    /// changed.
    public var configurationHash: String {
        var hashed = self
        hashed.qualityGate = QualityGateSettings()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(hashed) else { return ContentHash.of("<unencodable>") }
        return ContentHash.of(data)
    }
}

// MARK: - Project

public enum ProjectKind: String, Codable, Sendable {
    /// Detect from the directory contents. What `init` writes by default.
    case auto
    /// Swift package tested with `swift test` on the host.
    case swiftPackageMacOS
    /// Swift package for a non-host Apple platform (e.g. UIKit-dependent code).
    /// Needs `xcodebuild` against a simulator destination — `swift test` alone
    /// runs on the host toolchain and cannot see these frameworks.
    case swiftPackageApple
    case xcodeProject
    case xcodeWorkspace
}

public struct ProjectSettings: Codable, Sendable, Hashable {
    public var kind: ProjectKind
    public var path: String?
    public var scheme: String?
    public var destination: String?
    public var derivedDataPath: String?

    public init(
        kind: ProjectKind = .auto,
        path: String? = nil,
        scheme: String? = nil,
        destination: String? = nil,
        derivedDataPath: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.scheme = scheme
        self.destination = destination
        self.derivedDataPath = derivedDataPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind) ?? .auto
        path = try container.decodeIfPresent(String.self, forKey: .path)
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
        destination = try container.decodeIfPresent(String.self, forKey: .destination)
        derivedDataPath = try container.decodeIfPresent(String.self, forKey: .derivedDataPath)
    }
}

// MARK: - Sources

public struct SourceSettings: Codable, Sendable, Hashable {
    public var include: [String]
    public var exclude: [String]

    public init(include: [String] = ["Sources/**"], exclude: [String] = defaultExcludes) {
        self.include = include
        self.exclude = exclude
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        include = try container.decodeIfPresent([String].self, forKey: .include) ?? ["Sources/**"]
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? Self.defaultExcludes
    }

    /// Generated and mock code produces mutants nobody will ever act on, which
    /// is the main way a mutation report becomes noise people stop reading.
    public static let defaultExcludes = [
        "**/Generated/**",
        "**/*.generated.swift",
        "**/*Mock*.swift",
        "**/*Mocks*.swift",
        "**/.build/**",
        "**/DerivedData/**",
        "**/Pods/**",
        "**/Carthage/**"
    ]
}

// MARK: - Tests

public struct TestSettings: Codable, Sendable, Hashable {
    public var targets: [String]
    /// Extra arguments appended to the test invocation, as a list — never a
    /// shell string.
    public var extraArguments: [String]
    /// Run a Swift package's tests in parallel (`swift test --parallel`).
    ///
    /// **Off by default, and the default is the safe one.** Turning this on buys
    /// better diagnostics at the cost of a real correctness hazard, so it is the
    /// user's decision to make, not ours to make for them.
    ///
    /// What it buys: SwiftPM only writes the XCTest half of `--xunit-output`
    /// when tests run in parallel. Serially, an XCTest package reports no counts
    /// at all, so `inspect` cannot say which test caught a mutant. Outcomes stay
    /// correct either way — the verdict comes from the exit code — but the
    /// detail is lost.
    ///
    /// What it risks: a suite that is not parallel-safe flakes. A flaky failure
    /// during a mutant's run is indistinguishable from the mutant being caught,
    /// so it is recorded as `killedByAssertion` and the mutation score is
    /// silently inflated. An inflated score is the specific lie this tool exists
    /// to prevent, and unlike a missing count it announces nothing.
    ///
    /// Only enable it if your suite already passes reliably under
    /// `swift test --parallel`.
    public var parallel: Bool

    public init(targets: [String] = [], extraArguments: [String] = [], parallel: Bool = false) {
        self.targets = targets
        self.extraArguments = extraArguments
        self.parallel = parallel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targets = try container.decodeIfPresent([String].self, forKey: .targets) ?? []
        extraArguments = try container.decodeIfPresent([String].self, forKey: .extraArguments) ?? []
        parallel = try container.decodeIfPresent(Bool.self, forKey: .parallel) ?? false
    }
}

// MARK: - Operators

public struct OperatorSettings: Codable, Sendable, Hashable {
    public var profile: OperatorProfile
    public var disable: [String]
    public var enable: [String]

    public init(profile: OperatorProfile = .default, disable: [String] = [], enable: [String] = []) {
        self.profile = profile
        self.disable = disable
        self.enable = enable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(OperatorProfile.self, forKey: .profile) ?? .default
        disable = try container.decodeIfPresent([String].self, forKey: .disable) ?? []
        enable = try container.decodeIfPresent([String].self, forKey: .enable) ?? []
    }
}

// MARK: - Execution

/// How a budget narrows the discovered set down to `maxMutants`.
///
/// `nil` on `BudgetSettings.stratifyBy` preserves the original two-strategy
/// split (a `seed` draws a pure random sample; its absence round-robins by
/// file then operator) — existing configs and their exact selections are
/// unaffected by this type's addition. `.subtype` is the only case: it
/// stratifies by operator *and* by the exact original → replacement pair,
/// not just the operator. An operator that emits several distinct
/// replacements — relational-operator-replacement emits ten — is really
/// several different claims about the source, and a sample that does not
/// separate them lets whichever pair is most common in the codebase crowd
/// out the rest, exactly as an unstratified sample would. Reproducible from
/// `(plan, seed)`: the same seed always draws the same mutants, but two
/// seeds draw two different within-stratum orderings, never two different
/// sets of strata.
public enum BudgetStratification: String, Codable, Sendable {
    /// Stratifies by operator *and* by the exact original → replacement
    /// pair, round-robin over strata in **alphabetical stratum-key order**.
    /// That fixed order is a real limitation, not just a historical quirk:
    /// when the number of distinct strata exceeds the budget, the strata
    /// that sort later never contribute at all, regardless of how common
    /// they are — this is what happened measuring `ternary-branch-swap` and
    /// `unary-not-removal` against a real project (0 of either sampled out
    /// of a 1242-candidate pool at a 100-mutant budget; see the internal
    /// corpus-validation notes' "Corpus sampling caveats" section, not part
    /// of this public repo). A seed only decides which *member* of an
    /// already-included stratum is drawn, never which strata are included.
    /// Kept exactly as-is — this is what makes it additive rather than a
    /// silent behavior change for every existing config that set it.
    case subtype
    /// Balances by operator first, then by subtype within each operator —
    /// see `BudgetSettings.minimumPerOperator` and
    /// `BudgetSelector.selectByOperatorSubtype` for the full contract. Unlike
    /// `.subtype`, every ordering decision this mode makes — which
    /// operators are included when the budget can't cover all of them,
    /// which subtypes are included within an operator's slice, and which
    /// members are drawn — is a function of `seed`, not of alphabetical
    /// sort order.
    case operatorSubtype
}

/// Opt-in switch between v1's `stratifyBy`-driven selection and Budget
/// Selection v2's two-level allocator (ADR-0007). `nil`/`.v1` (the default)
/// keeps `stratifyBy`/`minimumPerOperator` in full effect, byte-identical to
/// existing configs (ADR-0007 invariant 8, Choice 1 — v2 ships opt-in only
/// this milestone). `.v2` routes through `BudgetSelectorV2` instead, using
/// `minimumPerStratum`/`weight` and ignoring `stratifyBy`/`minimumPerOperator`.
public enum BudgetSelectionAlgorithm: String, Codable, Sendable {
    case v1
    case v2
}

public struct BudgetSettings: Codable, Sendable, Hashable {
    public var maxMutants: Int?
    public var maxDurationSeconds: Double?
    /// Required if `maxMutants` is set and selection must sample — determinism
    /// is the default, so any randomness has to be named explicitly.
    public var seed: UInt64?
    public var stratifyBy: BudgetStratification?
    /// Minimum mutants reserved per enabled operator with >=1 eligible
    /// candidate, under `stratifyBy: .operatorSubtype`. Defaults to 1 —
    /// enough to get *some* signal per operator, which is the entire point
    /// of that mode. Ignored under `.subtype` and `nil`. Ignored entirely
    /// under `selection: .v2` — see `minimumPerStratum`.
    public var minimumPerOperator: Int?
    /// Opts into Budget Selection v2 (ADR-0007). See
    /// `BudgetSelectionAlgorithm`'s doc comment.
    public var selection: BudgetSelectionAlgorithm?
    /// `selection: .v2` only: the outer stratum's (operator's) Phase 1
    /// minimum-reservation floor — the v2 analogue of `minimumPerOperator`.
    /// Defaults to 1 when `.v2` is active and this is unset. Ignored under
    /// `.v1`/`nil`.
    public var minimumPerStratum: Int?
    /// `selection: .v2` only: optional per-operator Phase 2 weight (ADR-0007
    /// B.3), keyed by operator ID. Empty/unset means equal-share. If any
    /// entry is configured, every operator with an eligible candidate must
    /// be configured — a partial configuration is a config-load error (see
    /// `BudgetSelectorV2.validateWeightConfiguration`). Ignored under
    /// `.v1`/`nil`.
    public var weight: [String: Int]?

    public init(
        maxMutants: Int? = nil,
        maxDurationSeconds: Double? = nil,
        seed: UInt64? = nil,
        stratifyBy: BudgetStratification? = nil,
        minimumPerOperator: Int? = nil,
        selection: BudgetSelectionAlgorithm? = nil,
        minimumPerStratum: Int? = nil,
        weight: [String: Int]? = nil
    ) {
        self.maxMutants = maxMutants
        self.maxDurationSeconds = maxDurationSeconds
        self.seed = seed
        self.stratifyBy = stratifyBy
        self.minimumPerOperator = minimumPerOperator
        self.selection = selection
        self.minimumPerStratum = minimumPerStratum
        self.weight = weight
    }

    /// `sampling`/`stratifyWithinOperatorBy` were a same-day-superseded
    /// design: `sampling: balancedByOperator` + `stratifyWithinOperatorBy`
    /// shipped and were replaced by `stratifyBy: operatorSubtype` +
    /// `minimumPerOperator` before either key was used in any committed
    /// config. Decoding them silently (as unknown-key-ignored) would let a
    /// config written against the old key names quietly stop balancing by
    /// operator at all — the exact silent starvation this mode exists to
    /// prevent — so they decode as an explicit, actionable error instead.
    private enum LegacyCodingKeys: String, CodingKey {
        case sampling
        case stratifyWithinOperatorBy
    }

    public init(from decoder: Decoder) throws {
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if legacy.contains(.sampling) || legacy.contains(.stratifyWithinOperatorBy) {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: legacy.codingPath,
                debugDescription: """
                execution.budget.sampling and execution.budget.stratifyWithinOperatorBy no longer \
                exist. Replace `sampling: balancedByOperator` with `stratifyBy: operatorSubtype` \
                (and move any `minimumPerOperator` to execution.budget directly, if not already \
                there); `stratifyWithinOperatorBy` has no replacement — subtype stratification is \
                unconditional under `stratifyBy: operatorSubtype`.
                """
            ))
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxMutants = try container.decodeIfPresent(Int.self, forKey: .maxMutants)
        maxDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .maxDurationSeconds)
        seed = try container.decodeIfPresent(UInt64.self, forKey: .seed)
        stratifyBy = try container.decodeIfPresent(BudgetStratification.self, forKey: .stratifyBy)
        minimumPerOperator = try container.decodeIfPresent(Int.self, forKey: .minimumPerOperator)
        selection = try container.decodeIfPresent(BudgetSelectionAlgorithm.self, forKey: .selection)
        minimumPerStratum = try container.decodeIfPresent(Int.self, forKey: .minimumPerStratum)
        weight = try container.decodeIfPresent([String: Int].self, forKey: .weight)
    }
}

public struct ExecutionSettings: Codable, Sendable, Hashable {
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

    public init(
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
        testBatchSize: Int? = nil
    ) {
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
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
    }

    public func resolvedWorkerCount() -> Int {
        // Builds are the bottleneck and they are themselves parallel; more
        // workers than half the cores mostly buys contention.
        workers ?? max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
}

// MARK: - Timeouts

public enum TimeoutStrategy: String, Codable, Sendable {
    /// Fixed `maximum` for every mutant.
    case fixed
    /// Derived from the observed baseline duration times `multiplier`, clamped
    /// to [`minimum`, `maximum`].
    case adaptive
}

public struct MutantTimeoutSettings: Codable, Sendable, Hashable {
    public var strategy: TimeoutStrategy
    public var multiplier: Double
    public var minimumSeconds: Double
    public var maximumSeconds: Double
    /// Flat time added to the adaptive limit, on top of `baseline × multiplier`.
    ///
    /// The baseline measures a suite that *passes*. A mutant that gets killed
    /// makes it fail, and failing costs extra fixed work that the baseline never
    /// paid for: xcodebuild collects diagnostics and attachments and finishes
    /// writing the result bundle. That cost is additive and does not shrink with
    /// the suite, so on a small suite a pure multiplier under-budgets precisely
    /// the mutants that are about to be killed — reporting them as `timedOut`,
    /// which is excluded from the score. Killed mutants would then quietly
    /// disappear from both sides of the ratio.
    public var overheadAllowanceSeconds: Double

    public init(
        strategy: TimeoutStrategy = .adaptive,
        multiplier: Double = 3,
        minimumSeconds: Double = 30,
        maximumSeconds: Double = 300,
        overheadAllowanceSeconds: Double = 60
    ) {
        self.strategy = strategy
        self.multiplier = multiplier
        self.minimumSeconds = minimumSeconds
        self.maximumSeconds = maximumSeconds
        self.overheadAllowanceSeconds = overheadAllowanceSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        strategy = try container.decodeIfPresent(TimeoutStrategy.self, forKey: .strategy) ?? .adaptive
        multiplier = try container.decodeIfPresent(Double.self, forKey: .multiplier) ?? 3
        minimumSeconds = try DurationDecoding.seconds(container, .minimum) ?? 30
        maximumSeconds = try DurationDecoding.seconds(container, .maximum) ?? 300
        overheadAllowanceSeconds = try DurationDecoding.seconds(container, .overheadAllowance) ?? 60
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(strategy, forKey: .strategy)
        try container.encode(multiplier, forKey: .multiplier)
        try container.encode(minimumSeconds, forKey: .minimum)
        try container.encode(maximumSeconds, forKey: .maximum)
        try container.encode(overheadAllowanceSeconds, forKey: .overheadAllowance)
    }

    enum CodingKeys: String, CodingKey {
        case strategy, multiplier, minimum, maximum, overheadAllowance
    }

    /// Resolves the wall-clock limit for one mutant given the measured baseline.
    ///
    /// A mutant that removes a `resume` on a continuation hangs forever; this
    /// number is the only thing that ends it. It has to be generous enough that a
    /// `timedOut` means "this mutant hangs" rather than "the limit was too tight",
    /// because the two are indistinguishable in the result and only the first is
    /// worth telling anyone about.
    public func resolve(baselineDuration: Double) -> Double {
        switch strategy {
        case .fixed:
            maximumSeconds
        case .adaptive:
            // Scale with the suite, then add the flat cost of failing.
            min(max(baselineDuration * multiplier + overheadAllowanceSeconds, minimumSeconds), maximumSeconds)
        }
    }
}

public struct TimeoutSettings: Codable, Sendable, Hashable {
    public var baselineSeconds: Double
    public var mutant: MutantTimeoutSettings
    /// How long a process group gets to exit on SIGTERM before SIGKILL.
    public var terminationGracePeriodSeconds: Double

    public init(
        baselineSeconds: Double = 600,
        mutant: MutantTimeoutSettings = MutantTimeoutSettings(),
        terminationGracePeriodSeconds: Double = 5
    ) {
        self.baselineSeconds = baselineSeconds
        self.mutant = mutant
        self.terminationGracePeriodSeconds = terminationGracePeriodSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baselineSeconds = try DurationDecoding.seconds(container, .baseline) ?? 600
        mutant = try container.decodeIfPresent(MutantTimeoutSettings.self, forKey: .mutant)
            ?? MutantTimeoutSettings()
        terminationGracePeriodSeconds = try container.decodeIfPresent(
            Double.self, forKey: .terminationGracePeriod
        ) ?? 5
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baselineSeconds, forKey: .baseline)
        try container.encode(mutant, forKey: .mutant)
        try container.encode(terminationGracePeriodSeconds, forKey: .terminationGracePeriod)
    }

    enum CodingKeys: String, CodingKey {
        case baseline, mutant, terminationGracePeriod
    }
}

/// Decodes a duration written either as a number of seconds or as `10m`/`90s`.
///
/// Both spellings are accepted because a config file is written by hand: `2m` is
/// what someone means, and `120` is what they will paste from a script.
enum DurationDecoding {
    static func seconds<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        _ key: Key
    ) throws -> Double? {
        // A numeric value decodes directly; a string one makes this throw, which
        // is the signal to try parsing it as a duration literal instead.
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return DurationParser.seconds(from: text)
    }
}

/// Parses `10m`, `90s`, `1h30m` and bare numbers (seconds) from config.
public enum DurationParser {
    public static func seconds(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let bare = Double(trimmed) { return bare }

        var total: Double = 0
        var current = ""
        var matched = false

        for character in trimmed {
            if character.isNumber || character == "." {
                current.append(character)
                continue
            }
            guard let value = Double(current) else { return nil }
            let multiplier: Double
            switch character {
            case "h": multiplier = 3600
            case "m": multiplier = 60
            case "s": multiplier = 1
            default: return nil
            }
            total += value * multiplier
            current = ""
            matched = true
        }

        return matched && current.isEmpty ? total : nil
    }
}

// MARK: - Reports

public enum ReportKind: String, Codable, Sendable, CaseIterable {
    case console
    case xcode
    case json
    case strykerJSON = "stryker-json"
    case html
    case ciSummary = "ci-summary"
}

// MARK: - Quality gate

/// CI merge-decision policy, checked out separately at `gate` time — see
/// `GateCommand` and `QualityGateThresholds`. Deliberately excluded from
/// `Configuration.configurationHash` (see that property's own comment):
/// tightening or loosening a CI threshold does not change what gets
/// mutated, so it must not invalidate an in-progress plan or checkpoint.
public struct QualityGateSettings: Codable, Sendable, Hashable {
    public struct ScoreThreshold: Codable, Sendable, Hashable {
        /// Percent, e.g. `70` for 70%.
        public var minimum: Double?

        public init(minimum: Double? = nil) {
            self.minimum = minimum
        }
    }

    public struct RegressionThreshold: Codable, Sendable, Hashable {
        /// Percentage points, e.g. `2` for 2%. Requires `gate --baseline`.
        public var maximumDrop: Double?

        public init(maximumDrop: Double? = nil) {
            self.maximumDrop = maximumDrop
        }
    }

    public struct SurvivedThreshold: Codable, Sendable, Hashable {
        public var newMaximum: Int?

        public init(newMaximum: Int? = nil) {
            self.newMaximum = newMaximum
        }
    }

    public struct IntegrityThreshold: Codable, Sendable, Hashable {
        /// Written for symmetry with the other four keys, not because a
        /// nonzero tolerance is supported: the gate already fails closed
        /// on any integrity violation unconditionally (see
        /// `QualityGate.evaluate`), and `ConfigurationLoader`/`gate` reject
        /// any value here other than `0` rather than silently accept a
        /// setting that would weaken that guarantee.
        public var maximum: Int?

        public init(maximum: Int? = nil) {
            self.maximum = maximum
        }
    }

    public var testedScore: ScoreThreshold?
    public var effectiveScore: ScoreThreshold?
    public var regression: RegressionThreshold?
    public var survived: SurvivedThreshold?
    public var integrityViolations: IntegrityThreshold?

    public init(
        testedScore: ScoreThreshold? = nil,
        effectiveScore: ScoreThreshold? = nil,
        regression: RegressionThreshold? = nil,
        survived: SurvivedThreshold? = nil,
        integrityViolations: IntegrityThreshold? = nil
    ) {
        self.testedScore = testedScore
        self.effectiveScore = effectiveScore
        self.regression = regression
        self.survived = survived
        self.integrityViolations = integrityViolations
    }

    /// Converts to the fraction/count-based thresholds `QualityGate.evaluate`
    /// actually checks. Throws if `integrityViolations.maximum` is set to
    /// anything but `0` (see that field's own comment).
    public func resolvedThresholds() throws -> QualityGateThresholds {
        if let maximum = integrityViolations?.maximum, maximum != 0 {
            throw QualityGateSettingsError.nonzeroIntegrityTolerance(maximum)
        }
        return QualityGateThresholds(
            minimumTested: testedScore?.minimum.map { $0 / 100 },
            minimumEffective: effectiveScore?.minimum.map { $0 / 100 },
            maximumSurvivors: nil,
            regressionMaximumDrop: regression?.maximumDrop.map { $0 / 100 },
            newSurvivorsMaximum: survived?.newMaximum
        )
    }
}

public enum QualityGateSettingsError: Error, CustomStringConvertible {
    case nonzeroIntegrityTolerance(Int)

    public var description: String {
        switch self {
        case let .nonzeroIntegrityTolerance(value):
            "qualityGate.integrityViolations.maximum must be 0 (found \(value)): MutantKit always "
                + "fails closed on an integrity violation, and this cannot be configured to tolerate one."
        }
    }
}
