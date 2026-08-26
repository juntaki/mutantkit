import Foundation

/// Phase B1 (rigorous-benchmark program): a mutation identity that means
/// the same thing independent of *any* tool's own bookkeeping, and is
/// durable enough to persist to disk and reuse across many separate
/// benchmark runs — unlike `CrossToolMutationIdentity` (Phase C13), which
/// exists only for the lifetime of one comparison and is never itself
/// written to a file. Fixed at the exact tuple `Research/
/// rigorous-benchmark-2026-08/B0-CONTRACT.md`'s own B1 section specifies:
/// repository commit, relative file path, source position, original
/// text, mutated text, operator intent.
///
/// `repositoryCommit` is part of this identity deliberately, even though
/// every other field is already commit-relative in practice: a canonical
/// corpus is meant to be a durable artifact checked into this repo and
/// reused across many later runs, potentially against a project whose
/// checkout has since moved — this makes explicit, in the data itself,
/// exactly which commit a given canonical mutation was discovered
/// against, so a future comparison against a moved checkout is a
/// conscious decision (re-validate the corpus), never a silent drift.
public struct CanonicalMutation: Codable, Hashable, Sendable {
    public let repositoryCommit: String
    public let relativePath: String
    public let line: Int
    public let column: Int
    public let originalText: String
    public let replacementText: String
    /// The shared vocabulary family (Phase C13's `mutantKitOperatorFamily`/
    /// `muterOperatorFamily`/`swiftMutationTestingOperatorFamily`), e.g.
    /// `"relational-operator"` — never a single tool's own raw operator
    /// ID, since the whole point of this type is to mean the same thing
    /// regardless of which tool discovered it.
    public let operatorFamily: String

    public init(
        repositoryCommit: String, relativePath: String, line: Int, column: Int,
        originalText: String, replacementText: String, operatorFamily: String
    ) {
        self.repositoryCommit = repositoryCommit
        self.relativePath = relativePath
        self.line = line
        self.column = column
        self.originalText = originalText
        self.replacementText = replacementText
        self.operatorFamily = operatorFamily
    }

    /// `a > b` → `a >= b` — the exact human-readable form B0's own spec
    /// example uses. For display/reporting only; never parsed back.
    public var displayDescription: String {
        "\(relativePath):\(line):\(column) \(originalText) → \(replacementText) (\(operatorFamily))"
    }
}

/// One canonical mutation, plus each tool's own native reference to it —
/// the actual corpus entry. `nativeID`/`bucket` are `nil` for a tool that
/// did not discover this exact mutation at all (a real, honest gap, never
/// silently backfilled) — but a `CanonicalMutationCorpusBuilder` only ever
/// *emits* entries present in every tool it was asked to intersect, so in
/// the corpus's own persisted form every field below is populated for
/// every tool that corpus was built from; `nil` only becomes possible if
/// this entry is later re-checked against a tool it was not originally
/// built from.
public struct MatchedMutation: Codable, Sendable {
    public struct ToolReference: Codable, Sendable {
        public let nativeID: String?
        public let bucket: String

        public init(nativeID: String?, bucket: String) {
            self.nativeID = nativeID
            self.bucket = bucket
        }
    }

    public let canonical: CanonicalMutation
    /// Keyed by `BenchmarkToolIdentity.name` (`"mutantkit"`, `"muter"`,
    /// `"swift-mutation-testing"`) — a plain `String` key, not an enum,
    /// so a corpus built against a future fourth tool needs no schema
    /// migration.
    public let tools: [String: ToolReference]

    public init(canonical: CanonicalMutation, tools: [String: ToolReference]) {
        self.canonical = canonical
        self.tools = tools
    }
}

/// The full, persisted corpus — one JSON file per (project, corpus-build)
/// pair, checked into `Research/rigorous-benchmark-2026-08/corpora/`.
public struct CanonicalMutationCorpus: Codable, Sendable {
    public let projectID: String
    public let repositoryCommit: String
    /// ISO 8601. When this corpus was built — a corpus is a snapshot, not
    /// a live query; rebuilding it (e.g. after any of the three tools
    /// changes its own discovery behavior) produces a new file, never an
    /// in-place silent edit of an old one's own mutation list.
    public let builtAt: String
    /// Which tools this corpus's intersection was computed across — a
    /// corpus built from only two tools must never be silently treated as
    /// if it also covers a third.
    public let tools: [String]
    public let mutations: [MatchedMutation]

    public init(projectID: String, repositoryCommit: String, builtAt: String, tools: [String], mutations: [MatchedMutation]) {
        self.projectID = projectID
        self.repositoryCommit = repositoryCommit
        self.builtAt = builtAt
        self.tools = tools
        self.mutations = mutations
    }
}

/// Builds a `CanonicalMutationCorpus` from each tool's own already-parsed
/// `[NormalizedMutant]` (`ResultNormalizer.normalize*Report`) — the real
/// N-way intersection, not a pairwise-against-MutantKit comparison the
/// way `ResultNormalizer.match` computes (Phase C13's own cross-tool
/// comparison, built for a live benchmark run's own report, not for
/// producing a durable, reusable corpus). A mutation only enters the
/// corpus when it is present, at the *same* `(relativePath, line, column)`
/// and the *same* `operatorFamily`, in every tool's own result set passed
/// in — anything present in only some of them is real, and reported
/// (`toolOnlyCounts`), but never included in the corpus itself: B1's own
/// explicit purpose is a mutation set every later phase can treat as
/// "provably the same thing to all three tools," and a partial match does
/// not meet that bar.
public enum CanonicalMutationCorpusBuilder {
    public struct BuildResult: Sendable {
        public let corpus: CanonicalMutationCorpus
        /// How many of each tool's own discovered mutants were *not*
        /// matched into the corpus — real, reportable evidence for B1's
        /// own "candidate counts differ" problem statement, not silently
        /// discarded once the corpus itself is built.
        public let toolOnlyCounts: [String: Int]
        /// How many `(relativePath, line, column, operatorFamily)` keys
        /// were excluded from this tool's own index — and therefore can
        /// never enter the corpus at all — because that single tool
        /// itself reported more than one *distinct* (non-identical)
        /// original/replacement text at the exact same key. This is
        /// never resolved by picking one arbitrarily: a corpus entry
        /// asserts one canonical text as "the" mutation at that position,
        /// and if the tool that actually knows the real text disagrees
        /// with itself about what that text is, no choice is honest —
        /// fail closed and exclude, rather than silently fabricate an
        /// answer another tool (e.g. Muter, whose own report never
        /// carries text at all) could not itself have confirmed. Distinct
        /// from `toolOnlyCounts`, which counts real, unambiguous mutants
        /// simply absent from another tool's own results.
        public let ambiguousCounts: [String: Int]
        /// How many otherwise-matched keys (present, unambiguously, in
        /// every tool's own index) were still excluded because two or
        /// more tools' own *non-empty* texts at that exact position
        /// disagreed — a coincidental key collision between genuinely
        /// different mutations, not the same mutation seen two ways.
        /// Never resolved by picking one tool's version over another's.
        public let crossToolTextDisagreementCount: Int
    }

    /// - Parameter mutantsByTool: every tool's own real, already-parsed
    ///   result set, keyed by the same tool-name strings
    ///   `MatchedMutation.ToolReference` uses. At least two entries are
    ///   required for an intersection to mean anything; an empty or
    ///   single-tool input still returns a (trivially empty or
    ///   single-tool-only) result rather than trapping, since a caller
    ///   discovering a tool produced zero usable mutants is itself a real
    ///   finding this function should not obscure by crashing.
    public static func build(
        projectID: String, repositoryCommit: String, mutantsByTool: [String: [NormalizedMutant]], now: Date = Date()
    ) -> BuildResult {
        typealias Key = CanonicalMutationMatcher.FamilyKey
        struct TextPair: Hashable {
            let original: String
            let replacement: String
        }

        // Tool names are normalized (trimmed, lowercased) before being
        // used as dictionary keys — real bug found by Codex review before
        // this was committed as done: an un-normalized caller passing
        // `"muter"` and `" Muter "` (or any casing/whitespace variant) for
        // what is really the same tool would have looked like two
        // independent tools to the `Set` intersection below, producing a
        // purported two-way corpus that is actually a self-intersection
        // of one tool's own results. Every real caller in this codebase
        // already passes `BenchmarkToolIdentity.name` verbatim
        // (`"mutantkit"`/`"muter"`/`"swift-mutation-testing"`, already
        // lowercase, already trimmed), so this never changes real
        // behavior — it only removes a latent trap for a future caller.
        let normalizedMutantsByTool = Dictionary(
            mutantsByTool.map { (key: $0.key.trimmingCharacters(in: .whitespaces).lowercased(), value: $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let toolNames = normalizedMutantsByTool.keys.sorted()
        guard let firstToolName = toolNames.first else {
            return BuildResult(
                corpus: CanonicalMutationCorpus(
                    projectID: projectID, repositoryCommit: repositoryCommit,
                    builtAt: ISO8601DateFormatter().string(from: now), tools: [], mutations: []
                ),
                toolOnlyCounts: [:], ambiguousCounts: [:], crossToolTextDisagreementCount: 0
            )
        }

        // Index every tool's own mutants by the shared key. When a tool
        // itself reports more than one mutant at the same key, two real
        // cases are distinguished rather than conflated:
        //
        // 1. Every candidate at that key has the *same* (originalText,
        //    replacementText) — a harmless duplicate (e.g. a tool
        //    reporting the identical mutant twice). Collapsing this to
        //    one entry loses nothing, so it is collapsed, with a stable
        //    tie-breaker (sorted by native ID) only to make *which*
        //    duplicate's native ID survives deterministic regardless of
        //    input-array order — never promised stable by
        //    `NormalizedMutant` or any `normalize*Report` function.
        // 2. Candidates at that key disagree — genuinely different
        //    (originalText, replacementText) pairs claim the same
        //    position/family. This used to be resolved by an arbitrary
        //    (if deterministic) tie-break, which silently asserted one
        //    candidate's text as "the" canonical mutation at that
        //    position — a real problem found during B1.1's own design
        //    review: nothing this tool reports can tell us *which* of its
        //    own candidates another tool (e.g. Muter, whose own report
        //    never carries text at all) actually exercised, so no choice
        //    is honest. This key is excluded from this tool's index
        //    entirely — fail closed, never resolved by guessing — and
        //    counted in `ambiguousCounts` instead.
        // Delegates the actual per-tool indexing/ambiguity-resolution to
        // `CanonicalMutationMatcher`, the one shared primitive
        // `MatchedMutantLane` and `ResultNormalizer.match` now also use —
        // this file used to carry its own separate copy of exactly this
        // logic.
        var byToolByKey: [String: [Key: NormalizedMutant]] = [:]
        var ambiguousCounts: [String: Int] = [:]
        for (tool, mutants) in normalizedMutantsByTool {
            let (indexed, ambiguousKeyCount) = CanonicalMutationMatcher.indexedByFamilyKey(mutants)
            byToolByKey[tool] = indexed
            ambiguousCounts[tool] = ambiguousKeyCount
        }

        // The real intersection: only a key present in every tool's own
        // index survives. Starting from the first tool's own keys keeps
        // this correct regardless of how many tools are passed in (2, 3,
        // or a future 4th) rather than hardcoding a 3-way comparison.
        //
        // A single tool is a real, explicit special case, not a
        // degenerate 1-way "intersection" that trivially includes
        // everything that tool found: `dropFirst()` on a 1-element array
        // is empty, so the `reduce` below would never narrow anything —
        // found by this file's own test suite before being shipped.
        // "Intersection" only means something with at least two
        // independent sets to compare.
        let firstToolKeys = Set(byToolByKey[firstToolName]?.keys ?? [:].keys)
        let intersectedKeys: Set<Key> = toolNames.count < 2 ? [] : toolNames.dropFirst().reduce(into: firstToolKeys) { keys, tool in
            let toolKeys = Set(byToolByKey[tool]?.keys ?? [:].keys)
            keys.formIntersection(toolKeys)
        }

        // A second, cross-tool form of the same fail-closed principle:
        // even after each tool's own index is internally unambiguous,
        // two *different* tools can still disagree about what the real
        // text at the same matched position actually is (e.g. one tool's
        // relational-operator mutation there is `==`→`!=`, another's is
        // `==`→`>=`) — a genuinely different mutation coincidentally
        // sharing a key, not the same mutation described two ways. Only
        // tools that report real (non-empty) text can even take part in
        // this check; a tool whose report never carries text (Muter) is
        // silently uninformative here, not a source of disagreement.
        var crossToolTextDisagreementCount = 0
        var disagreementKeys: Set<Key> = []
        for matchKey in intersectedKeys {
            let distinctNonEmptyTexts = Set(
                toolNames.compactMap { byToolByKey[$0]?[matchKey] }
                    .filter { !$0.identity.originalText.isEmpty }
                    .map { TextPair(original: $0.identity.originalText, replacement: $0.identity.replacementText) }
            )
            if distinctNonEmptyTexts.count > 1 {
                crossToolTextDisagreementCount += 1
                disagreementKeys.insert(matchKey)
            }
        }

        let mutations: [MatchedMutation] = intersectedKeys.subtracting(disagreementKeys).compactMap { matchKey in
            // The canonical mutation's own displayed original/replacement
            // text comes from whichever tool actually has real
            // (non-empty) text for it — Muter's own report never carries
            // text at all (Phase C13's own finding), so preferring a
            // tool that does keeps the corpus human-readable rather than
            // defaulting to Muter's empty strings whenever Muter happens
            // to be first alphabetically. Safe to pick either non-empty
            // text now: `disagreementKeys` has already excluded every key
            // where non-empty texts disagreed.
            let representative = toolNames.compactMap { byToolByKey[$0]?[matchKey] }
                .first { !$0.identity.originalText.isEmpty } ?? byToolByKey[firstToolName]?[matchKey]
            guard let representative else { return nil }

            let canonical = CanonicalMutation(
                repositoryCommit: repositoryCommit, relativePath: matchKey.relativePath, line: matchKey.line,
                column: matchKey.column, originalText: representative.identity.originalText,
                replacementText: representative.identity.replacementText, operatorFamily: matchKey.operatorFamily
            )
            var tools: [String: MatchedMutation.ToolReference] = [:]
            for tool in toolNames {
                guard let mutant = byToolByKey[tool]?[matchKey] else { continue }
                tools[tool] = MatchedMutation.ToolReference(nativeID: mutant.nativeID, bucket: mutant.bucket.rawValue)
            }
            return MatchedMutation(canonical: canonical, tools: tools)
        }
        // Sorted for a deterministic, diffable file — an unordered corpus
        // would make every rebuild's own git diff unreadable noise.
        .sorted {
            ($0.canonical.relativePath, $0.canonical.line, $0.canonical.column)
                < ($1.canonical.relativePath, $1.canonical.line, $1.canonical.column)
        }

        var toolOnlyCounts: [String: Int] = [:]
        for tool in toolNames {
            let ownKeys = Set(byToolByKey[tool]?.keys ?? [:].keys)
            toolOnlyCounts[tool] = ownKeys.subtracting(intersectedKeys).count
        }

        return BuildResult(
            corpus: CanonicalMutationCorpus(
                projectID: projectID, repositoryCommit: repositoryCommit,
                builtAt: ISO8601DateFormatter().string(from: now), tools: toolNames, mutations: mutations
            ),
            toolOnlyCounts: toolOnlyCounts, ambiguousCounts: ambiguousCounts,
            crossToolTextDisagreementCount: crossToolTextDisagreementCount
        )
    }
}
