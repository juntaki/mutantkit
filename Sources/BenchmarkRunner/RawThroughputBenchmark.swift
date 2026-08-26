import Foundation

/// Phase B3 (rigorous-benchmark program): raw throughput, on an ordinary
/// green project (no fault injection — that is B4's own separate
/// concern), with real repetitions in a rotated tool order, per B0's own
/// contract ("MK → SMT → Muter, then SMT → Muter → MK, then Muter → MK →
/// SMT, …") — a real, if minimal, defense against one tool consistently
/// benefiting from running first (a cold filesystem cache, a cold
/// thermal state) or last (a warm one) every single time.
///
/// Reuses each tool's own existing `MutationBenchmarkTool.run(project:
/// context:)` unchanged — this is not a new way of invoking a tool, only
/// a new *schedule* for calling the same real per-tool invocation
/// `BenchmarkOrchestrator`'s own end-to-end lane already uses.
public enum RawThroughputBenchmark {
    public struct Repetition: Sendable {
        public let tool: String
        public let repetitionIndex: Int
        /// Position in this repetition's own rotated order (0 = ran
        /// first) — kept explicitly so a later analysis can check
        /// whether "ran first" itself correlates with the result,
        /// exactly the bias this whole rotation exists to catch, not
        /// just to avoid.
        public let positionInRotation: Int
        public let raw: RawBenchmarkRun
        public let normalized: [NormalizedMutant]
        /// B3.6's permanent validity guard, evaluated for this repetition
        /// alone — `nil` when this run is valid. Never silently dropped
        /// from `ToolSummary`'s own throughput numbers; a caller must
        /// check this before treating any wall time here as real.
        public let validityViolation: BenchmarkViolation?
    }

    public struct ToolSummary: Sendable {
        public let tool: String
        public let wallSecondsByRepetition: [Double]
        public let peakResidentBytesByRepetition: [UInt64?]
        public var medianWallSeconds: Double? { ResultNormalizer.median(wallSecondsByRepetition) }
        /// `nil` whenever a discovered-count could not be established for
        /// every repetition (a crashed/timed-out run has no usable
        /// report), or whenever *any* repetition failed B3.6's own
        /// validity guard (`violations` non-empty) — never computed from
        /// a partial or invalid repetition set silently passed off as the
        /// real median. A wrong/empty answer must never look like a fast
        /// win, even by accident.
        public var medianMutantsPerSecond: Double? {
            guard violations.isEmpty, let medianWallSeconds, medianWallSeconds > 0, let discoveredCount else { return nil }
            return Double(discoveredCount) / medianWallSeconds
        }
        public let discoveredCount: Int?
        /// Every B3.6 validity violation found across this tool's own
        /// repetitions — non-empty means every throughput number above is
        /// suppressed to `nil`, not just the affected repetition's own.
        public let violations: [BenchmarkViolation]

        public init(
            tool: String, wallSecondsByRepetition: [Double], peakResidentBytesByRepetition: [UInt64?], discoveredCount: Int?,
            violations: [BenchmarkViolation] = []
        ) {
            self.tool = tool
            self.violations = violations
            self.wallSecondsByRepetition = wallSecondsByRepetition
            self.peakResidentBytesByRepetition = peakResidentBytesByRepetition
            self.discoveredCount = discoveredCount
        }
    }

    /// - Parameters:
    ///   - tools: `(name, tool)` pairs, in the order they should appear
    ///     in *rotation 0* — every subsequent repetition rotates this
    ///     list by one position (`repetitionIndex % tools.count`), per
    ///     B0's own fixed contract, never re-ordered "for convenience"
    ///     mid-run.
    ///   - repetitions: how many full rotations to run. B0's own contract
    ///     specifies a minimum of 5; a caller running fewer under real
    ///     time constraints must say so explicitly wherever this
    ///     function's own result is reported, never silently presented
    ///     as if the full count ran.
    ///   - requestedScopeIsNonEmpty: per tool name, whether this call
    ///     asked that tool to consider at least one real source file —
    ///     B3.6's validity guard is a no-op for any tool not listed here
    ///     (defaults to `true`, matching every real caller today, which
    ///     always scopes to something).
    ///   - zeroMutantsExpected: per tool name, `true` only when a fixture
    ///     explicitly documents that zero mutants is the correct result
    ///     for this exact run — never inferred, always stated by the
    ///     caller. Defaults to `false`.
    public static func run(
        tools: [(name: String, tool: any MutationBenchmarkTool)], project: MaterializedBenchmarkProject,
        mode: BenchmarkMode, repetitions: Int, cacheDirectory: URL, timeoutSeconds: Double,
        requestedScopeIsNonEmpty: [String: Bool] = [:], zeroMutantsExpected: [String: Bool] = [:]
    ) async throws -> (repetitions: [Repetition], summaries: [ToolSummary]) {
        var repetitionResults: [Repetition] = []

        for repetitionIndex in 0..<repetitions {
            let rotation = rotated(tools, by: repetitionIndex)
            for (position, entry) in rotation.enumerated() {
                let context = BenchmarkRunContext(
                    mode: mode, runIndex: repetitionIndex, cacheDirectory: cacheDirectory, timeoutSeconds: timeoutSeconds
                )
                try await entry.tool.prepare(project: project, context: context)
                let raw = try await entry.tool.run(project: project, context: context)
                let normalized = normalize(entry.name, raw.reportData)
                let violation = BenchmarkValidityGuard.validate(
                    tool: entry.name, toolExitedSuccessfully: raw.execution.exitCode == 0 && !raw.execution.timedOut,
                    requestedScopeIsNonEmpty: requestedScopeIsNonEmpty[entry.name] ?? true,
                    discoveredCount: normalized.count, zeroMutantsExpected: zeroMutantsExpected[entry.name] ?? false
                )
                repetitionResults.append(Repetition(
                    tool: entry.name, repetitionIndex: repetitionIndex, positionInRotation: position, raw: raw,
                    normalized: normalized, validityViolation: violation
                ))
            }
        }

        let toolNames = tools.map(\.name)
        let summaries: [ToolSummary] = toolNames.map { name in
            let ownRepetitions = repetitionResults.filter { $0.tool == name }
            let wallSeconds = ownRepetitions.map(\.raw.execution.wallSeconds)
            let peakResident = ownRepetitions.map(\.raw.resources.peakResidentBytes)
            // A discovered count is only meaningful when every repetition
            // agrees — a real green-project run should discover the
            // identical mutant set every time; disagreement itself would
            // be real, reportable evidence (non-determinism in the
            // tool's own discovery), not something to paper over by
            // picking one repetition's own count arbitrarily.
            let discoveredCounts = Set(ownRepetitions.map(\.normalized.count))
            return ToolSummary(
                tool: name, wallSecondsByRepetition: wallSeconds, peakResidentBytesByRepetition: peakResident,
                discoveredCount: discoveredCounts.count == 1 ? discoveredCounts.first : nil,
                violations: ownRepetitions.compactMap(\.validityViolation)
            )
        }

        return (repetitionResults, summaries)
    }

    private static func rotated<T>(_ array: [T], by amount: Int) -> [T] {
        guard !array.isEmpty else { return array }
        let offset = amount % array.count
        return Array(array[offset...] + array[..<offset])
    }

    private static func normalize(_ tool: String, _ reportData: Data?) -> [NormalizedMutant] {
        guard let reportData else { return [] }
        switch tool {
        case "mutantkit": return (try? ResultNormalizer.normalizeMutantKitReport(reportData).mutants) ?? []
        case "muter": return (try? ResultNormalizer.normalizeMuterReport(reportData)) ?? []
        case "swift-mutation-testing": return (try? ResultNormalizer.normalizeSwiftMutationTestingReport(reportData)) ?? []
        default: return []
        }
    }
}
