@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("CanonicalMutationCorpusBuilder (Phase B1)")
struct CanonicalMutationCorpusBuilderTests {
    private func makeMutant(
        path: String = "A.swift", line: Int, column: Int, family: String = "relational-operator",
        original: String = "<", replacement: String = ">=", bucket: NormalizedMutant.Bucket = .killed, nativeID: String? = nil
    ) -> NormalizedMutant {
        NormalizedMutant(
            identity: CrossToolMutationIdentity(
                relativePath: path, startUTF8Offset: 0, endUTF8Offset: 0,
                originalTextHash: ResultNormalizer.sha256Hex(original), replacementTextHash: ResultNormalizer.sha256Hex(replacement),
                normalizedOperatorFamily: family, line: line, column: column, originalText: original, replacementText: replacement
            ),
            bucket: bucket, provenActive: nil, nativeID: nativeID
        )
    }

    @Test("A mutation present in all three tools' own result sets enters the corpus")
    func threeWayIntersectionEntersCorpus() throws {
        let mk = [makeMutant(line: 10, column: 5, nativeID: "mut_abc")]
        let muter = [makeMutant(line: 10, column: 5, original: "", replacement: "")]
        let smt = [makeMutant(line: 10, column: 5, nativeID: "smt_1")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter, "swift-mutation-testing": smt]
        )
        #expect(result.corpus.mutations.count == 1)
        let entry = try #require(result.corpus.mutations.first)
        #expect(entry.canonical.relativePath == "A.swift")
        #expect(entry.canonical.line == 10)
        #expect(entry.canonical.column == 5)
        // Real text preferred over Muter's own always-empty text.
        #expect(entry.canonical.originalText == "<")
        #expect(entry.canonical.replacementText == ">=")
        #expect(entry.tools["mutantkit"]?.nativeID == "mut_abc")
        #expect(entry.tools["muter"]?.nativeID == nil)
        #expect(entry.tools["swift-mutation-testing"]?.nativeID == "smt_1")
        #expect(result.toolOnlyCounts["mutantkit"] == 0)
        #expect(result.toolOnlyCounts["muter"] == 0)
        #expect(result.toolOnlyCounts["swift-mutation-testing"] == 0)
    }

    @Test("A mutation only two of three tools found is excluded from the corpus but counted as tool-only")
    func partialMatchIsExcludedButCounted() {
        let mk = [makeMutant(line: 10, column: 5), makeMutant(line: 20, column: 1)]
        let muter = [makeMutant(line: 10, column: 5, original: "", replacement: "")]
        let smt = [makeMutant(line: 10, column: 5)]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter, "swift-mutation-testing": smt]
        )
        #expect(result.corpus.mutations.count == 1, "only the (10,5) mutation is in all three")
        #expect(result.toolOnlyCounts["mutantkit"] == 1, "the (20,1) mutation is MutantKit-only")
        #expect(result.toolOnlyCounts["muter"] == 0)
        #expect(result.toolOnlyCounts["swift-mutation-testing"] == 0)
    }

    @Test("Different operator families at the same position never match")
    func differentFamiliesNeverMatch() {
        let mk = [makeMutant(line: 5, column: 1, family: "relational-operator")]
        let muter = [makeMutant(line: 5, column: 1, family: "logical-connector")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        #expect(result.corpus.mutations.isEmpty)
        #expect(result.toolOnlyCounts["mutantkit"] == 1)
        #expect(result.toolOnlyCounts["muter"] == 1)
    }

    /// B1.1 design correction: this used to assert the two distinct
    /// replacements "collapsed to one canonical mutation" — in practice,
    /// an arbitrary (if deterministic) pick of *which* replacement text
    /// became "the" canonical mutation, with no way for a corpus reader
    /// to know a real disagreement occurred. Muter's own candidate at
    /// this position can never disambiguate which MutantKit replacement
    /// it actually matches (its own report never carries text at all —
    /// see `CrossToolMutationIdentity`'s doc comment), so asserting one
    /// as ground truth was a guess, not a fact. The corpus now fails
    /// closed: this key is excluded entirely, and counted as ambiguous.
    @Test(
        "Two distinct replacements at the same (path, line, column) in one tool are excluded as ambiguous, never arbitrarily resolved"
    )
    func samePositionMultipleDistinctReplacementsExcludedAsAmbiguous() {
        let mk = [
            makeMutant(line: 10, column: 5, replacement: ">="),
            makeMutant(line: 10, column: 5, replacement: "<=")
        ]
        let muter = [makeMutant(line: 10, column: 5, original: "", replacement: "")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        #expect(result.corpus.mutations.isEmpty, "a genuine same-position disagreement must never enter the corpus under one guessed text")
        #expect(result.ambiguousCounts["mutantkit"] == 1)
        #expect(result.toolOnlyCounts["mutantkit"] == 0, "the ambiguous key is excluded outright, not double-counted as tool-only")
        #expect(result.toolOnlyCounts["muter"] == 1, "muter's own now-unmatched candidate is real, reportable tool-only evidence")
    }

    /// The safe counterpart to the above: when a tool reports the exact
    /// same (originalText, replacementText) more than once at the same
    /// key (e.g. a duplicate scan), there is no genuine disagreement —
    /// collapsing loses no information, so this still enters the corpus.
    @Test("Duplicate identical candidates at the same key still collapse safely, not counted as ambiguous")
    func duplicateIdenticalCandidatesCollapseSafely() {
        let mk = [
            makeMutant(line: 10, column: 5, replacement: ">=", nativeID: "mut_b"),
            makeMutant(line: 10, column: 5, replacement: ">=", nativeID: "mut_a")
        ]
        let muter = [makeMutant(line: 10, column: 5, original: "", replacement: "")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        #expect(result.corpus.mutations.count == 1)
        #expect(result.ambiguousCounts["mutantkit"] == 0)
        #expect(
            result.corpus.mutations.first?.tools["mutantkit"]?.nativeID == "mut_a",
            "deterministic tie-break by native ID among identical candidates"
        )
    }

    @Test("An empty input yields an empty corpus, not a crash")
    func emptyInputYieldsEmptyCorpus() {
        let result = CanonicalMutationCorpusBuilder.build(projectID: "example", repositoryCommit: "deadbeef", mutantsByTool: [:])
        #expect(result.corpus.mutations.isEmpty)
        #expect(result.corpus.tools.isEmpty)
    }

    @Test("A single-tool input yields an empty corpus (no intersection possible) without crashing")
    func singleToolInputYieldsEmptyCorpus() {
        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": [makeMutant(line: 1, column: 1)]]
        )
        #expect(result.corpus.mutations.isEmpty)
        #expect(result.toolOnlyCounts["mutantkit"] == 1)
    }

    @Test("The corpus is deterministically ordered by (relativePath, line, column)")
    func corpusIsDeterministicallyOrdered() {
        let mk = [
            makeMutant(path: "Z.swift", line: 1, column: 1),
            makeMutant(path: "A.swift", line: 20, column: 1),
            makeMutant(path: "A.swift", line: 5, column: 1)
        ]
        let muter = mk.map {
            makeMutant(path: $0.identity.relativePath, line: $0.identity.line, column: $0.identity.column, original: "", replacement: "")
        }

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        let ordering = result.corpus.mutations.map { ($0.canonical.relativePath, $0.canonical.line) }
        #expect(ordering.elementsEqual([("A.swift", 5), ("A.swift", 20), ("Z.swift", 1)], by: ==))
    }

    /// Regression test for a real bug found by Codex review before this
    /// was committed as done: tool names were used as raw dictionary
    /// keys with no normalization, so `"muter"` and `" Muter "` looked
    /// like two independent tools to the intersection, even though every
    /// real caller passes the same fixed, already-lowercase
    /// `BenchmarkToolIdentity.name` strings.
    @Test("Tool names are normalized, so casing/whitespace variants never masquerade as independent tools")
    func toolNamesAreNormalized() {
        let mk = [makeMutant(line: 10, column: 5)]
        let muter = [makeMutant(line: 10, column: 5, original: "", replacement: "")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: [" MutantKit ": mk, "MUTER": muter]
        )
        #expect(result.corpus.tools == ["mutantkit", "muter"])
        #expect(result.corpus.mutations.count == 1)
        #expect(result.corpus.mutations.first?.tools["mutantkit"] != nil)
        #expect(result.corpus.mutations.first?.tools["muter"] != nil)
    }

    /// Regression test for a real bug found by Codex review, later
    /// superseded by B1.1's own fail-closed redesign: same-key
    /// collisions were originally resolved by whichever candidate the
    /// input array happened to list first (never promised stable by
    /// `NormalizedMutant` or any `normalize*Report` function), then by a
    /// deterministic-but-arbitrary tie-break. Both are gone now — a
    /// genuine same-key disagreement is excluded, not resolved — so what
    /// this test now guards is that the *exclusion itself* is
    /// order-independent: running the same build twice with the two
    /// disagreeing candidates in reversed order must still exclude the
    /// key both times, not "resolve" it differently depending on order.
    @Test("Same-key ambiguity is excluded identically regardless of input array order")
    func sameKeyAmbiguityExclusionIsOrderIndependent() {
        let lessEqual = makeMutant(line: 10, column: 5, replacement: "<=", nativeID: "mut_a")
        let greaterEqual = makeMutant(line: 10, column: 5, replacement: ">=", nativeID: "mut_b")
        let muter = [makeMutant(line: 10, column: 5, original: "", replacement: "")]

        let forward = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": [lessEqual, greaterEqual], "muter": muter]
        )
        let reversed = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": [greaterEqual, lessEqual], "muter": muter]
        )
        #expect(forward.corpus.mutations.isEmpty && reversed.corpus.mutations.isEmpty)
        #expect(forward.ambiguousCounts["mutantkit"] == 1 && reversed.ambiguousCounts["mutantkit"] == 1)
    }

    // MARK: - B1.1 adversarial fixtures (synthetic, per B0/B1.1's own contract:

    // validating the matcher's own logic, never requiring a real tool to
    // re-execute a real project to exercise an edge case it may not
    // naturally contain).

    @Test("Same line, different columns: two real, distinct mutations never match each other")
    func sameLineDifferentColumnsNeverMatch() {
        let mk = [makeMutant(line: 5, column: 10)]
        let muter = [makeMutant(line: 5, column: 20, original: "", replacement: "")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        #expect(result.corpus.mutations.isEmpty)
        #expect(result.toolOnlyCounts["mutantkit"] == 1)
        #expect(result.toolOnlyCounts["muter"] == 1)
    }

    @Test("Same operator family, multiple real mutations on one line: each position matches independently")
    func sameOperatorFamilyMultipleMutationsPerLineMatchIndependently() {
        let mk = [
            makeMutant(line: 8, column: 3, replacement: ">="),
            makeMutant(line: 8, column: 15, replacement: "!=")
        ]
        let muter = [
            makeMutant(line: 8, column: 3, original: "", replacement: ""),
            makeMutant(line: 8, column: 15, original: "", replacement: "")
        ]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        #expect(result.corpus.mutations.count == 2)
        #expect(Set(result.corpus.mutations.map(\.canonical.column)) == [3, 15])
    }

    @Test("Unicode-equivalent but byte-different text at the same position still matches by position alone")
    func unicodeNormalizationDifferencesStillMatchByPosition() {
        let precomposed = "café" // é as a single precomposed code point
        let decomposed = "cafe\u{0301}" // e + combining acute accent
        // Swift's `==` uses Unicode canonical equivalence, so these already
        // compare equal as `String`s — the byte-level check below is what
        // actually proves this test exercises a real encoding difference,
        // the same difference a naive text-hash match key would see.
        #expect(Array(precomposed.utf8) != Array(decomposed.utf8), "these must actually be byte-different for this test to mean anything")

        let mk = [makeMutant(line: 12, column: 1, original: precomposed, replacement: "x")]
        let smt = [makeMutant(line: 12, column: 1, original: decomposed, replacement: "x", nativeID: "smt_1")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "swift-mutation-testing": smt]
        )
        #expect(result.corpus.mutations.count == 1, "position-based matching must not be defeated by a Unicode representation difference")
    }

    @Test("All tools reporting empty text still match by position, degrading gracefully rather than being excluded")
    func allToolsMissingTextStillMatchByPosition() {
        let mk = [makeMutant(line: 10, column: 5, original: "", replacement: "")]
        let muter = [makeMutant(line: 10, column: 5, original: "", replacement: "")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        #expect(result.corpus.mutations.count == 1)
        #expect(result.corpus.mutations.first?.canonical.originalText == "")
    }

    /// Regression-style robustness test: operator-family strings are
    /// expected to already share a canonical vocabulary by convention
    /// (every real `normalize*Report` function maps into it), but the
    /// builder defensively normalizes casing/whitespace anyway — the
    /// same posture already applied to tool names, since nothing at the
    /// type level enforces a single tool's own casing consistency.
    @Test("Operator-family naming differences (casing/whitespace) never prevent a real match")
    func operatorFamilyNamingDifferencesNormalized() {
        let mk = [makeMutant(line: 10, column: 5, family: "Relational-Operator ")]
        let muter = [makeMutant(line: 10, column: 5, family: " relational-operator", original: "", replacement: "")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        #expect(result.corpus.mutations.count == 1)
    }

    /// Regression test for a real gap Codex review found in the fix
    /// above: casing normalization must never extend to an *unmapped*
    /// operator family. `ResultNormalizer`'s own `*OperatorFamily`
    /// functions deliberately let an unrecognized operator ID fall
    /// through to its own tool-native raw ID rather than a shared
    /// bucket, specifically so it never silently "matches" something
    /// unconfirmed — case is significant there. Two tools' own distinct,
    /// unmapped raw IDs that happen to be case variants of each other
    /// (`FooMutation` vs. `foomutation`) must stay tool-only, never enter
    /// the corpus as a false cross-tool match just because they'd be
    /// equal after lowercasing.
    @Test("Casing normalization never applies to an unmapped/unknown operator family — only to confirmed shared vocabulary")
    func unmappedOperatorFamilyCasingIsNeverNormalized() {
        let mk = [makeMutant(line: 10, column: 5, family: "FooMutation")]
        let muter = [makeMutant(line: 10, column: 5, family: "foomutation", original: "", replacement: "")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        #expect(result.corpus.mutations.isEmpty, "distinct unmapped raw IDs must never be treated as the same family")
        #expect(result.toolOnlyCounts["mutantkit"] == 1)
        #expect(result.toolOnlyCounts["muter"] == 1)
    }

    /// The cross-tool counterpart to same-tool ambiguity: two tools each
    /// report exactly one (internally unambiguous) mutation at the same
    /// key, but their own real texts disagree — a coincidental key
    /// collision between two genuinely different mutations, not the same
    /// mutation described two ways (e.g. different original operators at
    /// that position that both happen to fall in the same family and
    /// exact line/column, or a stale/shifted position on one tool's
    /// side). Must be excluded, never resolved by preferring either
    /// tool's version.
    @Test("Cross-tool text disagreement at the same matched position is excluded, not silently resolved")
    func crossToolTextDisagreementExcluded() {
        let mk = [makeMutant(line: 10, column: 5, original: "==", replacement: "!=")]
        let smt = [makeMutant(line: 10, column: 5, original: "==", replacement: ">=", nativeID: "smt_1")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "swift-mutation-testing": smt]
        )
        #expect(result.corpus.mutations.isEmpty)
        #expect(result.crossToolTextDisagreementCount == 1)
        #expect(result.toolOnlyCounts["mutantkit"] == 0, "still a real matched position, not tool-only, just excluded for disagreement")
        #expect(result.toolOnlyCounts["swift-mutation-testing"] == 0)
    }

    /// A tool with no real text (Muter) never counts as "disagreeing" —
    /// it has nothing to disagree *with*. Only tools that both report
    /// real, non-empty text can create a cross-tool disagreement.
    @Test("A tool with empty text never triggers a cross-tool disagreement against a tool with real text")
    func emptyTextToolNeverTriggersDisagreement() {
        let mk = [makeMutant(line: 10, column: 5, original: "==", replacement: "!=")]
        let muter = [makeMutant(line: 10, column: 5, original: "", replacement: "")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        #expect(result.corpus.mutations.count == 1)
        #expect(result.crossToolTextDisagreementCount == 0)
    }

    /// "Duplicate-looking" mutants: the same tool reports what looks like
    /// the same mutation twice under two different native IDs (e.g. a
    /// tool's own internal duplicate-scan artifact). Identical text means
    /// this is a safe, information-free duplicate — already covered by
    /// `duplicateIdenticalCandidatesCollapseSafely` for the 2-candidate
    /// case; this variant checks 3+ duplicates still collapse to exactly
    /// one canonical entry, not a partial/inconsistent collapse.
    @Test("Three or more duplicate-looking candidates at the same key still collapse to exactly one entry")
    func threeOrMoreDuplicatesCollapseToOne() {
        let mk = [
            makeMutant(line: 10, column: 5, replacement: ">=", nativeID: "mut_c"),
            makeMutant(line: 10, column: 5, replacement: ">=", nativeID: "mut_a"),
            makeMutant(line: 10, column: 5, replacement: ">=", nativeID: "mut_b")
        ]
        let muter = [makeMutant(line: 10, column: 5, original: "", replacement: "")]

        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef",
            mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        #expect(result.corpus.mutations.count == 1)
        #expect(result.ambiguousCounts["mutantkit"] == 0)
        #expect(result.corpus.mutations.first?.tools["mutantkit"]?.nativeID == "mut_a")
    }

    @Test("CanonicalMutationCorpus round-trips through JSON encoding/decoding")
    func corpusRoundTripsThroughJSON() throws {
        let mk = [makeMutant(line: 10, column: 5, nativeID: "mut_abc")]
        let muter = [makeMutant(line: 10, column: 5, original: "", replacement: "")]
        let result = CanonicalMutationCorpusBuilder.build(
            projectID: "example", repositoryCommit: "deadbeef", mutantsByTool: ["mutantkit": mk, "muter": muter]
        )
        let data = try JSONEncoder().encode(result.corpus)
        let decoded = try JSONDecoder().decode(CanonicalMutationCorpus.self, from: data)
        #expect(decoded.mutations.count == 1)
        #expect(decoded.mutations.first?.canonical.displayDescription.contains("→") == true)
    }
}
