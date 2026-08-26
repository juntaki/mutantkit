import Foundation
import MutationModel

// MARK: - Reporter

/// Exports SonarQube/SonarCloud's [generic issue import
/// format](https://docs.sonarsource.com/sonarqube-server/latest/analyzing-source-code/importing-external-issues/generic-issue-import-format/),
/// so a project that already gates merges on a SonarQube quality gate can see
/// MutantKit's findings there instead of a second, unrelated dashboard.
///
/// - Note on schema version: SonarQube Server 10.3 deprecated the old flat
///   format (an issue object carrying `engineId`/`ruleId`/`severity`/`type`
///   directly) in favour of a two-array `rules` + `issues` document, and
///   10.8+ requires the new shape outright. This reporter emits the current
///   format — a top-level `rules` array (each entry self-describing, with a
///   stable `id`) and a top-level `issues` array of instances that reference
///   a rule by that `id`. See `SonarPayload` below for the exact shape.
///
/// - Note on `textRange`: SonarQube's line numbers are 1-based but its
///   column numbers are 0-based offsets — a documented Sonar-wide convention
///   (their own generic coverage and scanner APIs use the same split). Our
///   own `MutationPoint.column` is 1-based (see its doc comment), so every
///   column here is translated by one; `StrykerReporter.endLocation` is
///   reused to find the end of a (possibly multi-line) span rather than
///   re-deriving that arithmetic a second time.
///
/// - Note on `cleanCodeAttribute`/`impacts`: SonarQube Server 10.4 introduced
///   the Clean Code taxonomy and, from that version's generic-issue-import
///   schema onward, a rule must carry either the classic `type`/`severity`
///   pair *or* `cleanCodeAttribute` + `impacts` — carrying only `type`/
///   `severity` is accepted as a deprecated/back-compat shape on 10.4-10.7
///   but is rejected outright by SonarQube Cloud, whose import validates
///   against the newer schema unconditionally. This reporter emits both: the
///   classic fields for any server still tolerating them, plus
///   `cleanCodeAttribute`/`impacts` so the payload validates on Cloud and on
///   every 10.4+ Server release without a version check at render time. See
///   `SonarRule`'s doc comment for which attribute/impact this reporter
///   chose and why.
///
/// Only `.survived` mutants become issues. A quality gate exists to tell a
/// reviewer what still needs fixing before merge; a killed mutant is exactly
/// the outcome that needed no action, so reporting it as an "issue" would ask
/// for triage of something that already passed. `.noCoverage` is a real gap
/// too, but a *different kind* of gap — no test ran the line at all, versus a
/// test ran it and still didn't notice the mutation — and mixing the two
/// under one rule would blur which finding a reader is looking at, the same
/// reasoning `StrykerReporter`'s status-mapping comment gives for keeping
/// outcomes distinct rather than collapsing them for convenience. A future
/// reporter (or a second rule here) can cover `.noCoverage` on its own if
/// that turns out to be wanted; this one sticks to the single, unambiguous
/// claim the task asked for.
///
/// `report.survivors` (see `Reporter.swift`) is already this codebase's one
/// definition of "survived mutants, in reading order" — every other reporter
/// that needs that exact list uses it, and this one does too rather than
/// re-deriving the filter.
public struct SonarReporter: Reporter {
    public init() {}

    public func render(_ report: RunReport) throws -> String {
        // Fail-closed, same principle as `FailClosed` elsewhere in this
        // module: when integrity failed, `report.score == nil` and nothing
        // downstream is a trustworthy claim about the test suite — including
        // a `.survived` verdict recorded during the broken run. Sonar's
        // schema has no field for "this analysis is not trustworthy", so the
        // honest choice is to import zero issues rather than let unverified
        // diagnostics get filed as reliability debt against real code. This
        // does not read as a false "all clear": an external-issue import
        // with nothing in it only ever means "this particular tool found
        // nothing to add", and the run's own broken-integrity signal is
        // already surfaced loudly elsewhere (console output, CI summary,
        // process exit code) well before a SonarQube quality gate is
        // reached.
        guard report.score != nil else {
            return try Self.encode(SonarPayload(rules: [], issues: []))
        }

        var rulesByID: [String: SonarRule] = [:]
        var issues: [SonarIssue] = []

        for result in report.survivors {
            let point = result.point
            let ruleID = Self.ruleID(for: point.operatorID)
            if rulesByID[ruleID] == nil {
                rulesByID[ruleID] = SonarRule(
                    id: ruleID,
                    name: "Surviving mutant: \(point.operatorID)",
                    description: """
                    MutantKit's '\(point.operatorID)' mutation operator produced a mutant that \
                    the test suite did not catch: the tests ran, covered the mutated code, and \
                    still passed. See the issue message for the specific mutation and diagnosis.
                    """,
                    engineId: Self.engineID,
                    cleanCodeAttribute: .tested,
                    type: .codeSmell,
                    severity: .major,
                    impacts: [SonarImpact(softwareQuality: .maintainability, severity: .medium)]
                )
            }
            issues.append(Self.issue(ruleID: ruleID, result: result))
        }

        // Sorted for byte-stable output, matching `StrykerReporter`'s own
        // reasoning for sorting its per-file mutant arrays: the encoder only
        // sorts object keys, not arrays.
        let payload = SonarPayload(
            rules: rulesByID.values.sorted { $0.id < $1.id },
            issues: issues.sorted {
                ($0.primaryLocation.filePath, $0.primaryLocation.textRange.startLine, $0.ruleId)
                    < ($1.primaryLocation.filePath, $1.primaryLocation.textRange.startLine, $1.ruleId)
            }
        )
        return try Self.encode(payload)
    }

    private static func encode(_ payload: SonarPayload) throws -> String {
        String(decoding: try MutationPlan.encoder().encode(payload), as: UTF8.self)
    }

    /// `mutantkit` is a fixed engine identifier across every rule this
    /// reporter emits — Sonar's own field for "which third-party analyzer
    /// found this", not something that varies per mutation.
    static let engineID = "mutantkit"

    static func ruleID(for operatorID: String) -> String {
        "\(engineID):\(operatorID)"
    }

    // MARK: Issue construction

    private static func issue(ruleID: String, result: MutationResult) -> SonarIssue {
        let point = result.point
        let end = StrykerReporter.endLocation(line: point.line, column: point.column, originalText: point.originalText)

        return SonarIssue(
            ruleId: ruleID,
            primaryLocation: SonarLocation(
                message: issueMessage(for: result),
                filePath: point.file,
                textRange: SonarTextRange(
                    startLine: point.line,
                    endLine: end.line,
                    // Sonar's columns are 0-based; ours are 1-based. See this
                    // file's top-level doc comment.
                    startColumn: point.column - 1,
                    endColumn: end.column - 1
                )
            )
        )
    }

    /// The same descriptive content `ConsoleReporter.survivorSection` and
    /// `StrykerReporter.mutant(for:...)` already assemble for a survivor —
    /// operator, what changed, and the diagnosis — composed here as one
    /// plain-text sentence instead of their multi-line/ANSI-coloured or
    /// separate-field renderings, since a Sonar issue has exactly one
    /// `message` string to work with.
    private static func issueMessage(for result: MutationResult) -> String {
        let point = result.point
        return """
        [\(point.operatorID)] Surviving mutant in \(point.enclosingDeclaration.description): replaced \
        `\(point.originalText)` with `\(point.replacementText)`. \(result.diagnosis)
        """
    }
}

// MARK: - Schema types

/// See `SonarReporter`'s doc comment for why this is the current two-array
/// shape rather than the pre-10.3 flat one. Field names below are exactly
/// SonarQube's own (Swift's default camelCase encoding already matches, so
/// no `CodingKeys` are needed anywhere in this file).
struct SonarPayload: Codable {
    let rules: [SonarRule]
    let issues: [SonarIssue]
}

/// One rule per distinct MutantKit operator that produced a survivor in this
/// report — not one rule per instance. Sonar's rule/issue split exists
/// precisely so a category of finding (e.g. "bool-literal-inversion
/// survived") is described once and every occurrence just references it.
struct SonarRule: Codable {
    let id: String
    let name: String
    let description: String
    let engineId: String

    // `cleanCodeAttribute` places every rule this reporter emits in the
    // Clean Code taxonomy's "Adaptable" category (the attribute's category
    // is fixed by Sonar and not sent separately). `TESTED` is the one
    // attribute in that taxonomy that names, precisely, "verified through
    // automated tests" — a surviving mutant is exactly evidence that a line
    // was not (the mutation changed behaviour and no test noticed), so this
    // is not a guess among equally-plausible attributes the way any of the
    // other thirteen would be.
    let cleanCodeAttribute: SonarCleanCodeAttribute

    // `type`/`severity` are kept for SonarQube Server versions still
    // tolerating the pre-10.4 flat shape (see this file's top-level doc
    // comment); `impacts` is required alongside them from 10.4 onward and
    // unconditionally on SonarQube Cloud.
    let type: SonarRuleType
    let severity: SonarSeverity
    let impacts: [SonarImpact]
}

/// One Clean Code taxonomy attribute a rule violates. Values and their fixed
/// category grouping per SonarSource's own documentation:
/// Consistent (`FORMATTED`, `CONVENTIONAL`, `IDENTIFIABLE`), Intentional
/// (`CLEAR`, `LOGICAL`, `COMPLETE`, `EFFICIENT`), Adaptable (`FOCUSED`,
/// `DISTINCT`, `MODULAR`, `TESTED`), Responsible (`LAWFUL`, `TRUSTWORTHY`,
/// `RESPECTFUL`).
enum SonarCleanCodeAttribute: String, Codable {
    case formatted = "FORMATTED"
    case conventional = "CONVENTIONAL"
    case identifiable = "IDENTIFIABLE"
    case clear = "CLEAR"
    case logical = "LOGICAL"
    case complete = "COMPLETE"
    case efficient = "EFFICIENT"
    case focused = "FOCUSED"
    case distinct = "DISTINCT"
    case modular = "MODULAR"
    /// The attribute every rule this reporter emits uses. See `SonarRule`'s
    /// doc comment for why.
    case tested = "TESTED"
    case lawful = "LAWFUL"
    case trustworthy = "TRUSTWORTHY"
    case respectful = "RESPECTFUL"
}

/// One Software Quality this rule's violations degrade, at a given Impact
/// severity. A rule may in principle carry more than one; this reporter
/// emits exactly one per rule.
struct SonarImpact: Codable {
    let softwareQuality: SonarSoftwareQuality
    let severity: SonarImpactSeverity
}

enum SonarSoftwareQuality: String, Codable {
    case security = "SECURITY"
    case reliability = "RELIABILITY"
    /// What a surviving mutant impacts here: an untested behavioural change
    /// makes the code harder to safely maintain going forward, not (on its
    /// own, absent a confirmed bug) a live reliability or security defect —
    /// the same reasoning `SonarRuleType.codeSmell`'s doc comment gives for
    /// the classic `type` classification below.
    case maintainability = "MAINTAINABILITY"
}

/// Impact severity, distinct from — and not spelled the same as — the
/// classic `SonarSeverity` scale below. `MEDIUM` here is `MAJOR`'s
/// documented mapping in Sonar's own severity-to-impact migration
/// (BLOCKER/CRITICAL -> HIGH, MAJOR -> MEDIUM, MINOR/INFO -> LOW), matching
/// this reporter's `SonarSeverity.major` choice below rather than
/// introducing a second, independent severity judgement for the same
/// finding.
enum SonarImpactSeverity: String, Codable {
    case blocker = "BLOCKER"
    case high = "HIGH"
    case medium = "MEDIUM"
    case low = "LOW"
    case info = "INFO"
}

enum SonarRuleType: String, Codable {
    case bug = "BUG"
    case vulnerability = "VULNERABILITY"
    /// What a surviving mutant is classified as here: not a confirmed bug in
    /// the code under test (the mutant might be behaviourally equivalent, or
    /// simply not yet caught) and not a vulnerability — it is evidence of a
    /// testing gap, which is what `CODE_SMELL` exists to represent in
    /// Sonar's classic three-way taxonomy.
    case codeSmell = "CODE_SMELL"
}

enum SonarSeverity: String, Codable {
    case blocker = "BLOCKER"
    case critical = "CRITICAL"
    /// The severity every rule this reporter emits uses. A surviving mutant
    /// means a real behavioural change could ship completely undetected —
    /// worse than cosmetic, so not `MINOR` — but it is a gap in test
    /// evidence, not a confirmed active defect, so it does not warrant the
    /// `CRITICAL`/`BLOCKER` severities Sonar reserves for issues about code
    /// already known to be broken. `MAJOR` is the defensible middle, and
    /// matches `StrykerReporter`'s own default thresholds treating a
    /// mutation score below "high" as worth real attention rather than a
    /// footnote.
    case major = "MAJOR"
    case minor = "MINOR"
    case info = "INFO"
}

struct SonarIssue: Codable {
    let ruleId: String
    let primaryLocation: SonarLocation

    // `effortMinutes` is deliberately omitted (Sonar defaults it to `0`
    // when absent): there is no principled way to estimate how long
    // strengthening one test takes from the mutation alone, and inventing a
    // number would be exactly the kind of unbacked claim `FailClosed`'s own
    // doc comment (`Reporter.swift`) warns this codebase's reporters away
    // from elsewhere. Leaving it at Sonar's own default is the honest choice.
}

struct SonarLocation: Codable {
    let message: String
    let filePath: String
    let textRange: SonarTextRange
}

struct SonarTextRange: Codable {
    let startLine: Int
    let endLine: Int
    let startColumn: Int
    let endColumn: Int
}
