import Foundation

/// The one, shared, fail-closed matching primitive every cross-tool
/// comparison in this program uses — `CanonicalMutationCorpusBuilder`,
/// `MatchedMutantLane`, and `ResultNormalizer.match` all used to carry
/// their own separate (and, in two of the three cases, real-bug-carrying)
/// re-implementations of "index one tool's own mutants by position, and
/// resolve same-key duplicates" before this type existed. Extracted after
/// a real review found `MatchedMutantLane.measure` matched only on
/// `(path, line, column)` — never `operatorFamily` or text — so a
/// *different* mutation at the same source position than the one actually
/// in the canonical corpus could silently count as "matched" (in the
/// worst case, `matchedCount > corpusSize`), and `ResultNormalizer.match`
/// used `candidates.first` without ever consuming the candidate or
/// checking for more than one, so two different MutantKit mutants at the
/// same key could both match the same single Muter mutant, and a second,
/// unrelated Muter candidate at an ambiguous key was silently absorbed
/// rather than reported. Both contradicted the "ambiguous match → fail
/// closed, never pick an arbitrary candidate" rule this same codebase
/// already enforced correctly in `CanonicalMutationCorpusBuilder`.
public enum CanonicalMutationMatcher {
    /// Full canonical identity: the same key
    /// `CanonicalMutationCorpusBuilder` has always matched on. Two
    /// mutations are only "the same mutation" when they share this whole
    /// tuple — position alone is not enough, since a different operator
    /// (or, checked separately via text, a different replacement) at the
    /// identical position is a coincidental key collision, not a match.
    public struct FamilyKey: Hashable, Sendable {
        public let relativePath: String
        public let line: Int
        public let column: Int
        public let operatorFamily: String
    }

    /// Position only, deliberately leaving `operatorFamily` free —
    /// `ResultNormalizer.match` needs this to classify a same-position
    /// pair as `exactlyComparable` vs. `approximatelyComparable` *after*
    /// matching, which a family-inclusive key would make impossible to
    /// observe.
    public struct PositionKey: Hashable, Sendable {
        public let relativePath: String
        public let line: Int
        public let column: Int
    }

    /// One (originalText, replacementText) pair — used only to detect
    /// whether multiple candidates at the same key genuinely disagree
    /// about what mutation they are, vs. being harmless duplicates.
    private struct TextPair: Hashable {
        let original: String
        let replacement: String
    }

    /// The fixed, known canonical family vocabulary every real
    /// `normalize*Report` function's own `*OperatorFamily` mapping
    /// function emits (`ResultNormalizer.swift`) — restricts casing
    /// normalization to *confirmed* shared values only, so an unmapped
    /// operator ID falls through to its own tool-native raw ID rather
    /// than a shared bucket two different tools' distinct raw IDs could
    /// otherwise collide into by a pure casing coincidence.
    public static let knownCanonicalFamilies: Set<String> = [
        "boolean-literal", "logical-connector", "relational-operator", "remove-side-effects", "ternary", "unary-not",
        "arithmetic-operator"
    ]

    /// Normalizes a raw operator-family string the same way everywhere:
    /// trims/lowercases only when the result is a *known* canonical
    /// family, never for an unrecognized/tool-native ID.
    public static func normalizedFamily(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return knownCanonicalFamilies.contains(normalized) ? normalized : raw
    }

    public static func familyKey(_ mutant: NormalizedMutant) -> FamilyKey {
        FamilyKey(
            relativePath: mutant.identity.relativePath, line: mutant.identity.line,
            column: mutant.identity.column, operatorFamily: normalizedFamily(mutant.identity.normalizedOperatorFamily)
        )
    }

    public static func positionKey(_ mutant: NormalizedMutant) -> PositionKey {
        PositionKey(relativePath: mutant.identity.relativePath, line: mutant.identity.line, column: mutant.identity.column)
    }

    /// Indexes one tool's own mutants by full canonical identity
    /// (`FamilyKey`), failing closed — excluding, and counting rather
    /// than silently resolving — any key where that tool itself reports
    /// more than one *distinct* (originalText, replacementText) pair.
    /// Identical duplicates at the same key collapse safely (a stable,
    /// deterministic tie-break by native ID, never input-array order).
    public static func indexedByFamilyKey(_ mutants: [NormalizedMutant]) -> (index: [FamilyKey: NormalizedMutant], ambiguousKeyCount: Int) {
        var candidatesByKey: [FamilyKey: [NormalizedMutant]] = [:]
        for mutant in mutants { candidatesByKey[familyKey(mutant), default: []].append(mutant) }

        var index: [FamilyKey: NormalizedMutant] = [:]
        var ambiguousKeyCount = 0
        for (key, candidates) in candidatesByKey {
            let distinctTexts = Set(candidates.map {
                TextPair(original: $0.identity.originalText, replacement: $0.identity.replacementText)
            })
            if distinctTexts.count > 1 {
                ambiguousKeyCount += 1
                continue
            }
            index[key] = candidates.sorted { ($0.nativeID ?? "") < ($1.nativeID ?? "") }.first
        }
        return (index, ambiguousKeyCount)
    }

    /// Indexes one tool's own mutants by position only, failing closed —
    /// excluding, and counting, any position where that tool itself
    /// reports more than one distinct (operatorFamily, originalText,
    /// replacementText) candidate. Used only where `operatorFamily` must
    /// stay free for a later exact/approximate classification
    /// (`ResultNormalizer.match`); every other caller should prefer
    /// `indexedByFamilyKey`, which is strictly the more precise identity.
    public static func indexedByPosition(
        _ mutants: [NormalizedMutant]
    ) -> (index: [PositionKey: NormalizedMutant], ambiguousPositionCount: Int) {
        struct Candidate: Hashable {
            let family: String
            let text: TextPair
        }
        var candidatesByKey: [PositionKey: [NormalizedMutant]] = [:]
        for mutant in mutants { candidatesByKey[positionKey(mutant), default: []].append(mutant) }

        var index: [PositionKey: NormalizedMutant] = [:]
        var ambiguousPositionCount = 0
        for (key, candidates) in candidatesByKey {
            let distinct = Set(candidates.map {
                Candidate(
                    family: normalizedFamily($0.identity.normalizedOperatorFamily),
                    text: TextPair(original: $0.identity.originalText, replacement: $0.identity.replacementText)
                )
            })
            if distinct.count > 1 {
                ambiguousPositionCount += 1
                continue
            }
            index[key] = candidates.sorted { ($0.nativeID ?? "") < ($1.nativeID ?? "") }.first
        }
        return (index, ambiguousPositionCount)
    }
}
