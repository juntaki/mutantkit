import CryptoKit
import Foundation

/// A mutation identity that means the same thing regardless of which tool
/// produced it — `MutationID` itself is never comparable across tools
/// (each tool mints its own, unrelated scheme), so cross-tool matching
/// needs an identity derived purely from *what changed in the source*, not
/// from either tool's internal bookkeeping. Line/column alone is
/// deliberately not enough: a file with more than one candidate on the
/// same line (a common case for boolean-literal or relational mutants)
/// would collide.
public struct CrossToolMutationIdentity: Codable, Hashable, Sendable {
    public let relativePath: String
    public let startUTF8Offset: Int
    public let endUTF8Offset: Int
    public let originalTextHash: String
    public let replacementTextHash: String
    public let normalizedOperatorFamily: String

    public init(
        relativePath: String, startUTF8Offset: Int, endUTF8Offset: Int,
        originalTextHash: String, replacementTextHash: String, normalizedOperatorFamily: String
    ) {
        self.relativePath = relativePath
        self.startUTF8Offset = startUTF8Offset
        self.endUTF8Offset = endUTF8Offset
        self.originalTextHash = originalTextHash
        self.replacementTextHash = replacementTextHash
        self.normalizedOperatorFamily = normalizedOperatorFamily
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

    public init(identity: CrossToolMutationIdentity, bucket: Bucket, provenActive: Bool?) {
        self.identity = identity
        self.bucket = bucket
        self.provenActive = provenActive
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

            let identity = CrossToolMutationIdentity(
                relativePath: file, startUTF8Offset: start, endUTF8Offset: end,
                originalTextHash: sha256Hex(originalText), replacementTextHash: sha256Hex(replacementText),
                normalizedOperatorFamily: mutantKitOperatorFamily(operatorID)
            )
            let evidencePresent = (result["evidence"] as? [String: Any])?["applicationEvidence"] != nil
            let mutantBucket = bucket(forMutantKitOutcome: outcome)
            if mutantBucket != .infrastructureFailure, mutantBucket != .other, (result["verificationVersion"] as? Int) == 0 {
                falseScoredMutants += 1
            }
            return NormalizedMutant(identity: identity, bucket: mutantBucket, provenActive: evidencePresent)
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

    // MARK: - Muter report.json

    /// Muter's real JSON reporter shape (`Sources/muterCore/TestReporting/
    /// Json/JsonReporter.swift` + `MuterTestReport.swift`, confirmed against
    /// a real regression-test snapshot in the muter repository, not
    /// guessed): `fileReports[].appliedOperators[].{mutationPoint:
    /// {mutationOperatorId, position:{line,column}}, mutationSnapshot:
    /// {before,after}, testSuiteOutcome}`. `position` is line/column, not a
    /// UTF-8 byte offset — Muter's own report never reports one, so
    /// `CrossToolMutationIdentity`'s offsets are synthesized as a stable
    /// (not-necessarily-comparable-to-MutantKit's-own) encoding of
    /// `(line, column)`; the identity's `relativePath` + text hashes +
    /// operator family are what carry real matching weight, exactly as
    /// intended by "not comparing on line/column alone."
    /// Muter's own real phase breakdown — just one total (`timeElapsed`)
    /// and a per-operator mutation count, since Muter's real report.json
    /// never exposes anything finer (no per-mutation build/test split, no
    /// baseline-vs-mutant separation). Observable external boundary only,
    /// per this benchmark's own rule of never distributing a total by
    /// guesswork.
    public struct MuterPhaseTimings: Sendable, Equatable {
        public let totalWallSeconds: Double?
        public let operatorCounts: [String: Int]
    }

    public static func muterPhaseTimings(_ data: Data) throws -> MuterPhaseTimings {
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

    public static func normalizeMuterReport(_ data: Data) throws -> [NormalizedMutant] {
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
                // empty strings when absent — Muter's own bucket outcome
                // (killed/survived/etc.) is still real and counted; only
                // text-hash-based cross-tool matching degrades (an empty-vs-
                // empty hash can still coincidentally collide across two
                // Muter mutants, which `relativePath` + operator family
                // narrows but does not fully prevent — a known, accepted
                // limitation, never worse than dropping the mutant entirely).
                let snapshot = applied["mutationSnapshot"] as? [String: Any]
                let before = snapshot?["before"] as? String ?? ""
                let after = snapshot?["after"] as? String ?? ""

                // Muter's own `position` never carries a byte offset, so
                // `(line, column)` is packed into the offset fields as a
                // stable synthetic pair — never intended to line up
                // numerically with MutantKit's real UTF-8 offsets; matching
                // relies on relativePath + text hashes + operator family.
                let identity = CrossToolMutationIdentity(
                    relativePath: fileName, startUTF8Offset: line * 1_000_000 + column, endUTF8Offset: line * 1_000_000 + column,
                    originalTextHash: sha256Hex(before), replacementTextHash: sha256Hex(after),
                    normalizedOperatorFamily: muterOperatorFamily(operatorID)
                )
                return NormalizedMutant(identity: identity, bucket: bucket(forMuterOutcome: testSuiteOutcome), provenActive: nil)
            }
        }
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

    // MARK: - Cross-tool matching

    /// Matches purely on `relativePath` + text hashes — the offset fields
    /// are excluded from the match key on purpose, since Muter's own
    /// offsets are a synthesized line/column encoding, never a real UTF-8
    /// byte range comparable to MutantKit's. `normalizedOperatorFamily`
    /// decides `exactlyComparable` vs. `approximatelyComparable`.
    public static func match(mutantKit: [NormalizedMutant], muter: [NormalizedMutant]) -> CrossToolComparison {
        struct MatchKey: Hashable {
            let relativePath: String
            let originalTextHash: String
            let replacementTextHash: String
        }
        func key(_ mutant: NormalizedMutant) -> MatchKey {
            MatchKey(
                relativePath: mutant.identity.relativePath, originalTextHash: mutant.identity.originalTextHash,
                replacementTextHash: mutant.identity.replacementTextHash
            )
        }

        var muterByKey: [MatchKey: [NormalizedMutant]] = [:]
        for mutant in muter { muterByKey[key(mutant), default: []].append(mutant) }

        var exact: [(NormalizedMutant, NormalizedMutant)] = []
        var approximate: [(NormalizedMutant, NormalizedMutant)] = []
        var mutantKitOnly: [NormalizedMutant] = []
        var matchedMuterKeys: Set<MatchKey> = []

        for mkMutant in mutantKit {
            let k = key(mkMutant)
            guard let candidates = muterByKey[k], let muterMutant = candidates.first else {
                mutantKitOnly.append(mkMutant)
                continue
            }
            matchedMuterKeys.insert(k)
            if mkMutant.identity.normalizedOperatorFamily == muterMutant.identity.normalizedOperatorFamily {
                exact.append((mkMutant, muterMutant))
            } else {
                approximate.append((mkMutant, muterMutant))
            }
        }
        let muterOnly = muter.filter { !matchedMuterKeys.contains(key($0)) }

        return CrossToolComparison(
            exactlyComparable: exact, approximatelyComparable: approximate, mutantKitOnly: mutantKitOnly, muterOnly: muterOnly
        )
    }

    // MARK: - Median

    /// The median, not the mean — a single anomalous run (a thermal
    /// throttle, a network hiccup during package resolution) must not skew
    /// the reported number the way it would skew an average.
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: - Hashing

    static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Backend disagreement (isolated vs schemata, same plan)

    /// One mutation whose isolated-mode and schemata-mode outcome disagree
    /// — always a real finding, never expected in a healthy run (ADR-0006
    /// Stage 3's whole differential-acceptance gate exists to make this
    /// structurally rare in practice).
    public struct BackendDisagreement: Codable, Sendable {
        public let identity: CrossToolMutationIdentity
        public let isolatedOutcome: String
        public let schemataOutcome: String
    }

    public struct DifferentialValidationResult: Codable, Sendable {
        public let comparableMutations: Int
        public let disagreements: Int
        public let details: [BackendDisagreement]
    }

    /// Compares two MutantKit `report.json` runs of the *identical* plan —
    /// one forced to `execution.strategy: isolated`, one to `schemata` —
    /// matching purely by `CrossToolMutationIdentity`, exactly the same
    /// identity `match(mutantKit:muter:)` uses for cross-tool comparison.
    /// Only mutations both runs actually reported are counted as
    /// "comparable" — a mutation only one run reports (e.g. an
    /// isolated-fallback mutation the schemata run also degraded, so it
    /// exists in both, or one run crashed on it) is not silently treated
    /// as agreement.
    public static func compareBackends(isolatedReportData: Data, schemataReportData: Data) throws -> DifferentialValidationResult {
        let isolated = try normalizeMutantKitReport(isolatedReportData).mutants
        let schemata = try normalizeMutantKitReport(schemataReportData).mutants

        var schemataByIdentity: [CrossToolMutationIdentity: NormalizedMutant] = [:]
        for mutant in schemata { schemataByIdentity[mutant.identity] = mutant }

        var comparable = 0
        var disagreements: [BackendDisagreement] = []
        for isolatedMutant in isolated {
            guard let schemataMutant = schemataByIdentity[isolatedMutant.identity] else { continue }
            comparable += 1
            if isolatedMutant.bucket != schemataMutant.bucket {
                disagreements.append(BackendDisagreement(
                    identity: isolatedMutant.identity,
                    isolatedOutcome: isolatedMutant.bucket.rawValue, schemataOutcome: schemataMutant.bucket.rawValue
                ))
            }
        }
        return DifferentialValidationResult(comparableMutations: comparable, disagreements: disagreements.count, details: disagreements)
    }
}
