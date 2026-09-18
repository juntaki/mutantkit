import Foundation
import MutationModel

/// One baseline (build the project unmutated, run the whole test suite
/// once, optionally measure per-test coverage), established once and
/// shared between backends — the mechanism `SchemataRunOrchestration`
/// uses to run this exactly once per `mutantkit run` invocation instead
/// of once per backend pass. Both passes previously built and ran
/// their own baseline independently; measured on a real iOS
/// project, that redundant work cost ~104s — about 9.5% of total
/// wall clock.
///
/// Mirrors `MutationRunner`'s own private `establishBaseline(in:startedAt:)`
/// exactly (build, test, coverage-cache-or-measure, in that order) —
/// deliberately a parallel implementation, not a refactor of either
/// existing runner's internals: `MutationRunner.establishBaseline()` and
/// `SchemataMutationRunner.establishBaseline()` are untouched for every
/// caller that does not inject a result here (a plain `mutantkit run
/// --strategy isolated`, or a schemata run with no fallback portion —
/// see each runner's own `preEstablishedBaseline` parameter), so neither
/// runner's independently-tested baseline logic is put at risk by this.
public enum SharedBaselineEstablisher {
    public enum Outcome: Sendable {
        case established(EstablishedBaseline)
        case failed(record: BaselineRecord, diagnosis: String)
    }

    public static func establish(
        build: any BuildAdapter,
        test: any TestAdapter,
        in sandbox: URL,
        configuration: Configuration,
        projectRoot: URL,
        coverageCache: CoverageProfileCache?,
        coverageCacheKey: CoverageProfileCache.Key?,
        operationalIssues: OperationalIssueLog? = nil
    ) async -> Outcome {
        let started = Date()
        let timeouts = TimeoutController(settings: configuration.timeouts)

        let artifact: BuildArtifact
        do {
            artifact = try await build.buildBaseline(in: sandbox)
        } catch let failure as BuildFailure {
            return .failed(
                record: unusableBaseline(startedAt: started),
                diagnosis: "The project does not build unmutated: \(failure.diagnosis)"
            )
        } catch {
            return .failed(
                record: unusableBaseline(startedAt: started),
                diagnosis: "The baseline build could not be run: \(error)"
            )
        }

        let testStarted = Date()
        let run: TestRunResult
        do {
            run = try await test.runBaseline(artifact, in: sandbox, timeoutSeconds: timeouts.baselineLimitSeconds)
        } catch {
            return .failed(
                record: unusableBaseline(startedAt: started, buildCommand: artifact.command),
                diagnosis: "The baseline test run could not be completed: \(error)"
            )
        }
        // Measured wall clock, never the reported test duration — see
        // `MutationRunner.establishBaseline(in:startedAt:)`'s own doc
        // comment for why (simulator boot/install/launch dwarfs the
        // assertions' own reported time on a small suite).
        let testDuration = Date().timeIntervalSince(testStarted)

        let record = BaselineRecord(
            passed: run.status == .passed,
            testSummary: run.summary,
            durationSeconds: Date().timeIntervalSince(started),
            buildProductHash: artifact.productHash,
            buildCommand: artifact.command,
            testCommand: run.command,
            buildDurationSeconds: testStarted.timeIntervalSince(started),
            testDurationSeconds: testDuration
        )

        guard run.status == .passed else {
            return .failed(
                record: record,
                diagnosis: """
                The unmutated suite did not pass (\(run.status.rawValue)): \(run.diagnosis) Every \
                mutant is measured against this run, so nothing can be concluded until it is green.
                """
            )
        }

        // The one step this establisher does *not* implement in parallel with
        // `MutationRunner.establishBaseline` -- see
        // `BaselineCoverageMeasurement`'s own doc comment for why this
        // particular step must not have two copies.
        let measured = await BaselineCoverageMeasurement(
            configuration: configuration, cache: coverageCache, cacheKey: coverageCacheKey,
            operationalIssues: operationalIssues
        ).measure(
            with: test, against: artifact, in: sandbox, projectRoot: projectRoot,
            timeoutSeconds: timeouts.baselineLimitSeconds
        )

        let recordWithProfiling = BaselineRecord(
            passed: record.passed,
            testSummary: record.testSummary,
            durationSeconds: record.durationSeconds,
            buildProductHash: record.buildProductHash,
            buildCommand: record.buildCommand,
            testCommand: record.testCommand,
            buildDurationSeconds: record.buildDurationSeconds,
            testDurationSeconds: record.testDurationSeconds,
            profilingDurationSeconds: measured.profilingDurationSeconds
        )

        return .established(EstablishedBaseline(
            record: recordWithProfiling,
            testDurationSeconds: testDuration,
            perTestCoverage: measured.perTestCoverage,
            coverage: measured.coverage
        ))
    }

    private static func unusableBaseline(startedAt: Date, buildCommand: CommandRecord? = nil) -> BaselineRecord {
        BaselineRecord(
            passed: false,
            testSummary: nil,
            durationSeconds: Date().timeIntervalSince(startedAt),
            buildProductHash: nil,
            buildCommand: buildCommand,
            testCommand: nil
        )
    }
}

/// One backend-agnostic established baseline — everything both
/// `MutationRunner` and `SchemataMutationRunner` need from it. See
/// `SharedBaselineEstablisher`'s own doc comment for why this exists.
public struct EstablishedBaseline: Sendable {
    public let record: BaselineRecord
    /// The real, measured wall-clock baseline test duration — carried
    /// separately from `record.testDurationSeconds` (`Double?`, for
    /// `Codable` robustness reasons unrelated to this type) so a consumer
    /// on this path never has to unwrap an optional that is never actually
    /// absent here.
    public let testDurationSeconds: Double
    public let perTestCoverage: PerTestCoverageMap?
    public let coverage: CoverageMap?

    public init(record: BaselineRecord, testDurationSeconds: Double, perTestCoverage: PerTestCoverageMap?, coverage: CoverageMap?) {
        self.record = record
        self.testDurationSeconds = testDurationSeconds
        self.perTestCoverage = perTestCoverage
        self.coverage = coverage
    }
}
