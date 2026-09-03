import Foundation
import MutationModel

/// The one canonical, reporter-independent presentation model every
/// reporter that shows survivors (`CISummaryReporter`, `ConsoleReporter`,
/// `HTMLReporter`) renders from.
///
/// Built once from a finished `RunReport`
/// (`SurvivorPresentationBuilder.build(from:)`), wrapping
/// `SurvivorActionabilityReport` — grouping by declaration and clustering
/// mutants sharing one root cause both live there and are never
/// reimplemented here. This type adds only what every reporter was
/// independently recomputing before it existed: a flat, render-ready row per
/// cluster (`groups.flatMap { $0.clusters }`, each row still carrying every
/// member's own full record — grouping is never destructive here either).
///
/// Deliberately does **not** pre-filter by `reason` the way an earlier
/// version of this type did (`.mutationSiteNotCovered` unconditionally
/// dropped, matching `RunReport.survivors`'s `.survived`-only scope). Which
/// reasons an audience should actually see is a rendering decision that
/// differs by reporter — `CISummaryReporter`'s compact PR-comment scope
/// reasonably stays `.survived`-only, matching `report.survivors`, but
/// `ConsoleReporter`/`HTMLReporter` are full local reports and show both
/// `.mutationSiteNotCovered` and `.coveredButNotCaught` — so that choice is
/// made explicitly, visibly, in each reporter's own `survivorSection`, not
/// baked into this shared builder.
public struct SurvivorPresentation: Codable, Sendable {
    public let planID: String
    public let rows: [Row]

    public init(planID: String, rows: [Row]) {
        self.planID = planID
        self.rows = rows
    }

    public struct Aggregate: Codable, Sendable, Equatable {
        public let totalMutants: Int
        public let distinctIssues: Int

        public init(totalMutants: Int, distinctIssues: Int) {
            self.totalMutants = totalMutants
            self.distinctIssues = distinctIssues
        }
    }

    /// One `SurvivorActionabilityReport.IssueCluster`, with its declaration
    /// attached, flattened into the shape every reporter actually iterates
    /// over. Carries the cluster's full `members` list — never a single
    /// "representative" — so no reporter has to lose a collapsed member's
    /// own diff just to render a compact row; that tradeoff belongs to the
    /// reporter, made explicitly when it chooses what to print, not to this
    /// type by construction.
    public struct Row: Codable, Sendable, Equatable {
        public let file: String
        public let declaration: String
        public let reason: SurvivorActionabilityReport.Reason
        /// Every mutant this row's cluster contains, sorted by mutant ID.
        /// Never empty.
        public let members: [SurvivorActionabilityReport.Member]

        public init(
            file: String, declaration: String, reason: SurvivorActionabilityReport.Reason, members: [SurvivorActionabilityReport.Member]
        ) {
            self.file = file
            self.declaration = declaration
            self.reason = reason
            self.members = members
        }

        /// A stable identity for this row, deterministic regardless of
        /// input order — the sorted-first member's own mutant ID. Exists so
        /// a cross-reporter test can assert "the same row appeared in every
        /// reporter" by equality, instead of each test re-deriving a
        /// grouping decision of its own to compare against.
        public var key: String { members.first?.mutantID ?? "" }
        public var count: Int { members.count }
        public var mutantIDs: [String] { members.map(\.mutantID) }
        public var operatorIDs: [String] { Array(Set(members.map(\.operatorID))).sorted() }
        public var reproduceCommands: [String] { members.map(\.reproduceCommand) }

        /// `nil` for `.mutationSiteNotCovered` — there is no test scope to
        /// name when nothing ran at all.
        public var testScope: SurvivorActionabilityReport.TestScope? {
            if case let .coveredButNotCaught(scope) = reason { return scope }
            return nil
        }
    }
}

public enum SurvivorPresentationBuilder {
    /// Builds the shared presentation from a finished run — every actionable
    /// row, both reasons, unfiltered. Pure and deterministic: the same
    /// `RunReport`, regardless of the order its `results` happen to be
    /// stored in, always produces the same `rows` in the same order (proven
    /// by `SurvivorActionabilityReport.build(from:)`'s own total ordering).
    public static func build(from report: RunReport) -> SurvivorPresentation {
        let actionability = SurvivorActionabilityReport.build(from: report)
        let rows = actionability.groups.flatMap { group in
            group.clusters.map { cluster in
                SurvivorPresentation.Row(
                    file: group.file, declaration: group.declaration, reason: cluster.reason, members: cluster.members
                )
            }
        }
        return SurvivorPresentation(planID: actionability.planID, rows: rows)
    }
}

extension [SurvivorPresentation.Row] {
    /// The aggregate counts for whichever subset of rows a reporter actually
    /// renders — computed the same way everywhere, so no reporter's own
    /// header line can drift from what its own rows actually contain.
    public var aggregate: SurvivorPresentation.Aggregate {
        .init(totalMutants: reduce(0) { $0 + $1.count }, distinctIssues: count)
    }
}
