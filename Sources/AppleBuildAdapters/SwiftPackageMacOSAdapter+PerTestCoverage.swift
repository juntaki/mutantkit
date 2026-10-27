import Foundation
import MutationExecution
import MutationModel

// MARK: - Per-test coverage measurement

extension SwiftPackageMacOSAdapter {
    /// Runs every test `swift test list` reports, one at a time, with
    /// coverage enabled, against the artifact already built for the
    /// baseline — no separate coverage build step: `swift test
    /// --enable-code-coverage` re-instruments as a side effect the same way
    /// `runBaseline`'s own coverage pass already relies on (see its doc
    /// comment above), so only the first of these per-test invocations needs
    /// to pay for that one-shot rebuild. Every later one passes `skipBuild:
    /// true` explicitly — sources never change between iterations of this
    /// loop, so there is nothing for SwiftPM's own build-graph check to
    /// find, and skipping it outright avoids paying for that check on every
    /// one of what can be hundreds of invocations, with no change to what
    /// coverage gets attributed to which test (confirmed: `swift test
    /// --skip-build --enable-code-coverage` still exports a fresh, correct,
    /// unaccumulated `codecov/*.json` per invocation). Each individual run's
    /// codecov JSON is read right after that run finishes and merged into a
    /// reverse index.
    ///
    /// A one-time cost paid once per execution, not per mutant: worth it on
    /// a real project, where the fixed cost of re-running an entire suite
    /// dominates every mutant's wall clock regardless of how few tests
    /// actually exercise the mutated line.
    ///
    /// The retry, and what becomes of a test that still cannot be proven,
    /// are `PerTestCoverageAttribution.attribute`'s — see its doc comment,
    /// and `PerTestCoverageMap`'s, for the policy and why it is safe. Two
    /// things specific to this adapter. The failure class includes a
    /// selection SwiftPM silently ran zero of (P12-B Finding A/B/C, before
    /// this adapter's own filter and `classify` fixes), which is why
    /// `reliableExpectedTestCount` is passed below. And a test that
    /// legitimately covers nothing — a genuine, successfully-read empty
    /// `CoverageMap` — is *not* that failure class here, unlike in
    /// `XcodeBuildAdapter`: it is fully attributed, contributing no lines.
    /// - Parameter artifact: `runBaseline`'s own, uninstrumented artifact —
    ///   unused here beyond satisfying the protocol; test identifiers come
    ///   from `swift test list`, not from the artifact, and per-test
    ///   coverage needs its own coverage-instrumented run regardless of what
    ///   `artifact` was built with.
    func measurePerTestCoverageSerial(
        artifact: BuildArtifact,
        in workspace: URL,
        timeoutSeconds: Double
    ) async -> PerTestCoverageMap? {
        let enumerated = await Self.enumerateTestIdentifiers(
            in: resolvedWorkspace(workspace),
            timeoutSeconds: timeoutSeconds,
            terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
        )
        let tests = Self.scope(enumerated, toConfiguredTargets: configuration.tests.targets)
        guard !tests.isEmpty else { return nil }

        // A static initializer has no coverage record of its own; wrapped, the build records it.
        let instrumentation = await instrumentStaticInitializers(in: workspace, timeoutSeconds: timeoutSeconds)
        defer { instrumentation?.restore() }

        // The loop, the retry policy and what becomes of a test that cannot
        // be proven are all `PerTestCoverageAttribution`'s -- see its doc
        // comment. What is adapter-specific, and all that is left
        // here, is how one test is run and how its coverage is read back.
        let granularity = configuration.execution.coverageGranularity
        let suiteSizes = Self.suiteSizes(of: tests)
        let attempts = 2
        let slots = CoverageSlots()
        let attempt = coverageAttempt(
            workspace: workspace, timeoutSeconds: timeoutSeconds, slots: slots,
            granularity: granularity, suiteSizes: suiteSizes, attempts: attempts
        )
        let progress = ProgressReporter(total: tests.count, label: "per-test coverage")
        let workers = max(1, configuration.execution.coverageWorkers ?? 1)
        guard workers > 1 else {
            return await PerTestCoverageAttribution.attribute(
                tests: tests, source: "swiftpm-codecov-per-test", attempts: attempts, progress: progress
            ) { test, attemptNumber in await attempt(test, attemptNumber, 0) }
        }

        let packageDirectory = resolvedWorkspace(workspace)
        defer { for scratch in slots.all { try? FileManager.default.removeItem(at: scratch) } }
        return await PerTestCoverageAttribution.attributeConcurrently(
            tests: tests, source: "swiftpm-codecov-per-test", attempts: attempts, workers: workers, progress: progress,
            groupKey: { test in
                // A suite measured once for all its tests is one group; a test measured alone is its own.
                Self.coverageUnit(for: test, granularity: granularity, suiteSizes: suiteSizes).suiteKey
                    ?? test.swiftTestFilterArgument
            },
            prepareSlot: { slot in
                // Only once the instrumented build exists: a clone of anything earlier would carry nothing to run.
                guard slots.artifactBuilt else { return false }
                let scratch = packageDirectory.appendingPathComponent(".build-coverage-slot-\(slot)", isDirectory: true)
                try? FileManager.default.removeItem(at: scratch)
                guard Self.cloneDirectory(packageDirectory.appendingPathComponent(".build", isDirectory: true), to: scratch)
                else { return false }
                slots.register(scratch, for: slot)
                return true
            },
            attempt: attempt
        )
    }

    /// Measures one test, retrying through the suite memo: a suite is run once and its outcome
    /// shared by every test in it. A failure is only remembered after the last attempt, so the
    /// retry policy still gets its second try at the suite.
    private func coverageAttempt(
        workspace: URL, timeoutSeconds: Double, slots: CoverageSlots,
        granularity: CoverageGranularity, suiteSizes: [String: Int], attempts: Int
    ) -> @Sendable (TestIdentifier, Int, Int) async -> CoverageMap? {
        let suiteMemo = SuiteCoverageMemo()
        let measure = coverageUnitMeasurer(workspace: workspace, timeoutSeconds: timeoutSeconds, slots: slots)
        return { test, attemptNumber, slot in
            let unit = Self.coverageUnit(for: test, granularity: granularity, suiteSizes: suiteSizes)
            guard let suiteKey = unit.suiteKey else { return await measure(unit, slot) }

            switch suiteMemo.outcome(for: suiteKey) {
            case let .measured(map): return map
            case .failed: return nil
            case nil: break
            }
            let map = await measure(unit, slot)
            if let map {
                suiteMemo.record(.measured(map), for: suiteKey)
            } else if attemptNumber >= attempts {
                suiteMemo.record(.failed, for: suiteKey)
            }
            return map
        }
    }

    /// One test, or (`coverageGranularity: suite`) one whole suite, run in isolation with coverage;
    /// the coverage read back is what gets credited. Slot 0 runs in the sandbox itself; every other
    /// slot runs the same already-built products from its own clone, so concurrent runs never share
    /// coverage output.
    private func coverageUnitMeasurer(
        workspace: URL, timeoutSeconds: Double, slots: CoverageSlots
    ) -> @Sendable (CoverageUnit, Int) async -> CoverageMap? {
        let packageDirectory = resolvedWorkspace(workspace)
        return { unit, slot in
            let scratch = slot == 0 ? nil : slots.scratchPath(for: slot)
            if slot != 0, scratch == nil { return nil }
            // Set only once a coverage-enabled run has completed *and* its coverage was actually
            // read -- not merely after an attempt finished. A failed attempt (build error, infra
            // failure, unreadable coverage) must never leave a later iteration skipping the build
            // against an artifact that may not exist or may be stale.
            guard let run = try? await self.runTests(
                in: scratch == nil ? workspace : packageDirectory,
                timeoutSeconds: timeoutSeconds,
                enableCoverage: true,
                skipBuild: scratch == nil ? slots.artifactBuilt : true,
                testFilters: [unit.filter],
                reliableExpectedTestCount: unit.expectedTestCount,
                scratchPath: scratch
            ) else { return nil }
            // `runTests`'s xunit report path is unique per invocation (never reused by a later
            // iteration), and this loop never preserves it as evidence afterward: once this
            // iteration is done with it, it is pure disk usage a project with many discovered
            // tests would otherwise accumulate one report pair per test.
            let skippedCount = run.resultArtifactPath.flatMap { XUnitParser.swiftTestingSkippedCount(forRequestedOutput: $0) }
            Self.removeXUnitReports(at: run.resultArtifactPath)
            // Tests that ran as skipped execute nothing, here and in every mutant run under the same
            // configuration, so they cover nothing. Leaving them unattributed would put them in every
            // mutant's selection, where they can never run and fail the shortfall check.
            if run.status == .infrastructureFailure,
               Self.allSelectedTestsSkipped(skippedCount: skippedCount, expectedTestCount: unit.expectedTestCount) {
                return CoverageMap(executedLines: [:], source: "swiftpm-codecov-per-test")
            }
            guard run.status == .passed else { return nil }

            let map: CoverageMap? = if let scratch {
                await self.readCoverage(
                    productsDirectory: scratch.appendingPathComponent("debug", isDirectory: true), projectRoot: workspace
                )
            } else {
                await self.readCoverage(in: workspace, projectRoot: workspace)
            }
            guard let map else { return nil }
            if scratch == nil { slots.markBuilt() }
            return map
        }
    }
}
