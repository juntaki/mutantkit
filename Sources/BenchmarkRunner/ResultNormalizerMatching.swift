import CryptoKit
import Foundation

// MARK: - Cross-tool matching + median + hashing + backend disagreement

//
// Split into its own file (same type, `extension ResultNormalizer`) purely
// to keep `ResultNormalizer.swift` itself under SwiftLint's `file_length`
// limit — not a behavior change. Mirrors the same same-type-split pattern
// already used within `ResultNormalizer.swift` for its own
// `type_body_length` limit.
public extension ResultNormalizer {
    // MARK: - Cross-tool matching

    /// Matches on `relativePath` + `line` + `column` — **not** the text
    /// hashes, as of Phase C13. A real Muter `--format json` report never
    /// carries the mutated text at all (`CrossToolMutationIdentity`'s own
    /// doc comment has the full account), so `originalTextHash`/
    /// `replacementTextHash` hash an empty string for every real Muter
    /// mutant unconditionally — matching on them was structurally
    /// guaranteed to match zero mutants, which is exactly what a real
    /// calibration run found. `line`/`column` are real on both sides and
    /// confirmed to agree for the same real mutation site (see the same
    /// doc comment). `normalizedOperatorFamily` still decides
    /// `exactlyComparable` vs. `approximatelyComparable`, unchanged.
    static func match(mutantKit: [NormalizedMutant], muter: [NormalizedMutant]) -> CrossToolComparison {
        // Grouped (not deduplicated) by position, using the same shared
        // `CanonicalMutationMatcher.positionKey` every other cross-tool
        // comparison in this program keys on. Deliberately *not*
        // `CanonicalMutationMatcher.indexedByPosition`/`indexedByFamilyKey`
        // here: those fail closed by excluding an ambiguous position
        // entirely, which is right for `CanonicalMutationCorpusBuilder`/
        // `MatchedMutantLane` (each needs one, provable canonical
        // mutation per key) but wrong for this function's own, different
        // purpose — this codebase already documents, as an intentional,
        // accepted design (`CrossToolMutationIdentity`'s own doc
        // comment), that several MutantKit mutants at one position all
        // genuinely correspond to the single Muter mutant Muter itself
        // cannot further distinguish (its report never carries text).
        //
        // The real bug fixed here is narrower than "many-to-one is
        // wrong": the previous implementation took `candidates.first`
        // without ever tracking *which* candidate was used, then marked
        // the *entire key* matched — so if Muter's own raw results held
        // two distinct entries at one key (not just MutantKit's), the
        // second one silently vanished from every category (not
        // `exactlyComparable`/`approximatelyComparable`, not
        // `muterOnly` either).
        //
        // Pairing is family-aware and deterministic, not raw-input-array
        // order (an independent review of this exact fix found a real,
        // narrower bug in an earlier draft: pairing purely by index —
        // `muterCandidates[i % muterCandidates.count]` over each side's
        // *raw* input order — could accidentally pair two candidates of
        // *different* families into `approximatelyComparable` while
        // leaving a real same-family match unpaired, purely because of
        // which order a report happened to list its candidates in, which
        // is never a promised, stable property of any `normalize*Report`
        // output). Each position's candidates are first sorted by native
        // ID (the same deterministic tie-break used everywhere else in
        // this codebase), then greedily paired same-family-first —
        // whenever a not-yet-used candidate on the other side shares this
        // one's family, pair with it (guaranteed `exactlyComparable`, and
        // never order-dependent: two same-family candidates always find
        // each other regardless of input order). Only a MutantKit
        // candidate with no same-family Muter candidate left falls back
        // to round-robin over the *full* Muter list at that position —
        // preserving the accepted many-to-one design when Muter truly
        // cannot disambiguate further, while never blocking a real
        // same-family pairing that was available.
        func candidatesByPosition(_ mutants: [NormalizedMutant]) -> [CanonicalMutationMatcher.PositionKey: [NormalizedMutant]] {
            var grouped: [CanonicalMutationMatcher.PositionKey: [NormalizedMutant]] = [:]
            for mutant in mutants { grouped[CanonicalMutationMatcher.positionKey(mutant), default: []].append(mutant) }
            return grouped
        }
        let mkByPosition = candidatesByPosition(mutantKit)
        let muterByPosition = candidatesByPosition(muter)

        var exact: [(NormalizedMutant, NormalizedMutant)] = []
        var approximate: [(NormalizedMutant, NormalizedMutant)] = []
        // Which of each side's own per-position candidates actually got
        // paired at least once — anything never touched belongs in that
        // side's own `-Only` list. Every MutantKit candidate always finds
        // a partner below (the accepted many-to-one design), so only
        // Muter's own leftovers need tracking by index (`usedMuterIndices`).
        var mutantKitOnly: [NormalizedMutant] = []
        var muterOnly: [NormalizedMutant] = []

        for (position, rawMkCandidates) in mkByPosition {
            guard let rawMuterCandidates = muterByPosition[position], !rawMuterCandidates.isEmpty else {
                mutantKitOnly.append(contentsOf: rawMkCandidates)
                continue
            }
            let mkCandidates = rawMkCandidates.sorted { ($0.nativeID ?? "") < ($1.nativeID ?? "") }
            let muterCandidates = rawMuterCandidates.sorted { ($0.nativeID ?? "") < ($1.nativeID ?? "") }

            var usedMuterIndices: Set<Int> = []
            var pairs: [(mk: NormalizedMutant, muterIndex: Int)] = []
            var unresolvedMK: [NormalizedMutant] = []
            for mk in mkCandidates {
                let mkFamily = CanonicalMutationMatcher.normalizedFamily(mk.identity.normalizedOperatorFamily)
                if let matchIndex = muterCandidates.indices.first(where: {
                    !usedMuterIndices.contains($0)
                        && CanonicalMutationMatcher.normalizedFamily(muterCandidates[$0].identity.normalizedOperatorFamily) == mkFamily
                }) {
                    pairs.append((mk, matchIndex))
                    usedMuterIndices.insert(matchIndex)
                } else {
                    unresolvedMK.append(mk)
                }
            }
            // Every MK candidate still gets a partner (the accepted
            // many-to-one design), just never at the cost of a real
            // same-family pairing found above.
            for (offset, mk) in unresolvedMK.enumerated() {
                let muterIndex = offset % muterCandidates.count
                pairs.append((mk, muterIndex))
                usedMuterIndices.insert(muterIndex)
            }

            for (mk, muterIndex) in pairs {
                let muterMutant = muterCandidates[muterIndex]
                if CanonicalMutationMatcher.normalizedFamily(mk.identity.normalizedOperatorFamily)
                    == CanonicalMutationMatcher.normalizedFamily(muterMutant.identity.normalizedOperatorFamily) {
                    exact.append((mk, muterMutant))
                } else {
                    approximate.append((mk, muterMutant))
                }
            }
            // Every MK candidate at this position always finds a partner
            // above, so none contribute to `mutantKitOnly` here. Only
            // Muter candidates genuinely never used (no MK candidate
            // shared their family, and round-robin never happened to
            // land on them) do.
            for (index, muterMutant) in muterCandidates.enumerated() where !usedMuterIndices.contains(index) {
                muterOnly.append(muterMutant)
            }
        }
        for (position, rawMuterCandidates) in muterByPosition where mkByPosition[position] == nil {
            muterOnly.append(contentsOf: rawMuterCandidates)
        }

        return CrossToolComparison(
            exactlyComparable: exact, approximatelyComparable: approximate, mutantKitOnly: mutantKitOnly, muterOnly: muterOnly
        )
    }

    /// Compares MutantKit against any second tool that is not Muter —
    /// added (Phase C13) for the new swift-mutation-testing adapter, and
    /// usable for any future third+ adapter the same way. Forwards to
    /// `match(mutantKit:muter:)` unchanged: the underlying comparison
    /// (`relativePath`/`line`/`column`/operator family) has never actually
    /// been Muter-specific, only its parameter name was — this exists
    /// purely so a non-Muter call site does not read as "compared against
    /// muter" in its own source. `CrossToolComparison`'s own `muter`-named
    /// fields (`muterOnly`, the `muter:` half of each comparable pair)
    /// keep their names regardless of which second tool was actually
    /// passed in, for the same reason: renaming a public, already-used
    /// type for a second call site is a larger, separate change this
    /// phase does not need to make.
    static func match(mutantKit: [NormalizedMutant], comparedAgainst other: [NormalizedMutant]) -> CrossToolComparison {
        match(mutantKit: mutantKit, muter: other)
    }

    // MARK: - Median

    /// The median, not the mean — a single anomalous run (a thermal
    /// throttle, a network hiccup during package resolution) must not skew
    /// the reported number the way it would skew an average.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: - Hashing

    internal static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Backend disagreement (isolated vs schemata, same plan)

    /// One mutation whose isolated-mode and schemata-mode outcome disagree
    /// — always a real finding, never expected in a healthy run (ADR-0006
    /// Stage 3's whole differential-acceptance gate exists to make this
    /// structurally rare in practice).
    struct BackendDisagreement: Codable, Sendable {
        public let identity: CrossToolMutationIdentity
        public let isolatedOutcome: String
        public let schemataOutcome: String
    }

    struct DifferentialValidationResult: Codable, Sendable {
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
    static func compareBackends(isolatedReportData: Data, schemataReportData: Data) throws -> DifferentialValidationResult {
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
