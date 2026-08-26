import CryptoKit
import Foundation

/// A mutation identity that means the same thing regardless of which tool
/// produced it — `MutationID` itself is never comparable across tools
/// (each tool mints its own, unrelated scheme), so cross-tool matching
/// needs an identity derived purely from *what changed in the source*, not
/// from either tool's internal bookkeeping.
///
/// `line`/`column` (Phase C13, competitive-parity program): added after a
/// real Muter calibration run found **zero** matched mutants despite
/// running the identical corpus, file, and operator. Root cause, found by
/// reading Muter's own real `--format json` output directly rather than
/// its schema on paper: Muter `16`'s `AppliedMutationOperator.CodingKeys`
/// (real source: `Sources/muterCore/TestReporting/MuterTestReport.swift`
/// at that version/commit) explicitly excludes `mutationSnapshot` from
/// encoding — a real report from that version never carries the mutated
/// text at all, so `originalTextHash`/`replacementTextHash` (this
/// identity's *original* match key, before this fix) hash an empty
/// string for every Muter mutant this program has observed. This is
/// scoped to the verified version deliberately: it is not a claim about
/// every past or future Muter release, only about the one actually read.
/// Matching on those fields alone was structurally guaranteed to match
/// nothing on that version, regardless of what corpus or operator was
/// compared — confirmed by inspecting a real captured calibration report
/// (`Benchmarks/results/.../stage1-calibration/raw/
/// swift-numerics-muter-cold-0.json`), which indeed has no snapshot text
/// anywhere.
///
/// That same real report *does* carry `position.line`/`position.column`
/// for every mutation, and MutantKit's own `MutationPoint` always carries
/// real `line`/`column` too (`Sources/MutationModel/MutationPoint.swift` —
/// non-optional, present in every schema version). Cross-checked directly
/// against the real swift-numerics calibration pair: for the same real
/// file and the same real mutation site, both tools report the identical
/// `(line, column)` pair every time (confirmed for 3 independent
/// mutations in `GCD.swift`) — even though Muter's own `position
/// .utf8Offset` field (present, but never previously parsed) disagreed
/// with MutantKit's `utf8Range.start` by a constant, unexplained 72-byte
/// delta for that same file, making the byte-offset fields *not* safely
/// comparable across tools without further investigation this fix does
/// not depend on. `(relativePath, line, column)` both agrees in practice
/// and needs no such cross-tool calibration, so it is the new match key.
///
/// This does reintroduce the theoretical collision this type's docs used
/// to warn about (two distinct candidates at the same line *and* column —
/// e.g. two different replacements of the same relational operator token,
/// which MutantKit itself produces and Muter does not) — accepted
/// deliberately: it degrades a same-position multiple-replacement case
/// from "matched, once each" to "several `mutantKit` mutants correctly
/// matching the one real `muter` mutant at that position" (still a real,
/// correct correspondence, not a wrong one), which is strictly better
/// than the pre-fix "matches nothing, ever."
public struct CrossToolMutationIdentity: Codable, Hashable, Sendable {
    public let relativePath: String
    public let startUTF8Offset: Int
    public let endUTF8Offset: Int
    public let originalTextHash: String
    public let replacementTextHash: String
    public let normalizedOperatorFamily: String
    /// 1-based source line/column, as reported by the *producing* tool
    /// itself — the real cross-tool match key as of Phase C13; see this
    /// type's own doc comment for why the text-hash fields above cannot
    /// serve that purpose for a real Muter report.
    public let line: Int
    public let column: Int
    /// The real, human-readable original/mutated source text — Phase B1
    /// (rigorous-benchmark program) added these so a canonical matched
    /// mutation can be reported as `a > b` → `a >= b`, not just an opaque
    /// hash. Defaulted to `""` for backward compatibility with every
    /// existing call site that only ever needed the hashes for matching;
    /// never used as part of `Hashable`/matching identity on its own — the
    /// hashes above remain the authoritative "did the text change"
    /// signal, this is purely for human/report consumption.
    public let originalText: String
    public let replacementText: String

    public init(
        relativePath: String, startUTF8Offset: Int, endUTF8Offset: Int,
        originalTextHash: String, replacementTextHash: String, normalizedOperatorFamily: String,
        line: Int = 0, column: Int = 0, originalText: String = "", replacementText: String = ""
    ) {
        self.relativePath = relativePath
        self.startUTF8Offset = startUTF8Offset
        self.endUTF8Offset = endUTF8Offset
        self.originalTextHash = originalTextHash
        self.replacementTextHash = replacementTextHash
        self.normalizedOperatorFamily = normalizedOperatorFamily
        self.line = line
        self.column = column
        self.originalText = originalText
        self.replacementText = replacementText
    }
}

/// The full measurement for one tool's one run of one project in one mode
/// — the shape both `raw/*.json` entries and `aggregate.json` are built
/// from. Every `Int?`/`Double?`/`UInt64?` here is `nil` when the source
/// tool does not expose the concept at all (Muter has no `provenActive`/
/// `provenExecuted` equivalent) or when the measurement genuinely could
/// not be taken (a crashed process leaves no report to read counts from) —
/// never coerced to `0`, which would silently claim "measured, and it was
/// zero."
public struct MutationBenchmarkMeasurement: Codable, Sendable {
    public let runID: UUID
    public let tool: BenchmarkToolIdentity
    public let projectID: String
    public let projectCommit: String
    public let mode: BenchmarkMode
    /// Which `BenchmarkToolchainProfile` this measurement was taken under —
    /// required, never inferred: `current` and `compatibility` results must
    /// never be silently averaged or compared against each other, since
    /// that would conflate "which tool happens to compile on today's
    /// toolchain" with "which tool is actually faster."
    public let toolchainProfileID: String
    public let discovered: Int
    public let applied: Int?
    public let built: Int?
    public let provenActive: Int?
    public let provenExecuted: Int?
    public let killed: Int
    public let survived: Int
    public let noCoverage: Int
    public let unviable: Int
    public let infrastructureFailure: Int
    public let phantom: Int?
    public let falseScored: Int?
    public let backendDisagreements: Int?
    public let wallSeconds: Double
    public let peakResidentBytes: UInt64?
    /// Real working-directory size growth (never OS-level I/O byte
    /// counting — see `DiskMeasurement`'s own doc comment).
    public let workingDirectoryGrowthBytes: UInt64?
    public let exitCode: Int32

    public init(
        runID: UUID, tool: BenchmarkToolIdentity, projectID: String, projectCommit: String, mode: BenchmarkMode,
        toolchainProfileID: String, discovered: Int, applied: Int?, built: Int?, provenActive: Int?, provenExecuted: Int?,
        killed: Int, survived: Int, noCoverage: Int, unviable: Int, infrastructureFailure: Int,
        phantom: Int?, falseScored: Int?, backendDisagreements: Int?,
        wallSeconds: Double, peakResidentBytes: UInt64?, workingDirectoryGrowthBytes: UInt64?, exitCode: Int32
    ) {
        self.runID = runID
        self.tool = tool
        self.projectID = projectID
        self.projectCommit = projectCommit
        self.mode = mode
        self.toolchainProfileID = toolchainProfileID
        self.discovered = discovered
        self.applied = applied
        self.built = built
        self.provenActive = provenActive
        self.provenExecuted = provenExecuted
        self.killed = killed
        self.survived = survived
        self.noCoverage = noCoverage
        self.unviable = unviable
        self.infrastructureFailure = infrastructureFailure
        self.phantom = phantom
        self.falseScored = falseScored
        self.backendDisagreements = backendDisagreements
        self.wallSeconds = wallSeconds
        self.peakResidentBytes = peakResidentBytes
        self.workingDirectoryGrowthBytes = workingDirectoryGrowthBytes
        self.exitCode = exitCode
    }
}

/// One normalized mutant — enough to build a `CrossToolMutationIdentity`
/// and know its outcome bucket, extracted from either tool's own report
/// format by `ResultNormalizer`.
public struct NormalizedMutant: Sendable {
    public enum Bucket: String, Sendable {
        case killed, survived, noCoverage, unviable, infrastructureFailure, other
    }

    public let identity: CrossToolMutationIdentity
    public let bucket: Bucket
    /// `true` only for MutantKit results whose `evidence.applicationEvidence`
    /// is present — Muter's own normalized mutants never set this, since
    /// Muter has no equivalent concept.
    public let provenActive: Bool?
    /// The producing tool's own native mutation ID, when its report
    /// exposes one — Phase B1 (rigorous-benchmark program) added this so
    /// a canonical matched mutation can be traced back to, e.g.,
    /// MutantKit's own `mut_xxx` (`mutantkit reproduce`-able) or
    /// swift-mutation-testing's own `swift-mutation-testing_N`. `nil` for
    /// Muter: confirmed against its own real `--format json` output that
    /// no per-mutation ID field exists there at all (unlike
    /// `mutationSnapshot`, this is not a CodingKeys exclusion — the field
    /// is simply absent from the type Muter serializes).
    public let nativeID: String?
    /// Real per-mutant wall time (build + test), when the producing
    /// tool's own report exposes it — Phase B2 (rigorous-benchmark
    /// program) added this so the matched-mutant lane can compute a real
    /// "time spent evaluating just the corpus-matched subset" for a tool
    /// that reports it, rather than only ever falling back to a coarse
    /// whole-run proxy. Confirmed present in MutantKit's own real report
    /// (`buildDurationSeconds`/`testDurationSeconds` per result); Muter's
    /// and swift-mutation-testing's own real report schemas do not expose
    /// per-mutant duration at all, so this is `nil` for both — a real,
    /// disclosed capability gap between tools, not fabricated to appear
    /// symmetric.
    public let durationSeconds: Double?

    public init(
        identity: CrossToolMutationIdentity, bucket: Bucket, provenActive: Bool?, nativeID: String? = nil,
        durationSeconds: Double? = nil
    ) {
        self.identity = identity
        self.bucket = bucket
        self.durationSeconds = durationSeconds
        self.provenActive = provenActive
        self.nativeID = nativeID
    }
}

public struct CrossToolComparison: Sendable {
    /// Same file/offsets/edit AND the same normalized operator family —
    /// the strongest match this harness can make.
    public let exactlyComparable: [(mutantKit: NormalizedMutant, muter: NormalizedMutant)]
    /// Same file/offsets/edit but the operator family did not normalize to
    /// the same bucket (e.g. one tool's relational-operator variant the
    /// other does not have an exact analog for) — reported, not discarded,
    /// and never folded into `exactlyComparable`.
    public let approximatelyComparable: [(mutantKit: NormalizedMutant, muter: NormalizedMutant)]
    public let mutantKitOnly: [NormalizedMutant]
    public let muterOnly: [NormalizedMutant]

    public init(
        exactlyComparable: [(mutantKit: NormalizedMutant, muter: NormalizedMutant)],
        approximatelyComparable: [(mutantKit: NormalizedMutant, muter: NormalizedMutant)],
        mutantKitOnly: [NormalizedMutant], muterOnly: [NormalizedMutant]
    ) {
        self.exactlyComparable = exactlyComparable
        self.approximatelyComparable = approximatelyComparable
        self.mutantKitOnly = mutantKitOnly
        self.muterOnly = muterOnly
    }
}

public enum ResultNormalizer {
    // MARK: - Cross-tool operator family normalization

    /// A coarse family both tools' operator vocabularies can be mapped
    /// onto — deliberately coarser than either tool's own operator IDs,
    /// since the two tools were never designed to agree on operator
    /// granularity. Unknown operators map to their own raw ID rather than
    /// to a shared bucket, so an unrecognized operator never silently
    /// "matches" something it is not actually equivalent to.
    public static func mutantKitOperatorFamily(_ operatorID: String) -> String {
        switch operatorID {
        case "swift.core.bool-literal-inversion": "boolean-literal"
        case "swift.core.relational-operator-replacement": "relational-operator"
        case "swift.core.logical-connector-replacement": "logical-connector"
        case "swift.core.ternary-branch-swap": "ternary"
        case "swift.core.unary-not-removal": "unary-not"
        // Phase C13: added while wiring up the swift-mutation-testing
        // adapter — without this, C3's `swift.core.side-effect-call-removal`
        // (added this same phase) could never family-match Muter's or
        // swift-mutation-testing's own `RemoveSideEffects`, both of which
        // already map to `"remove-side-effects"` below, even though all
        // three tools implement essentially the same operator.
        case "swift.core.side-effect-call-removal": "remove-side-effects"
        // Added after a real review found this mapping missing entirely —
        // MutantKit does ship this operator (`Sources/SwiftCoreOperators/
        // ArithmeticOperatorReplacementOperator.swift`, documented in the
        // public README), so a swift-mutation-testing
        // `ArithmeticOperatorReplacement` mutant was being silently
        // dropped from cross-tool consideration rather than compared.
        case "swift.core.arithmetic-operator-replacement": "arithmetic-operator"
        default: operatorID
        }
    }

    public static func muterOperatorFamily(_ mutationOperatorID: String) -> String {
        switch mutationOperatorID {
        case "RelationalOperatorReplacement", "ROR": "relational-operator"
        case "ChangeLogicalConnector": "logical-connector"
        case "SwapTernary": "ternary"
        case "RemoveSideEffects": "remove-side-effects"
        default: mutationOperatorID
        }
    }

    /// `ericodx/swift-mutation-testing`'s own operator identifiers
    /// (confirmed via its real `Docs/USAGE.MD` "Operator identifiers"
    /// table), mapped onto the same shared family vocabulary
    /// `mutantKitOperatorFamily`/`muterOperatorFamily` already use, so a
    /// mutation this tool and MutantKit both implement can land in
    /// `exactlyComparable` rather than `approximatelyComparable`.
    /// `ArithmeticOperatorReplacement` maps onto MutantKit's own
    /// `swift.core.arithmetic-operator-replacement` (a real review found
    /// this repo's own doc comment previously, incorrectly, claimed no
    /// MutantKit equivalent existed). `NegateConditional` still has no
    /// MutantKit or Muter equivalent in this catalog today, so it falls
    /// through to its own raw name — never a false shared family.
    public static func swiftMutationTestingOperatorFamily(_ mutatorName: String) -> String {
        switch mutatorName {
        case "RelationalOperatorReplacement": "relational-operator"
        case "BooleanLiteralReplacement": "boolean-literal"
        case "LogicalOperatorReplacement": "logical-connector"
        case "SwapTernary": "ternary"
        case "RemoveSideEffects": "remove-side-effects"
        case "ArithmeticOperatorReplacement": "arithmetic-operator"
        default: mutatorName
        }
    }

    // MARK: - MutantKit report.json

    public enum ReportParsingError: Error, CustomStringConvertible {
        case malformedReport(String)
        public var description: String {
            switch self {
            case let .malformedReport(reason): "report.json could not be parsed: \(reason)"
            }
        }
    }

    public struct MutantKitReportSummary: Sendable {
        public let mutants: [NormalizedMutant]
        public let integrityPassed: Bool
        public let operationalIssueCount: Int
        public let plannedMutations: Int
        /// `IntegrityViolation.Kind.phantomMutant` count, read directly off
        /// `integrity.violations` — MutantKit's own definition of a
        /// phantom (a mutant in the report that never touched the source),
        /// not a redefinition invented for this benchmark.
        public let phantomMutants: Int
        /// A scorable result (`bucket` is `.killed`/`.survived`/`.noCoverage`/
        /// `.unviable`) whose own `verificationVersion` is `0` — the only
        /// value a `MutationResult` decoded from `report.json` ever carries
        /// when it did *not* come from a real `MutationVerdictVerifier
        /// .verify` call (see `MutationResult.mutationRef`'s own doc
        /// comment: `0` marks a legacy/placeholder-decoded record). A
        /// healthy run's own `report.json` — always written by `verify`
        /// itself — never produces one; this is a real, load-bearing
        /// correctness check, not a placeholder metric.
        public let falseScoredMutants: Int
        /// `nil` only when `report.json` carried none of the fields this
        /// is derived from (a crashed/malformed run) — a healthy report
        /// always has one.
        public let phaseTimings: MutantKitPhaseTimings?
    }

    /// A real phase breakdown read directly off MutantKit's own
    /// `report.json` fields (`baseline.buildDurationSeconds`/
    /// `testDurationSeconds`, each result's own `buildDurationSeconds`/
    /// `testDurationSeconds`/`point.executionMode`/`point.operatorID`,
    /// and the top-level `startedAt`/`finishedAt`) — never inferred or
    /// distributed by guesswork, since MutantKit already reports these
    /// per-mutant, unlike Muter (which only ever reports one total
    /// `timeElapsed`, with no phase breakdown at all — see
    /// `normalizeMuterReport`'s own doc comment on that boundary).
    public struct MutantKitPhaseTimings: Sendable, Equatable {
        public let totalWallSeconds: Double?
        public let baselineBuildSeconds: Double?
        public let baselineTestSeconds: Double?
        /// Sum across every `origin == "fresh"` result only — a
        /// checkpoint-resumed or cache-hit mutant did no building/testing
        /// in *this* run, and including its historical duration would
        /// double count time already spent in an earlier run (the same
        /// reasoning `Sources/Reporting/PerformanceSummary.swift` already
        /// documents for its own equivalent sums).
        public let sumFreshMutantBuildSeconds: Double
        public let sumFreshMutantTestSeconds: Double
        public let isolatedCount: Int
        public let schemataCount: Int
        public let operatorCounts: [String: Int]
    }

    /// Parses MutantKit's `report.json` via a generic `[String: Any]`
    /// walk, not by importing `MutationModel`'s own `RunReport`/
    /// `MutationResult` Codable types — `BenchmarkRunner` treats
    /// MutantKit as an external tool with a documented, versioned report
    /// format, the same posture it must have toward Muter, whose internal
    /// Swift types this repository obviously cannot import at all.
    public static func normalizeMutantKitReport(_ data: Data) throws -> MutantKitReportSummary {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReportParsingError.malformedReport("top level is not a JSON object")
        }
        let results = root["results"] as? [[String: Any]] ?? []
        let integrity = root["integrity"] as? [String: Any]
        let operationalIssues = root["operationalIssues"] as? [[String: Any]] ?? []
        let violations = integrity?["violations"] as? [[String: Any]] ?? []
        // `IntegrityReport.passed` (Sources/MutationModel/Integrity.swift)
        // is a computed property (`violations.isEmpty`), never a stored
        // field — it is never present in real report.json output, at any
        // version. Confirmed directly against a real MutantKit run this
        // parser once silently marked correctness-FAILED for, because
        // `integrity?["passed"]` always evaluated to the `?? false`
        // fallback. Derived the same way MutantKit itself does, instead.
        let integrityPassed = violations.isEmpty
        let phantomMutants = violations.filter { ($0["kind"] as? String) == "phantomMutant" }.count
        let plannedMutations = integrity?["planned"] as? Int ?? 0

        var falseScoredMutants = 0
        let mutants: [NormalizedMutant] = results.compactMap { result in
            guard let point = result["point"] as? [String: Any],
                  let file = point["file"] as? String,
                  let range = point["utf8Range"] as? [String: Any],
                  let start = range["start"] as? Int, let end = range["end"] as? Int,
                  let originalText = point["originalText"] as? String,
                  let replacementText = point["replacementText"] as? String,
                  let operatorID = point["operatorID"] as? String,
                  let outcome = result["outcome"] as? String
            else { return nil }

            // `line`/`column` are optional here (`as?`, not `guard let`)
            // deliberately, unlike the fields above: every *real* MutantKit
            // report has always carried them (`MutationPoint.line`/
            // `.column` are non-optional in the model itself), so this
            // never actually degrades a real report — but making them
            // required here would needlessly drop entries in every
            // existing hand-built test fixture that predates Phase C13's
            // line/column-based cross-tool matching and has no reason to
            // care about it. `0` is never a collision risk in practice: a
            // real `line` is always >= 1.
            let identity = CrossToolMutationIdentity(
                relativePath: file, startUTF8Offset: start, endUTF8Offset: end,
                originalTextHash: sha256Hex(originalText), replacementTextHash: sha256Hex(replacementText),
                normalizedOperatorFamily: mutantKitOperatorFamily(operatorID),
                line: point["line"] as? Int ?? 0, column: point["column"] as? Int ?? 0,
                originalText: originalText, replacementText: replacementText
            )
            let evidencePresent = (result["evidence"] as? [String: Any])?["applicationEvidence"] != nil
            let mutantBucket = bucket(forMutantKitOutcome: outcome)
            if mutantBucket != .infrastructureFailure, mutantBucket != .other, (result["verificationVersion"] as? Int) == 0 {
                falseScoredMutants += 1
            }
            let buildDuration = result["buildDurationSeconds"] as? Double
            let testDuration = result["testDurationSeconds"] as? Double
            let duration: Double? = (buildDuration != nil || testDuration != nil) ? (buildDuration ?? 0) + (testDuration ?? 0) : nil
            return NormalizedMutant(
                identity: identity, bucket: mutantBucket, provenActive: evidencePresent, nativeID: point["id"] as? String,
                durationSeconds: duration
            )
        }
        let phaseTimings = parsePhaseTimings(root: root, results: results)

        return MutantKitReportSummary(
            mutants: mutants, integrityPassed: integrityPassed, operationalIssueCount: operationalIssues.count,
            plannedMutations: plannedMutations, phantomMutants: phantomMutants, falseScoredMutants: falseScoredMutants,
            phaseTimings: phaseTimings
        )
    }

    private static func parsePhaseTimings(root: [String: Any], results: [[String: Any]]) -> MutantKitPhaseTimings? {
        let baseline = root["baseline"] as? [String: Any]
        let totalWallSeconds = iso8601Duration(
            start: root["startedAt"] as? String, end: root["finishedAt"] as? String
        )

        var buildSum = 0.0, testSum = 0.0, isolatedCount = 0, schemataCount = 0
        var operatorCounts: [String: Int] = [:]
        for result in results {
            let point = result["point"] as? [String: Any]
            if let operatorID = point?["operatorID"] as? String {
                operatorCounts[operatorID, default: 0] += 1
            }
            switch point?["executionMode"] as? String {
            case "isolated": isolatedCount += 1
            case "schemata": schemataCount += 1
            default: break
            }
            guard (result["origin"] as? String) == "fresh" else { continue }
            buildSum += result["buildDurationSeconds"] as? Double ?? 0
            testSum += result["testDurationSeconds"] as? Double ?? 0
        }

        guard baseline != nil || totalWallSeconds != nil || !results.isEmpty else { return nil }
        return MutantKitPhaseTimings(
            totalWallSeconds: totalWallSeconds,
            baselineBuildSeconds: baseline?["buildDurationSeconds"] as? Double,
            baselineTestSeconds: baseline?["testDurationSeconds"] as? Double,
            sumFreshMutantBuildSeconds: buildSum, sumFreshMutantTestSeconds: testSum,
            isolatedCount: isolatedCount, schemataCount: schemataCount, operatorCounts: operatorCounts
        )
    }

    /// `startedAt`/`finishedAt` are ISO 8601 strings — parsed with
    /// `ISO8601DateFormatter` rather than assuming a fixed format, since
    /// MutantKit's own encoder may or may not include fractional seconds.
    private static func iso8601Duration(start: String?, end: String?) -> Double? {
        guard let start, let end, let startDate = parseISO8601(start), let endDate = parseISO8601(end) else { return nil }
        return endDate.timeIntervalSince(startDate)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value)
    }

    private static func bucket(forMutantKitOutcome outcome: String) -> NormalizedMutant.Bucket {
        switch outcome {
        case "killedByAssertion", "killedByCrash", "verifiedTimeout": .killed
        case "survived": .survived
        case "noCoverage": .noCoverage
        case "unviable": .unviable
        case "infrastructureFailure", "notApplied", "baselineMismatch", "timedOut", "flaky": .infrastructureFailure
        default: .other
        }
    }
}

// MARK: - Muter/swift-mutation-testing report parsing

//
// Split into its own extension (same file, same type) purely to keep
// each individual type body under SwiftLint's `type_body_length` limit —
// not a behavior change. Mirrors the same split pattern already used
// elsewhere in this codebase's own test suites.
public extension ResultNormalizer {
    // MARK: - Muter report.json

    /// Muter's real JSON reporter shape (`Sources/muterCore/TestReporting/
    /// Json/JsonReporter.swift` + `MuterTestReport.swift`, confirmed against
    /// a real regression-test snapshot in the muter repository, not
    /// guessed): `fileReports[].appliedOperators[].{mutationPoint:
    /// {mutationOperatorId, position:{line,column,utf8Offset}},
    /// mutationSnapshot: {before,after}, testSuiteOutcome}`. `position`
    /// carries line/column and (see `normalizeMuterReport`'s own handling
    /// of `position["utf8Offset"]` below) a UTF-8 byte offset too — this
    /// doc comment previously claimed no such offset existed, which Phase
    /// C13 found to be wrong; `CrossToolMutationIdentity`'s byte-offset
    /// fields are nonetheless still synthesized as a stable
    /// (not-necessarily-comparable-to-MutantKit's-own) encoding of
    /// `(line, column)` rather than that offset, since it does not agree
    /// numerically with MutantKit's own `utf8Range.start` for the same
    /// real mutation site (see below); the identity's `relativePath` +
    /// text hashes + operator family are what carry real matching weight,
    /// exactly as intended by "not comparing on line/column alone."
    /// Muter's own real phase breakdown — just one total (`timeElapsed`)
    /// and a per-operator mutation count, since Muter's real report.json
    /// never exposes anything finer (no per-mutation build/test split, no
    /// baseline-vs-mutant separation). Observable external boundary only,
    /// per this benchmark's own rule of never distributing a total by
    /// guesswork.
    struct MuterPhaseTimings: Sendable, Equatable {
        public let totalWallSeconds: Double?
        public let operatorCounts: [String: Int]
    }

    static func muterPhaseTimings(_ data: Data) throws -> MuterPhaseTimings {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReportParsingError.malformedReport("top level is not a JSON object")
        }
        let fileReports = root["fileReports"] as? [[String: Any]] ?? []
        var operatorCounts: [String: Int] = [:]
        for fileReport in fileReports {
            for applied in fileReport["appliedOperators"] as? [[String: Any]] ?? [] {
                guard let operatorID = (applied["mutationPoint"] as? [String: Any])?["mutationOperatorId"] as? String else { continue }
                operatorCounts[operatorID, default: 0] += 1
            }
        }
        return MuterPhaseTimings(
            totalWallSeconds: parseMuterElapsed(root["timeElapsed"] as? String), operatorCounts: operatorCounts
        )
    }

    /// Muter's own `timeElapsed` format: `HH:MM:SS.mmm` (real example:
    /// `"00:01:24.088"`, confirmed against a real report this benchmark
    /// captured).
    private static func parseMuterElapsed(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// `projectDirectory`, when given (Phase C13), lets every mutant's
    /// `relativePath` be resolved from the *real* per-mutation
    /// `mutationPoint.filePath` Muter reports (an absolute path into
    /// whatever working copy Muter made — confirmed by a real captured
    /// report to be `<benchmark-materialized-dir>_mutated/<real relative
    /// path>`, e.g. `.../mutantbench-swift-numerics-muter-cold-0_mutated/
    /// Sources/IntegerUtilities/GCD.swift`) rather than the file-report's
    /// own bare `fileName` (real value in that same report: `"GCD.swift"`
    /// — no directory at all). That bare basename can never equal
    /// MutantKit's own `relativePath` for anything but a file that
    /// happens to sit at the project root, which was a second, compounding
    /// reason the original "0 matched mutants" calibration finding
    /// happened — not just the text-hash issue this type's own doc
    /// comment describes. `nil` (the default, and every existing caller
    /// before this parameter existed) preserves the old bare-basename
    /// behavior exactly, so this is purely additive.
    static func normalizeMuterReport(_ data: Data, projectDirectory: URL? = nil) throws -> [NormalizedMutant] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReportParsingError.malformedReport("top level is not a JSON object")
        }
        let fileReports = root["fileReports"] as? [[String: Any]] ?? []

        return fileReports.flatMap { fileReport -> [NormalizedMutant] in
            guard let fileName = fileReport["fileName"] as? String else { return [] }
            let appliedOperators = fileReport["appliedOperators"] as? [[String: Any]] ?? []
            return appliedOperators.compactMap { applied in
                guard let mutationPoint = applied["mutationPoint"] as? [String: Any],
                      let operatorID = mutationPoint["mutationOperatorId"] as? String,
                      let position = mutationPoint["position"] as? [String: Any],
                      let line = position["line"] as? Int, let column = position["column"] as? Int,
                      let testSuiteOutcome = applied["testSuiteOutcome"] as? String
                else { return nil }

                // Muter's own `AppliedMutationOperator.CodingKeys` (real
                // source: Sources/muterCore/TestReporting/MuterTestReport.swift)
                // explicitly excludes `mutationSnapshot` from JSON encoding —
                // it is never present in a real `--format json` report, at
                // any version, despite carrying it in-memory. Confirmed
                // directly against a real report this produced (0 phantom
                // fields, all Muter measurements silently dropped to zero
                // before this fix). `before`/`after` therefore default to
                // empty strings when absent. This is why cross-tool
                // matching no longer relies on these hashes at all (Phase
                // C13; see `CrossToolMutationIdentity`'s own doc comment)
                // — they are still populated here (never worse than
                // dropping the mutant), just no longer load-bearing for
                // `match(mutantKit:muter:)`.
                let snapshot = applied["mutationSnapshot"] as? [String: Any]
                let before = snapshot?["before"] as? String ?? ""
                let after = snapshot?["after"] as? String ?? ""

                // Muter's real `position` *does* carry `utf8Offset` — this
                // codebase's own prior doc comment claiming otherwise was
                // wrong, confirmed by a real captured report (Phase C13).
                // Recorded here for observability, but Phase C13 found it
                // does not agree numerically with MutantKit's own
                // `utf8Range.start` for the identical real file/mutation
                // (a constant, unexplained delta in the one real corpus
                // checked) — so `line`/`column` are the real match key,
                // not this offset. Falls back to the old synthetic
                // `line*1_000_000+column` packing when `utf8Offset` is
                // absent, purely so this field is never a total void.
                let utf8Offset = position["utf8Offset"] as? Int ?? (line * 1_000_000 + column)

                let identity = CrossToolMutationIdentity(
                    relativePath: relativePath(
                        forMuterFilePath: mutationPoint["filePath"] as? String, fallback: fileName, projectDirectory: projectDirectory
                    ),
                    startUTF8Offset: utf8Offset, endUTF8Offset: utf8Offset,
                    originalTextHash: sha256Hex(before), replacementTextHash: sha256Hex(after),
                    normalizedOperatorFamily: muterOperatorFamily(operatorID),
                    line: line, column: column, originalText: before, replacementText: after
                )
                // No `nativeID`: confirmed against a real Muter report
                // that no per-mutation ID field exists in its own
                // `--format json` output at all (Phase B1).
                return NormalizedMutant(identity: identity, bucket: bucket(forMuterOutcome: testSuiteOutcome), provenActive: nil)
            }
        }
    }

    /// Resolves a Muter mutation's *real* project-relative path from its
    /// absolute `mutationPoint.filePath`, by probing the filesystem for
    /// the longest path suffix that actually exists under
    /// `projectDirectory` — deliberately not a fixed `"_mutated"`-suffix
    /// string match, since that is Muter's own working-copy naming
    /// convention today, confirmed against one real captured report, not
    /// a documented contract this benchmark controls or should assume is
    /// stable across Muter versions. Falls back to `fallback` (the bare
    /// `fileName` every caller used before this existed) whenever
    /// `projectDirectory` or `filePath` is absent, or no suffix actually
    /// resolves to a real file — never throws, never guesses a path that
    /// does not exist on disk.
    internal static func relativePath(forMuterFilePath filePath: String?, fallback: String, projectDirectory: URL?) -> String {
        guard let filePath, let projectDirectory else { return fallback }
        // The leading root `"/"` `pathComponents` element is dropped first
        // so `components[start...].joined(separator: "/")` never produces
        // a malformed doubled-slash candidate.
        let components = URL(fileURLWithPath: filePath).pathComponents.filter { $0 != "/" }
        // Longest suffix first: a real relative path (e.g.
        // `Sources/IntegerUtilities/GCD.swift`) should always be preferred
        // over a shorter one that happens to also exist (e.g. a same-named
        // file at the project root), so this walks from the full path
        // down, not up.
        for start in 0 ..< components.count {
            let candidate = components[start...].joined(separator: "/")
            guard !candidate.isEmpty else { continue }
            if FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        return fallback
    }

    private static func bucket(forMuterOutcome outcome: String) -> NormalizedMutant.Bucket {
        switch outcome {
        case "failed", "runtimeError": .killed
        case "passed": .survived
        case "noCoverage": .noCoverage
        case "buildError": .unviable
        case "timeout": .infrastructureFailure
        default: .other
        }
    }

    // MARK: - swift-mutation-testing report.json

    /// Parses `ericodx/swift-mutation-testing`'s own `--output` report —
    /// real shape confirmed against its `Docs/STRYKER-COMPATIBILITY.md`
    /// (a documented, intentional near-superset of the Stryker mutation-
    /// testing-elements schema v1) *and* directly against its real
    /// `JsonReporter.swift` source (found by Codex review before this was
    /// committed as done — see below), not guessed: a top-level `files`
    /// dictionary keyed by path, each holding a `mutants` array.
    ///
    /// Two real, confirmed differences from Muter that make this parser
    /// simpler than `normalizeMuterReport`, not just differently-shaped:
    /// (1) `files` dictionary keys are already real paths *relative to
    /// `projectRoot`* (confirmed in the compatibility doc) — no
    /// filesystem-probing relative-path resolution is needed here at all.
    /// (2) `originalText`/`replacement` are real, always-populated fields
    /// (unlike Muter's `mutationSnapshot`, which a real report never
    /// includes) — so this tool's mutants get real, meaningful text
    /// hashes too, even though `match(mutantKit:muter:)` itself no longer
    /// keys on them (Phase C13; see `CrossToolMutationIdentity`'s own doc
    /// comment for why).
    ///
    /// A leading `/` is stripped from every key. Real bug found by Codex
    /// review before this was committed as done: `JsonReporter`'s actual
    /// key computation is `String(filePath.dropFirst(projectRoot.count))`
    /// — a plain character-count drop, not a proper path-relative
    /// computation — so for a `projectRoot` without a trailing slash
    /// (the normal case) every real key comes out as `"/Sources/
    /// Foo.swift"`, never `"Sources/Foo.swift"`. Left unstripped, this
    /// key could never equal MutantKit's own leading-slash-free
    /// `relativePath`, reproducing the exact "0 matched mutants" class of
    /// bug this whole phase exists to fix, just for a different tool.
    static func normalizeSwiftMutationTestingReport(_ data: Data) throws -> [NormalizedMutant] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReportParsingError.malformedReport("top level is not a JSON object")
        }
        let files = root["files"] as? [String: Any] ?? [:]

        return files.flatMap { rawPath, value -> [NormalizedMutant] in
            let path = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
            guard let fileEntry = value as? [String: Any], let mutants = fileEntry["mutants"] as? [[String: Any]] else { return [] }
            return mutants.compactMap { mutant in
                guard let mutatorName = mutant["mutatorName"] as? String,
                      let location = mutant["location"] as? [String: Any],
                      let start = location["start"] as? [String: Any],
                      let line = start["line"] as? Int, let column = start["column"] as? Int,
                      let status = mutant["status"] as? String
                else { return nil }

                // Real fields, per the compatibility doc — but only ever
                // used for observability/the text-hash fields' own sake;
                // matching itself relies on `line`/`column`, exactly like
                // the Muter path, for the one reason that actually
                // matters here: consistency, so both cross-tool
                // comparisons behave identically rather than one relying
                // on text hashes because this tool happens to supply them
                // and the other not.
                let originalText = mutant["originalText"] as? String ?? ""
                let replacement = mutant["replacement"] as? String ?? ""

                let identity = CrossToolMutationIdentity(
                    relativePath: path, startUTF8Offset: 0, endUTF8Offset: 0,
                    originalTextHash: sha256Hex(originalText), replacementTextHash: sha256Hex(replacement),
                    normalizedOperatorFamily: swiftMutationTestingOperatorFamily(mutatorName),
                    line: line, column: column, originalText: originalText, replacementText: replacement
                )
                return NormalizedMutant(
                    identity: identity, bucket: bucket(forSwiftMutationTestingStatus: status), provenActive: nil,
                    nativeID: mutant["id"] as? String
                )
            }
        }
    }

    /// Status strings per the real tool's own `Docs/STRYKER-COMPATIBILITY.md`
    /// "Status mapping" table (its internal `ExecutionStatus`, not the
    /// Stryker-schema string it separately maps to for the JSON file) —
    /// `"Crash"` counts as killed, matching that same doc's own stated
    /// rationale ("Crash mutants are killed (the mutation was detected)").
    private static func bucket(forSwiftMutationTestingStatus status: String) -> NormalizedMutant.Bucket {
        switch status {
        case "Killed", "Crash": .killed
        case "Survived": .survived
        case "NoCoverage": .noCoverage
        case "Unviable": .unviable
        case "Timeout": .infrastructureFailure
        default: .other
        }
    }
}
