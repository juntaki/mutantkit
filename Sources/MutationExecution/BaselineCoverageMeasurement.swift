import Foundation
import MutationModel

/// What a passed baseline's coverage step does, in one place: consult the
/// cross-run cache, measure per-test attribution only on a miss, report an
/// incomplete attribution, fall back to a whole-suite read, and account for
/// the time all of that took.
///
/// Shared by `MutationRunner.establishBaseline` and
/// `SharedBaselineEstablisher.establish`, which are otherwise deliberately
/// parallel implementations (see the latter's own doc comment for why that
/// separation exists and is worth keeping). This one step is the exception,
/// and for a specific reason rather than to reduce lines: it is the step
/// whose two copies must agree about cache semantics and about what a
/// *partial* attribution means. Two copies of "serve from cache, else
/// measure, else read the whole suite" is exactly how one of them ends up
/// deciding that a partial map may drive `.noCoverage` while the other does
/// not — and only one of those answers is safe.
public struct BaselineCoverageMeasurement: Sendable {
    public struct Result: Sendable {
        /// The per-test attribution, whether measured this run or served from
        /// the cache. `nil` when the adapter cannot attribute, or was not
        /// asked to.
        public let perTestCoverage: PerTestCoverageMap?
        /// The whole-suite coverage map the `.noCoverage` fast path is
        /// allowed to consult. `nil` whenever no map can honestly answer
        /// "the suite never reached this line" — including when the per-test
        /// attribution exists but is partial.
        public let coverage: CoverageMap?
        /// Wall clock spent measuring, and only measuring. `nil` when
        /// nothing was measured, which a cache hit is: the point of the cache
        /// is that this run did not pay the cost, and a record claiming
        /// otherwise would misreport where a run's time actually went.
        public let profilingDurationSeconds: Double?
    }

    let configuration: Configuration
    let cache: CoverageProfileCache?
    let cacheKey: CoverageProfileCache.Key?
    let operationalIssues: OperationalIssueLog?

    public init(
        configuration: Configuration,
        cache: CoverageProfileCache?,
        cacheKey: CoverageProfileCache.Key?,
        operationalIssues: OperationalIssueLog? = nil
    ) {
        self.configuration = configuration
        self.cache = cache
        self.cacheKey = cacheKey
        self.operationalIssues = operationalIssues
    }

    /// - Parameter artifact: the baseline's own already-built artifact. Only
    ///   the coverage step runs here; the build and the suite run that had to
    ///   pass before it are the caller's, and are not facts a cache can stand
    ///   in for.
    public func measure(
        with test: any TestAdapter,
        against artifact: BuildArtifact,
        in sandbox: URL,
        projectRoot: URL,
        timeoutSeconds: Double
    ) async -> Result {
        var perTestCoverage: PerTestCoverageMap?
        var coverage: CoverageMap?
        var profilingDurationSeconds: Double?

        if configuration.execution.selectCoveringTests {
            if let cacheKey, let cached = await cache?.load(cacheKey) {
                Self.note(
                    "coverage cache: hit — reusing the per-test attribution measured for this source tree, test " +
                        "suite and toolchain. The profiling pass is skipped."
                )
                perTestCoverage = cached
                coverage = cached.aggregate()
            } else if let selecting = test as? any TestSelecting {
                Self.note("coverage cache: \(Self.missReason(hasKey: cacheKey != nil, hasCache: cache != nil))")
                let profilingStarted = Date()
                perTestCoverage = await selecting.measurePerTestCoverage(
                    artifact: artifact, in: sandbox, timeoutSeconds: timeoutSeconds
                )
                if perTestCoverage == nil {
                    // The failure that cost a real project ~100 minutes,
                    // twice, in silence: the pass ran in full and attributed
                    // nothing, so nothing was narrowed and nothing was
                    // cached. Correct (the run falls back to testing every
                    // mutant against the whole suite) but expensive, and
                    // impossible to notice from the outside — the cache
                    // directory is simply never created.
                    Self.note(
                        "warning: per-test coverage could not be attributed for any test. Every mutant will run " +
                            "the full configured test list, and nothing was cached, so the next run measures again."
                    )
                }
                // `flatMap`, not `?.`: `aggregate()` is optional in its own
                // right and answers `nil` for a partial attribution, so the
                // `.noCoverage` fast path can never be driven by a map that
                // cannot rule a line out (see `aggregate()`'s own doc
                // comment). Flattened here so "no map at all" and "a map that
                // cannot answer the uncovered question" stay the single
                // `coverage == nil` case every caller already handles.
                coverage = perTestCoverage.flatMap { $0.aggregate() }
                profilingDurationSeconds = Date().timeIntervalSince(profilingStarted)
                if let measured = perTestCoverage, let cacheKey {
                    await cache?.store(measured, for: cacheKey)
                }
            }
            // After both branches, so a partial attribution served from the
            // cache is reported on every run that uses it, not only on the
            // run that happened to measure it.
            if let perTestCoverage {
                await PerTestCoverageAttribution.report(perTestCoverage, to: operationalIssues)
            }
        }

        if coverage == nil, configuration.execution.measureCoverage, let measuring = test as? any CoverageMeasuring {
            let profilingStarted = Date()
            coverage = await measuring.readCoverage(in: sandbox, projectRoot: projectRoot)
            profilingDurationSeconds = (profilingDurationSeconds ?? 0) + Date().timeIntervalSince(profilingStarted)
        }

        return Result(
            perTestCoverage: perTestCoverage, coverage: coverage, profilingDurationSeconds: profilingDurationSeconds
        )
    }

    /// Why this run is about to pay for the profiling pass rather than
    /// reusing a measurement.
    ///
    /// Named rather than reported as a bare "miss", because the three
    /// reasons call for completely different responses: an ordinary miss is
    /// expected on a first run and needs no action, a missing key means the
    /// digest could not be computed and *no* run will ever cache (a real,
    /// fixable problem, previously visible only as a raw error dump), and a
    /// missing cache means caching was disabled for this run.
    static func missReason(hasKey: Bool, hasCache: Bool) -> String {
        let measuring = "measuring per-test coverage"
        guard hasCache else { return "disabled for this run — \(measuring)." }
        guard hasKey else {
            return "unusable — this run's context digest could not be computed, so nothing can be reused or " +
                "stored. \(measuring) again."
        }
        return "miss — no measurement exists for this source tree, test suite and toolchain. \(measuring); " +
            "later runs against an unchanged tree reuse it."
    }

    /// Progress and cost notices go to stderr, never stdout: stdout carries
    /// the run's own reportable output, which `--report json` consumers
    /// parse. Same split every other diagnostic in this tool already makes.
    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
