import Foundation
import MutationExecution
import MutationModel

/// How `SwiftPackageMacOSAdapter.measurePerTestCoverage` groups tests into the
/// runs that measure them: one run per test, or (`coverageGranularity: suite`)
/// one run per top-level suite.
extension SwiftPackageMacOSAdapter {
    /// What one coverage-measuring run covers: one test, or one whole suite.
    struct CoverageUnit: Hashable {
        /// The `swift test --filter` regex selecting exactly this unit.
        let filter: String
        /// How many tests the run should execute, when SwiftPM's own report can be trusted on that.
        let expectedTestCount: Int?
        /// `nil` for a single test; set when the unit is a suite shared by several tests.
        let suiteKey: String?
    }

    /// The top-level suite a test belongs to: its identifier up to the first `/`.
    /// A nested suite belongs to its parent, because one `--filter` on the parent
    /// selects the nested tests too.
    private static func suiteName(of test: TestIdentifier) -> String? {
        guard let slash = test.qualifiedName.firstIndex(of: "/") else { return nil }
        return String(test.qualifiedName[..<slash])
    }

    /// How many of `tests` each top-level suite holds (nested suites included), keyed `"<target>.<suite>"`.
    static func suiteSizes(of tests: [TestIdentifier]) -> [String: Int] {
        var sizes: [String: Int] = [:]
        for test in tests {
            guard let suite = suiteName(of: test) else { continue }
            sizes["\(test.target).\(suite)", default: 0] += 1
        }
        return sizes
    }

    /// The unit that measures `test` under `granularity`. A test with no suite part
    /// in its identifier is always measured on its own.
    static func coverageUnit(
        for test: TestIdentifier, granularity: CoverageGranularity, suiteSizes: [String: Int]
    ) -> CoverageUnit {
        let single = CoverageUnit(
            filter: test.swiftTestFilterArgument,
            expectedTestCount: test.isSwiftTestingShaped ? 1 : nil,
            suiteKey: nil
        )
        guard granularity == .suite, let suite = suiteName(of: test),
              let size = suiteSizes["\(test.target).\(suite)"] else { return single }
        let key = "\(test.target).\(suite)"
        // `.*`, not `[^/]+`: SwiftPM's `--filter` matches nothing for a negated character class.
        let filter = "^\(NSRegularExpression.escapedPattern(for: test.target))\\."
            + "\(NSRegularExpression.escapedPattern(for: suite))/.*$"
        return CoverageUnit(
            filter: filter, expectedTestCount: test.isSwiftTestingShaped ? size : nil, suiteKey: key
        )
    }

    /// Whether a run that fell short of its expected test count did so because every selected test
    /// was skipped: the report records exactly as many skipped tests as were selected. A run where
    /// some selected test is missing or ran is not this.
    static func allSelectedTestsSkipped(skippedCount: Int?, expectedTestCount: Int?) -> Bool {
        guard let skippedCount, let expectedTestCount, expectedTestCount > 0 else { return false }
        return skippedCount == expectedTestCount
    }

    /// The outcome of measuring a suite, shared by every test in it.
    ///
    /// Locked, because concurrent measurement slots (`execution.coverageWorkers`) read and record it
    /// together. A suite is only ever worked on by one slot at a time, so the lock guards the
    /// dictionary, not the order of its entries.
    final class SuiteCoverageMemo: @unchecked Sendable {
        enum Outcome {
            case measured(CoverageMap)
            case failed
        }

        private let lock = NSLock()
        private var outcomes: [String: Outcome] = [:]

        func outcome(for key: String) -> Outcome? {
            lock.lock()
            defer { lock.unlock() }
            return outcomes[key]
        }

        func record(_ outcome: Outcome, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            outcomes[key] = outcome
        }
    }

    /// The scratch directories that give each extra measurement slot its own copy of the build
    /// products, and the one fact the slots share: whether the coverage-instrumented build exists.
    final class CoverageSlots: @unchecked Sendable {
        private let lock = NSLock()
        private var scratch: [Int: URL] = [:]
        private var built = false

        var artifactBuilt: Bool {
            lock.lock()
            defer { lock.unlock() }
            return built
        }

        func markBuilt() {
            lock.lock()
            defer { lock.unlock() }
            built = true
        }

        func scratchPath(for slot: Int) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return scratch[slot]
        }

        func register(_ url: URL, for slot: Int) {
            lock.lock()
            defer { lock.unlock() }
            scratch[slot] = url
        }

        var all: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return Array(scratch.values)
        }
    }

    /// `clonefile(2)` of `source` to `destination`: copy-on-write on APFS, and never a plain copy,
    /// because a build directory is large enough that copying it would cost more than the
    /// parallelism saves.
    static func cloneDirectory(_ source: URL, to destination: URL) -> Bool {
        clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0
    }
}
