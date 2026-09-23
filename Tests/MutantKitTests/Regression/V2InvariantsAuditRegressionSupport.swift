import Foundation

/// Shared textual source-scanning helpers for the four regression suites
/// that turn an internal structural-invariants audit's 14 test-coverage
/// gaps into permanent, mechanical gates:
/// `RunSessionAndVerdictPolicyRegressionTests`,
/// `SchemataWorkspaceAndBaselineRegressionTests`,
/// `SchemataCapabilityGuardOrderingRegressionTests`, and
/// `XcodeAdapterStructuralGuardRegressionTests`.
///
/// Every invariant those suites pin is, by the audit's own method, a
/// **structural fact about the current source text** — "site X passes
/// literal `nil`," "exactly N call sites exist," "function Y's body never
/// calls Z" — independently re-derived from `Sources/` rather than assumed
/// true because a plan document once said so. None of the 14 gaps is
/// reachable through a fast unit test that actually *runs* the code (real
/// Xcode/simulator/toolchain infrastructure would be required — exactly
/// why the audit itself verified each one by direct source reading and
/// `grep`, not by execution). A textual re-scan of the real, current file at
/// test time is the same method, made to fail loudly instead of going
/// stale silently — the same stance `ProcessSupervisorBypassRegressionTests`
/// and `DocumentedVersionPinConsistencyTests` already take for their own,
/// unrelated bug classes.
///
/// Factored out once four sibling suites needed the same two primitives
/// (locate `Sources/`, slice out one function/property-block's text) rather
/// than reimplemented four times.
enum V2InvariantsAuditRegressionSupport {
    /// `#filePath`-anchored, like every sibling regression suite in this
    /// directory — resolves identically regardless of the working directory
    /// `swift test` is invoked from, with no environment, git, or build
    /// products involved.
    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/MutantKitTests/Regression/<this file>
            .deletingLastPathComponent() // Regression
            .deletingLastPathComponent() // MutantKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources")
    }

    /// Reads a production source file at a path relative to `Sources/`,
    /// e.g. `"MutationExecution/RunSession.swift"`.
    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: sourcesRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The lines of `text` from the first line containing `startMarker`
    /// (inclusive) up to — but not including — the next later line whose
    /// text starts with `endLinePrefix` (e.g. `"    func "`, a sibling
    /// member declaration at the same 4-space indentation this codebase
    /// uses uniformly for struct/class members). Returns `nil` if
    /// `startMarker` is never found; returns everything to the end of
    /// `text` if no later line matches `endLinePrefix`.
    ///
    /// A textual heuristic, not a parser — the same tradeoff
    /// `ProcessSupervisorBypassRegressionTests`'s own per-line regex scan
    /// makes: it does not balance braces and would not survive a
    /// deeply unusual reformatting, but it is exact about the one thing
    /// each caller below actually needs — "does this specific function's
    /// body, as it reads right now, contain/omit this specific substring."
    static func span(in text: String, startMarker: String, endLinePrefix: String) -> String? {
        let allLines = text.components(separatedBy: .newlines)
        guard let startIndex = allLines.firstIndex(where: { $0.contains(startMarker) }) else { return nil }
        var endIndex = allLines.count
        for index in (startIndex + 1) ..< allLines.count where allLines[index].hasPrefix(endLinePrefix) {
            endIndex = index
            break
        }
        return allLines[startIndex ..< endIndex].joined(separator: "\n")
    }

    /// Like `span(in:startMarker:endLinePrefix:)`, but the end boundary is a
    /// line whose content, trimmed of surrounding whitespace, equals
    /// `closingLine` exactly (e.g. `")"` — the closing paren of a
    /// multi-line call/initializer, which is not left-aligned to a fixed
    /// column the way a member declaration is). Used to slice out one
    /// multi-argument call's own argument list without depending on the
    /// unrelated arguments around the two or three this project's own
    /// invariant actually concerns.
    static func span(in text: String, startMarker: String, untilLineEquals closingLine: String) -> String? {
        let allLines = text.components(separatedBy: .newlines)
        guard let startIndex = allLines.firstIndex(where: { $0.contains(startMarker) }) else { return nil }
        for index in (startIndex + 1) ..< allLines.count
            where allLines[index].trimmingCharacters(in: .whitespaces) == closingLine {
            return allLines[startIndex ... index].joined(separator: "\n")
        }
        return nil
    }

    /// Every non-overlapping span produced by repeatedly applying
    /// `span(in:startMarker:untilLineEquals:)` — one per occurrence of
    /// `startMarker`, each bounded by its own next matching closing line,
    /// scanning forward from just after the previous span's end. Used where
    /// one file legitimately calls the same API more than once (e.g.
    /// `XCTestInvocationService`'s two `ProcessSupervisor.run(...)` call
    /// sites) and every occurrence needs the same assertion, not just the
    /// first.
    static func allSpans(in text: String, startMarker: String, untilLineEquals closingLine: String) -> [String] {
        let allLines = text.components(separatedBy: .newlines)
        var spans: [String] = []
        var searchStart = 0
        while searchStart < allLines.count,
              let startIndex = allLines[searchStart...].firstIndex(where: { $0.contains(startMarker) }) {
            var endIndex: Int?
            for index in (startIndex + 1) ..< allLines.count
                where allLines[index].trimmingCharacters(in: .whitespaces) == closingLine {
                endIndex = index
                break
            }
            guard let endIndex else { break }
            spans.append(allLines[startIndex ... endIndex].joined(separator: "\n"))
            searchStart = endIndex + 1
        }
        return spans
    }

    /// The number of non-overlapping occurrences of `literal` in `text`.
    /// Deliberately a plain substring count (no regex, no word-boundary
    /// logic) — every call site below counts an exact, already-known-shape
    /// spelling (a type name immediately followed by `(`), the same
    /// precision `DocumentedVersionPinConsistencyTests`'s own
    /// `packageRequirements` scanner favors over a more "clever" pattern.
    static func occurrenceCount(of literal: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex ..< text.endIndex
        while let range = text.range(of: literal, range: searchRange) {
            count += 1
            searchRange = range.upperBound ..< text.endIndex
        }
        return count
    }
}
