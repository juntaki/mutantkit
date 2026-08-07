import Foundation
import MutationModel
import SwiftFrontend

/// Which lines the baseline suite executed, keyed by repository-relative path.
///
/// This is a baseline-only measurement: the suite runs once with coverage
/// instrumentation, every mutant looks the map up by its own `file` and `line`,
/// and `noCoverage` is decided without re-running. The decision is per-line —
/// "this file appeared in the run" is not enough, because a file can be reached
/// while leaving whole branches un-entered, and those branches are exactly what
/// a mutation can hide in.
///
/// The map is keyed by the same repository-relative, `/`-separated paths the
/// rest of the tool uses. Paths in the source coverage export are absolute, so
/// the reader that builds one of these normalises them by stripping the project
/// root.
public struct CoverageMap: Sendable, Hashable {
    /// 1-based lines that were executed at least once, per repository-relative path.
    public let executedLines: [String: Set<Int>]
    /// Where the claim came from, so a wrong one can be traced back to its source.
    public let source: String

    public init(executedLines: [String: Set<Int>], source: String) {
        self.executedLines = executedLines
        self.source = source
    }

    public var isEmpty: Bool { executedLines.isEmpty }

    public var filesCovered: Int { executedLines.count }

    /// The observation the classifier consumes, or `nil` when the map has
    /// nothing to say about this site.
    ///
    /// Three cases, each of which has to stay distinguishable:
    ///
    /// - The file appears and the line is in the executed set → the line ran,
    ///   so the classifier falls through to its normal survived/activation
    ///   logic. A `mutatedLineWasExecuted: true` observation is returned for
    ///   symmetry, but it does not change the verdict.
    /// - The file appears and the line is *not* in the executed set → the
    ///   mutation is on code the suite never reached. `noCoverage` is the only
    ///   honest verdict, and the runner can establish it without building or
    ///   testing the mutant.
    /// - The file does not appear at all → the map has no claim to make. The
    ///   classifier is called with `nil`, exactly as in a no-coverage run, so
    ///   nothing is reported as uncovered on the basis of missing data.
    public func observation(forFile file: String, line: Int) -> CoverageObservation? {
        guard let lines = executedLines[file] else { return nil }
        return CoverageObservation(
            mutatedLineWasExecuted: lines.contains(line),
            source: source
        )
    }

    /// Whether the line is known to be uncovered, with no claim either way when
    /// the file or line is absent from the map. Used by the runner to decide
    /// whether a mutant can be classified without building it.
    public func isKnownUncovered(_ point: MutationPoint) -> Bool {
        guard let lines = executedLines[point.file] else { return false }
        return !lines.contains(point.line)
    }
}
