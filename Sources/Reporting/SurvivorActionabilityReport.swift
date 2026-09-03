import Foundation
import MutationModel

/// Survivor actionability — moves the product from "produces a mutation
/// score" to "a developer looking at a surviving mutant knows what to do
/// next."
///
/// The per-mutant record this needs (file/line, original/mutated, operator,
/// covering tests, actually executed tests, why it survived, reproduce
/// command) already exists — every field is either on `MutationPoint`
/// directly or on `MutationResult.evidence`/`testSummary`, and
/// `InspectCommand` already renders all of it for one mutant at a time.
/// What was missing, and what this file adds, is the *aggregate* view:
/// grouping by file/declaration and
/// clustering survivors that share one root cause — without ever claiming
/// more than the evidence actually proves. See `Reason`/`TestScope`'s own
/// doc comments for exactly where that line is drawn, and why: an earlier
/// version of this type claimed "no test exercises this declaration at all"
/// for `.noCoverage` (stronger than what that outcome means — a single
/// unreached line, not a whole unreached declaration) and claimed "the full
/// suite ran" for `.survived` whenever no narrower selection was on record
/// (true only for wave-based early kill; the overwhelmingly common ordinary
/// invocation records no attempt-level selection at all, so that absence
/// means *unknown*, not *full suite*). Both are fixed here.
public struct SurvivorActionabilityReport: Codable, Sendable {
    public let planID: String
    public let groups: [DeclarationGroup]

    public init(planID: String, groups: [DeclarationGroup]) {
        self.planID = planID
        self.groups = groups
    }

    /// One declaration (function, computed property, initializer, ...) that
    /// has at least one survivor or uncovered mutant. Grouped by
    /// `(file, enclosingDeclaration)` — the same key
    /// `BudgetV2Eval/Corpus.declarationKey(_:)` already uses for its own,
    /// unrelated stratification purpose, reused here because it answers the
    /// same real question: "which one human-authored unit of code is this
    /// mutant actually inside."
    public struct DeclarationGroup: Codable, Sendable {
        public let file: String
        public let declaration: String
        public let clusters: [IssueCluster]

        public init(file: String, declaration: String, clusters: [IssueCluster]) {
            self.file = file
            self.declaration = declaration
            self.clusters = clusters
        }
    }

    /// One root cause within a declaration — every mutant in one cluster
    /// shares the exact same actionability story (a `Reason`). Two
    /// survivors in the same function whose `Reason`s differ (different
    /// `TestScope`, in particular) are kept in *separate* clusters, so one
    /// never hides that it points at a different fix than the other.
    ///
    /// Grouping mutants into one cluster is never destructive: every member
    /// keeps its own file/line/original/replacement/diff/reproduce command.
    /// A UI is free to render a cluster as a single compact row (its own
    /// count, its own distinct operator IDs) — that is a rendering choice a
    /// `Reporter` makes, not something this type decides by discarding
    /// data other members would need.
    public struct IssueCluster: Codable, Sendable {
        public let reason: Reason
        /// Every mutant sharing this cluster's root cause, sorted by
        /// mutant ID. Never empty.
        public let members: [Member]

        public init(reason: Reason, members: [Member]) {
            self.reason = reason
            self.members = members
        }

        public var mutantIDs: [String] { members.map(\.mutantID) }
        /// Distinct operator IDs represented, sorted — a reader scanning for
        /// "is this just one kind of edit or several" answers it without
        /// opening every member.
        public var operatorIDs: [String] { Array(Set(members.map(\.operatorID))).sorted() }
        public var reproduceCommands: [String] { members.map(\.reproduceCommand) }
    }

    /// One surviving/uncovered mutant's own full record — nothing summarized
    /// away, so a cluster of five never costs four of them their own diff.
    public struct Member: Codable, Sendable, Equatable {
        public let mutantID: String
        public let operatorID: String
        public let file: String
        public let line: Int
        public let column: Int
        public let original: String
        public let replacement: String
        /// This mutant's own unified diff, when the run's evidence recorded
        /// one. `nil`, not a placeholder string, when it did not.
        public let sourceDiff: String?
        /// `MutationResult.diagnosis` — the verifier's own one-sentence
        /// explanation for this specific mutant, not re-derived here.
        public let diagnosis: String
        public let reproduceCommand: String

        public init(
            mutantID: String, operatorID: String, file: String, line: Int, column: Int,
            original: String, replacement: String, sourceDiff: String?, diagnosis: String, reproduceCommand: String
        ) {
            self.mutantID = mutantID
            self.operatorID = operatorID
            self.file = file
            self.line = line
            self.column = column
            self.original = original
            self.replacement = replacement
            self.sourceDiff = sourceDiff
            self.diagnosis = diagnosis
            self.reproduceCommand = reproduceCommand
        }

        public var displayLocation: String { "\(file):\(line):\(column)" }
    }

    /// Why every mutant in one `IssueCluster` survived, distinguished
    /// exactly the way `MutationOutcome.survived`/`.noCoverage` already
    /// are — this enum never re-derives that judgment, it only carries it
    /// forward alongside the `TestScope` `.survived`'s own case needs to be
    /// actionable.
    public enum Reason: Codable, Sendable, Equatable {
        /// `MutationOutcome.noCoverage` — per that case's own doc comment,
        /// "tests ran and passed, but nothing executed the mutated line."
        /// A statement about this one mutation site, not about the
        /// enclosing declaration: a declaration can be reached by real
        /// tests while one specific branch inside it (where this mutant
        /// landed) is not. Actionable as "add or extend a test that reaches
        /// this exact site" — never rendered as a claim that the whole
        /// declaration is untested.
        case mutationSiteNotCovered
        /// `MutationOutcome.survived` — the mutant was reached, tests ran,
        /// and none of them failed. `testScope` names what is actually
        /// known about which tests ran in the deciding attempt — see its
        /// own doc comment for why this is deliberately not called
        /// "covering tests": nothing here proves any specific test in that
        /// scope is the one that reached the mutated line, only that the
        /// scope as a whole ran and passed.
        case coveredButNotCaught(testScope: TestScope)

        /// Ordering only — the more severe gap (no test presence at this
        /// site at all) reads above a covered-but-weak one when a reader is
        /// scanning a declaration for what to fix first.
        var severityRank: Int {
            switch self {
            case .mutationSiteNotCovered: 0
            case .coveredButNotCaught: 1
            }
        }
    }

    /// What the run's own evidence actually establishes about which tests
    /// ran in a `.survived` mutant's deciding attempt.
    ///
    /// `MutationEvidence.testAttempts` — the only source this type reads —
    /// is populated **only for wave-based early kill**; an isolated or
    /// ordinary (non-wave) invocation, which is the overwhelmingly common
    /// case, leaves it empty (see that property's own doc comment). Reading
    /// an empty `testAttempts` as "the full suite ran" would be a claim the
    /// evidence does not support — the actual invocation may well have been
    /// narrowed (e.g. by `execution.selectCoveringTests`), just not through
    /// the attempt-tracked path this type has access to. `.unknown` is the
    /// honest label for that gap; a future improvement could recover it (by
    /// having every invocation, not just wave-based ones, append its own
    /// `TestAttemptEvidence`, or by parsing `MutationEvidence.testCommand`'s
    /// raw arguments) — neither attempted here, since both are changes to
    /// `MutationExecution`'s own evidence-construction path, well outside
    /// this presentation-layer type's scope.
    ///
    /// Even a fully-known scope is a list of tests that *ran*, not proof
    /// that any specific one of them is what reached the mutated line —
    /// `selectedTests`/`TestAttemptEvidence` never attribute a mutation site
    /// to one test the way per-test coverage attribution would. A single-
    /// test `.narrowed` scope is the only case strong enough to say "this
    /// test is the one to strengthen"; a multi-test scope only narrows the
    /// search.
    public enum TestScope: Codable, Sendable, Equatable {
        /// At least one deciding attempt explicitly ran a narrowed list —
        /// exactly these tests, and only these, are known to have run.
        case narrowed([String])
        /// At least one deciding attempt explicitly ran with no narrowing:
        /// the whole configured suite, confirmed by the evidence itself
        /// (`TestAttemptEvidence.selectedTests == nil`), not inferred from
        /// its absence.
        case fullSuite
        /// The evidence does not distinguish narrowed from full-suite for
        /// this mutant — see this type's own doc comment.
        case unknown
    }

    /// Builds the grouped, clustered view from a finished run — pure,
    /// deterministic, no I/O, matching every other `Reporter`-adjacent type
    /// in this module. Only `.survived` and `.noCoverage` results
    /// contribute; every other outcome either was killed (nothing to act on)
    /// or describes the tool run, not the test suite (`Reporter.swift`'s own
    /// `excludedCounts` draws the identical line for the same reason).
    ///
    /// Includes both reasons unconditionally — `.mutationSiteNotCovered` and
    /// `.coveredButNotCaught` alike. Which of those a given audience should
    /// actually be shown (a compact CI comment vs. a full local report) is a
    /// rendering decision, made by each `Reporter`, not by this builder.
    public static func build(from report: RunReport) -> SurvivorActionabilityReport {
        let actionable = report.results.filter { $0.outcome == .survived || $0.outcome == .noCoverage }

        let byDeclaration = Dictionary(grouping: actionable) {
            DeclarationKey(file: $0.point.file, declaration: $0.point.enclosingDeclaration)
        }

        let groups = byDeclaration.map { key, results in
            buildGroup(file: key.file, declaration: key.declaration, results: results)
        }
        .sorted { ($0.file, $0.declaration) < ($1.file, $1.declaration) }

        return SurvivorActionabilityReport(planID: report.planID, groups: groups)
    }

    private struct DeclarationKey: Hashable {
        let file: String
        let declaration: DeclarationIdentity
    }

    private static func buildGroup(
        file: String, declaration: DeclarationIdentity, results: [MutationResult]
    ) -> DeclarationGroup {
        let byKey = Dictionary(grouping: results) { clusterKey(for: $0) }

        let clusters = byKey.map { _, members -> IssueCluster in
            let sorted = members.sorted { $0.point.id.rawValue < $1.point.id.rawValue }
            return IssueCluster(
                reason: reason(for: sorted[0]),
                members: sorted.map { result in
                    Member(
                        mutantID: result.point.id.rawValue,
                        operatorID: result.point.operatorID,
                        file: result.point.file,
                        line: result.point.line,
                        column: result.point.column,
                        original: result.point.originalText,
                        replacement: result.point.replacementText,
                        sourceDiff: result.evidence?.sourceDiff,
                        diagnosis: result.diagnosis,
                        reproduceCommand: "mutantkit reproduce \(result.point.id.rawValue)"
                    )
                }
            )
        }
        // Total ordering, so a report built twice from the same (possibly
        // differently-ordered) `results` array always produces byte-identical
        // output: severity band first, then collapsed-mutant count
        // descending (the highest-leverage single fix reads first within a
        // band), then the cluster's own first (sorted) mutant ID as a final,
        // never-tied tiebreaker — `Dictionary(grouping:)` above has no
        // ordering guarantee of its own, so without this last key, two
        // same-size clusters in the same band could swap places from one
        // build to the next.
        .sorted { lhs, rhs in
            if lhs.reason.severityRank != rhs.reason.severityRank {
                return lhs.reason.severityRank < rhs.reason.severityRank
            }
            if lhs.members.count != rhs.members.count {
                return lhs.members.count > rhs.members.count
            }
            return (lhs.members.first?.mutantID ?? "") < (rhs.members.first?.mutantID ?? "")
        }

        return DeclarationGroup(file: file, declaration: declaration.description, clusters: clusters)
    }

    /// The clustering key within a declaration: `.noCoverage` mutants always
    /// cluster together (there is only one way to have zero coverage at a
    /// site); `.survived` mutants cluster with others sharing the *exact
    /// same* `TestScope` — `.unknown` with `.unknown`, `.fullSuite` with
    /// `.fullSuite`, and a `.narrowed` set only with the identical set — so
    /// two mutants with different known scopes never share a cluster, while
    /// two with equally-unknown scopes do (there is nothing to distinguish
    /// them by from this evidence alone; see `members` for why that is not
    /// destructive).
    private static func clusterKey(for result: MutationResult) -> String {
        switch result.outcome {
        case .noCoverage:
            return "noCoverage"
        default:
            switch testScope(for: result) {
            case .unknown: return "survived:unknown"
            case .fullSuite: return "survived:full"
            case let .narrowed(tests): return "survived:narrowed:" + tests.joined(separator: "\u{1F}")
            }
        }
    }

    private static func reason(for result: MutationResult) -> Reason {
        switch result.outcome {
        case .noCoverage:
            .mutationSiteNotCovered
        default:
            .coveredButNotCaught(testScope: testScope(for: result))
        }
    }

    /// See `TestScope`'s own doc comment for what each case actually
    /// establishes and what it deliberately does not claim.
    private static func testScope(for result: MutationResult) -> TestScope {
        guard let attempts = result.evidence?.testAttempts, !attempts.isEmpty else {
            return .unknown
        }
        // An attempt with `selectedTests == nil` explicitly ran with no
        // narrowing -- real, positive evidence the whole suite ran (and
        // still passed), stronger than any `.narrowed` claim, so it wins
        // even if a different wave for the same mutant was narrowed.
        if attempts.contains(where: { $0.selectedTests == nil }) {
            return .fullSuite
        }
        let tests = Array(Set(attempts.compactMap(\.selectedTests).flatMap { $0 })).sorted()
        return tests.isEmpty ? .unknown : .narrowed(tests)
    }
}
