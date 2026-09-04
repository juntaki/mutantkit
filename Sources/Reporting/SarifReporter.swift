import Foundation
import MutationModel

// MARK: - Reporter

/// Exports [SARIF 2.1.0](https://docs.oasis-open.org/sarif/sarif/v2.1.0/os/sarif-v2.1.0-os.html)
/// (Static Analysis Results Interchange Format), so a project whose CI already
/// consumes SARIF — GitHub code scanning, Azure DevOps, most SAST dashboards —
/// can see MutantKit's findings there instead of a format nothing else reads.
///
/// Same scope and the same fail-closed discipline as `SonarReporter`, which
/// this reporter's shape deliberately mirrors:
///
/// - Only `.survived` mutants become results. A `.noCoverage` mutant is a
///   real gap too, but a *different* one — no test ran the line at all,
///   versus a test ran it and did not notice — and SARIF's `result` has no
///   field for that distinction; collapsing both under one `ruleId` would
///   blur which finding a reader is looking at. See `SonarReporter`'s own
///   doc comment for the fuller version of this reasoning, which applies
///   here unchanged.
/// - When `report.score == nil` (integrity failed), this emits a
///   structurally valid, empty-`results` SARIF log — but not a silently
///   "clean" one. Zero results from a tool that ran successfully reads as
///   "found nothing to add", which is not the claim an integrity failure can
///   make, and a dashboard reading only this file — not the console, not the
///   CI summary, not the process exit code — would have no way to tell the
///   two apart from `results` alone. SARIF's own mechanism for that
///   distinction is `run.invocations[].executionSuccessful` plus an
///   `error`-level entry in `toolExecutionNotifications` (see
///   `invocation(for:)`), both of which this reporter sets on the failure
///   path so the signal survives inside the SARIF file itself.
/// - `report.survivors` (see `Reporter.swift`) is reused rather than
///   re-deriving "survived mutants, in reading order".
///
/// - Note on columns: SARIF `region.startColumn`/`endColumn` are 1-based by
///   default (a region's `startLine`/`startColumn` name "the first character
///   in the region" — see the real, vendored schema's own field
///   descriptions, cross-checked in `SarifReporterTests`), the same 1-based
///   convention `MutationPoint.line`/`.column` already use — no *base*
///   translation needed here, unlike `SonarReporter`'s 0-based Sonar columns.
///
///   The *unit*, though, needs a caveat: `MutationPoint.column` is a UTF-8
///   byte offset (`SwiftSyntax.SourceLocation.column`'s own contract — see
///   `MutationDiscovery.swift`), while SARIF's `region.startColumn`/
///   `endColumn` default to counting in UTF-16 code units (`run.columnKind`,
///   left unset here, defaults to `"utf16CodeUnits"`) — and a raw byte
///   offset matches neither that default nor its one alternative,
///   `"unicodeCodePoints"`. For an all-ASCII prefix on the mutated line
///   (true of the overwhelming majority of Swift source) UTF-8 bytes,
///   UTF-16 units and Unicode code points coincide and `startColumn`/
///   `endColumn` land exactly right; they can only drift on a line whose
///   *preceding* text holds a multi-byte UTF-8 character (a non-ASCII
///   identifier, string literal, or comment before the anchor). Reporters
///   deliberately never re-read source files to correct for that (see
///   `Reporter`'s own doc comment), so this file also emits
///   `region.byteOffset`/`byteLength` straight from `MutationPoint
///   .utf8Range`: SARIF defines those as literal, `columnKind`-independent
///   byte counts into the artifact, so — unlike `startColumn`/`endColumn` —
///   they are exactly correct regardless of what precedes the mutation on
///   its line, for any consumer that reads them.
public struct SarifReporter: Reporter {
    public init() {}

    public func render(_ report: RunReport) throws -> String {
        // Fail-closed: see this type's doc comment for why an empty
        // `results` array, not an omitted file or a fabricated finding, is
        // the honest output once integrity has failed.
        guard report.score != nil else {
            return try Self.encode(Self.log(rules: [], results: [], report: report))
        }

        var rulesByID: [String: SarifReportingDescriptor] = [:]
        var results: [SarifResult] = []

        for result in report.survivors {
            let point = result.point
            let ruleID = Self.ruleID(for: point.operatorID)
            if rulesByID[ruleID] == nil {
                rulesByID[ruleID] = SarifReportingDescriptor(
                    id: ruleID,
                    name: point.operatorID,
                    shortDescription: SarifMultiformatMessage(
                        text: "Surviving mutant: \(point.operatorID)"
                    ),
                    fullDescription: SarifMultiformatMessage(text: """
                    MutantKit's '\(point.operatorID)' mutation operator produced a mutant that \
                    the test suite did not catch: the tests ran, covered the mutated code, and \
                    still passed.
                    """),
                    helpUri: Self.homepageURL
                )
            }
            results.append(Self.result(ruleID: ruleID, result: result))
        }

        // Sorted for byte-stable output, matching every other reporter in
        // this module: the encoder only sorts object keys, not arrays.
        let rules = rulesByID.values.sorted { $0.id < $1.id }
        let sortedResults = results.sorted {
            ($0.locations[0].physicalLocation.artifactLocation.uri,
             $0.locations[0].physicalLocation.region.startLine,
             $0.ruleId)
                < ($1.locations[0].physicalLocation.artifactLocation.uri,
                   $1.locations[0].physicalLocation.region.startLine,
                   $1.ruleId)
        }

        return try Self.encode(Self.log(rules: rules, results: sortedResults, report: report))
    }

    private static func encode(_ log: SarifLog) throws -> String {
        String(decoding: try MutationPlan.encoder().encode(log), as: UTF8.self)
    }

    /// The project's own public location — already the `$id` this repo's
    /// own `Schema/mutantkit-v1.json` publishes itself at, reused here
    /// rather than introducing a second, independently-typed URL for the
    /// same project.
    private static let homepageURL = "https://github.com/juntaki/mutantkit"

    private static func log(rules: [SarifReportingDescriptor], results: [SarifResult], report: RunReport) -> SarifLog {
        SarifLog(runs: [
            SarifRun(
                tool: SarifTool(driver: SarifToolComponent(
                    name: "MutantKit",
                    version: report.toolchain.toolVersion,
                    informationUri: homepageURL,
                    rules: rules
                )),
                results: results,
                invocations: [invocation(for: report)]
            )
        ])
    }

    /// SARIF's own mechanism for "the tool ran, but not to a trustworthy
    /// conclusion" — see this type's top-level doc comment for why an empty
    /// `results` array alone cannot carry that distinction.
    /// `executionSuccessful == false` plus an `error`-level
    /// `toolExecutionNotifications` entry is what a real SARIF consumer
    /// (GitHub code scanning reads `executionSuccessful` directly) can key
    /// off of to show this run as failed rather than clean.
    private static func invocation(for report: RunReport) -> SarifInvocation {
        guard report.score == nil else {
            return SarifInvocation(executionSuccessful: true, toolExecutionNotifications: nil)
        }
        return SarifInvocation(
            executionSuccessful: false,
            toolExecutionNotifications: [
                SarifNotification(
                    level: .error,
                    message: SarifMultiformatMessage(text: "\(FailClosed.headline). \(FailClosed.explanation)")
                )
            ]
        )
    }

    static func ruleID(for operatorID: String) -> String { "mutantkit/\(operatorID)" }

    // MARK: Result construction

    private static func result(ruleID: String, result: MutationResult) -> SarifResult {
        let point = result.point
        let end = StrykerReporter.endLocation(line: point.line, column: point.column, originalText: point.originalText)

        return SarifResult(
            ruleId: ruleID,
            level: .warning,
            message: SarifMultiformatMessage(text: message(for: result)),
            locations: [SarifLocation(physicalLocation: SarifPhysicalLocation(
                artifactLocation: SarifArtifactLocation(uri: point.file),
                region: SarifRegion(
                    startLine: point.line,
                    startColumn: point.column,
                    endLine: end.line,
                    endColumn: end.column,
                    byteOffset: point.utf8Range.start,
                    byteLength: point.utf8Range.length
                )
            ))]
        )
    }

    /// The same descriptive content `StrykerReporter.mutant(for:...)` and
    /// `SonarReporter.issueMessage` already assemble for a survivor —
    /// operator, what changed, and the diagnosis — composed here as one
    /// plain-text sentence for SARIF's single `message.text`.
    private static func message(for result: MutationResult) -> String {
        let point = result.point
        return """
        [\(point.operatorID)] Surviving mutant in \(point.enclosingDeclaration.description): replaced \
        `\(point.originalText)` with `\(point.replacementText)`. \(result.diagnosis)
        """
    }
}

// MARK: - Schema types

//
// Field names below are exactly SARIF 2.1.0's own (Swift's default
// camelCase encoding already matches every one of them except `$schema` and
// `version`'s "2.1.0" being a fixed literal, so `SarifLog` is the only type
// here that needs `CodingKeys`).

struct SarifLog: Codable {
    let schema: String
    let version: String
    let runs: [SarifRun]

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version
        case runs
    }

    init(runs: [SarifRun]) {
        schema = "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json"
        version = "2.1.0"
        self.runs = runs
    }
}

struct SarifRun: Codable {
    let tool: SarifTool
    let results: [SarifResult]
    let invocations: [SarifInvocation]
}

/// One record of the tool actually being invoked. SARIF's `executionSuccessful`
/// is the field a consumer checks to tell a genuinely clean run apart from one
/// whose results cannot be trusted — see this file's top-level doc comment and
/// `SarifReporter.invocation(for:)`, the only place that builds one.
struct SarifInvocation: Codable {
    let executionSuccessful: Bool
    let toolExecutionNotifications: [SarifNotification]?
}

/// A notification about the run itself, independent of any one `SarifResult`
/// — SARIF's mechanism for surfacing "the tool could not reach a trustworthy
/// conclusion" without inventing a fake finding to carry that message.
struct SarifNotification: Codable {
    let level: SarifLevel
    let message: SarifMultiformatMessage
}

struct SarifTool: Codable {
    let driver: SarifToolComponent
}

/// The `driver` of `tool`: SARIF's name for "the analysis engine itself", as
/// opposed to an `extensions` entry for a plugin. `name` is the only field
/// SARIF's own schema requires; everything else here is included because a
/// real consumer (GitHub code scanning in particular) uses it to group and
/// link findings back to documentation.
struct SarifToolComponent: Codable {
    let name: String
    let version: String
    let informationUri: String
    let rules: [SarifReportingDescriptor]
}

/// One rule per distinct MutantKit operator that produced a survivor in this
/// report — not one rule per instance, the same one-rule-per-category split
/// `SonarRule`'s doc comment explains.
struct SarifReportingDescriptor: Codable {
    let id: String
    let name: String
    let shortDescription: SarifMultiformatMessage
    let fullDescription: SarifMultiformatMessage
    let helpUri: String
}

struct SarifMultiformatMessage: Codable {
    let text: String
}

struct SarifResult: Codable {
    let ruleId: String
    let level: SarifLevel
    let message: SarifMultiformatMessage
    let locations: [SarifLocation]
}

/// SARIF's four severities. Every `SarifResult` this reporter emits uses
/// `warning` — the same reasoning `SonarSeverity.major`'s doc comment gives:
/// a real behavioural change shipping undetected is worse than cosmetic (not
/// `note`), but it is a gap in test evidence, not a confirmed active defect
/// (not `error`, which most SARIF consumers, GitHub code scanning included,
/// treat as build-affecting). The one exception is the fail-closed
/// `SarifNotification` built by `invocation(for:)`, which deliberately does
/// use `error`: that message reports the run itself as untrustworthy, not a
/// mutant, and `error` is the level most SARIF consumers key off of to
/// surface a run as failed rather than merely noisy.
enum SarifLevel: String, Codable {
    case none
    case note
    case warning
    case error
}

struct SarifLocation: Codable {
    let physicalLocation: SarifPhysicalLocation
}

struct SarifPhysicalLocation: Codable {
    let artifactLocation: SarifArtifactLocation
    let region: SarifRegion
}

/// `uri`: repository-relative, exactly `MutationPoint.file`'s own contract
/// (never absolute — see that property's doc comment) — which is also
/// SARIF's own convention for a `uri` with no `uriBaseId`: resolved relative
/// to the analysis root.
struct SarifArtifactLocation: Codable {
    let uri: String
}

/// `startLine`/`startColumn`/`endLine`/`endColumn` are all 1-based — see
/// this file's top-level doc comment on why no *base* translation is needed
/// here, and for the caveat on their *unit* that `byteOffset`/`byteLength`
/// exist to close: those two are literal, `columnKind`-independent UTF-8
/// byte counts into the artifact (`MutationPoint.utf8Range`, 0-based per
/// SARIF's own convention for `byteOffset`), so they stay exactly correct
/// even on a line where the column pair's unit assumption does not hold.
struct SarifRegion: Codable {
    let startLine: Int
    let startColumn: Int
    let endLine: Int
    let endColumn: Int
    let byteOffset: Int
    let byteLength: Int
}
