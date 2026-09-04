import Foundation
import MutationModel

// MARK: - Reporter

/// Emits the Mutation Testing Elements report schema, so a run can be viewed in
/// the standard `mutation-testing-elements` HTML viewer and compared against
/// runs from other ecosystems.
///
/// This is an *export*, not the record. `JSONReporter` is the record. Stryker's
/// vocabulary is narrower than ours in ways that lose information (see
/// `strykerStatus`), and the schema has no field for our integrity report, so
/// anything that matters must survive in `statusReason` or not be claimed at all.
public struct StrykerReporter: Reporter {
    /// The viewer syntax-highlights and renders each file's full source. We do
    /// not carry sources in `RunReport` — it is a report, not a snapshot — so a
    /// caller that wants source in the export supplies a way to read it, keyed
    /// by the same repository-relative path `MutationPoint.file` uses.
    public typealias SourceProvider = @Sendable (String) -> String?

    private let sourceProvider: SourceProvider?
    private let thresholds: Thresholds

    public init(
        thresholds: Thresholds = Thresholds(high: 80, low: 60),
        sourceProvider: SourceProvider? = nil
    ) {
        self.thresholds = thresholds
        self.sourceProvider = sourceProvider
    }

    public func render(_ report: RunReport) throws -> String {
        let failClosed = report.score == nil
        var files: [String: FileResult] = [:]

        for result in report.results {
            let path = result.point.file
            let mutant = mutant(for: result, failClosed: failClosed, in: report)

            if var existing = files[path] {
                existing.mutants.append(mutant)
                files[path] = existing
            } else {
                files[path] = FileResult(
                    language: "swift",
                    // Omitted, never faked: the viewer renders `source` as the
                    // file's true contents. An empty string would draw an empty
                    // file, which is a claim we cannot make. An absent key fails
                    // schema validation loudly instead, which is the honest
                    // failure.
                    source: sourceProvider?(path),
                    mutants: [mutant]
                )
            }
        }

        // Sorting mutants inside each file keeps the export byte-stable; the
        // encoder only sorts keys, not arrays.
        for path in files.keys {
            files[path]?.mutants.sort { $0.id < $1.id }
        }

        let strykerReport = StrykerReport(
            schema: Self.schemaURL,
            schemaVersion: Self.schemaVersion,
            thresholds: thresholds,
            projectRoot: report.projectRoot,
            files: files
        )

        return String(decoding: try MutationPlan.encoder().encode(strykerReport), as: UTF8.self)
    }

    private static let schemaVersion = "1.7"
    private static let schemaURL =
        "https://raw.githubusercontent.com/stryker-mutator/mutation-testing-elements/master/packages/report-schema/src/mutation-testing-report-schema.json"

    // MARK: Mutants

    private func mutant(
        for result: MutationResult,
        failClosed: Bool,
        in report: RunReport
    ) -> MutantResult {
        let point = result.point
        let end = Self.endLocation(line: point.line, column: point.column, originalText: point.originalText)

        return MutantResult(
            id: point.id.rawValue,
            mutatorName: point.operatorID,
            replacement: point.replacementText,
            location: Location(
                start: Position(line: point.line, column: point.column),
                end: Position(line: end.line, column: end.column)
            ),
            status: failClosed ? .ignored : Self.strykerStatus(for: result.outcome),
            statusReason: failClosed
                ? "\(FailClosed.headline). Real outcome was '\(result.outcome.displayName)'. \(FailClosed.explanation)"
                : Self.statusReason(for: result),
            description: "\(point.operatorID): replaced `\(point.originalText)` with `\(point.replacementText)` in \(point.enclosingDeclaration)"
        )
    }

    /// Our outcomes carry a reason; Stryker's `status` carries only a verdict.
    /// `statusReason` is the only place the reason survives the export.
    private static func statusReason(for result: MutationResult) -> String {
        var reason = result.diagnosis
        if result.outcome == .killedByCrash {
            // Stryker collapses this into `Killed`; keep the distinction here so
            // it is not lost entirely.
            reason = "Killed by crash or trap rather than a failed assertion. " + reason
        }
        return reason
    }

    // MARK: Status mapping

    /// Maps our outcomes onto Stryker's vocabulary
    /// (Killed, Survived, NoCoverage, CompileError, Timeout, Ignored, RuntimeError).
    ///
    /// Our model is deliberately richer than Stryker's, and this direction is
    /// lossy. What is lost, and why each choice is the honest one:
    ///
    /// - `killedByAssertion` → `Killed`
    /// - `killedByCrash`     → `Killed`
    ///   Lossy: Stryker has one kill. A trap and a failed `#expect` are the same
    ///   verdict to it. The distinction is preserved in `statusReason` only.
    /// - `survived`          → `Survived`
    /// - `noCoverage`        → `NoCoverage`
    /// - `unviable`          → `CompileError`   (exact equivalent)
    /// - `timedOut`          → `Timeout`        (exact equivalent)
    /// - `flaky`             → `Ignored`
    ///   Ignored means "deliberately excluded from the score", which is exactly
    ///   what we do with a mutant whose repeated runs disagree. The *reason* for
    ///   the exclusion is lost; only `statusReason` carries it.
    /// - `skipped`           → `Ignored`        (exact equivalent: excluded before execution)
    /// - `notApplied`        → `RuntimeError`
    /// - `baselineMismatch`  → `RuntimeError`
    /// - `infrastructureFailure` → `RuntimeError`
    ///
    /// The last three have no honest Stryker equivalent and are the reason this
    /// mapping needs a comment at all. Stryker cannot express "the tool failed to
    /// apply the mutation" or "the baseline is not trustworthy" — its vocabulary
    /// assumes the harness worked. Mapping them to `Survived` would be the exact
    /// laundering of an unknown into a test-quality claim this tool exists to
    /// prevent: a phantom mutant would be rendered as a real gap in the suite.
    /// `RuntimeError` is chosen because it is the one status Stryker excludes from
    /// the score while still marking the mutant as *failed*, rather than
    /// *deliberately skipped* — these were not choices, they were breakages, and
    /// `Ignored` would read as though we meant to skip them.
    static func strykerStatus(for outcome: MutationOutcome) -> MutantStatus {
        switch outcome {
        // `.verifiedTimeout` is a confirmed kill (see `MutationOutcome.Detection`)
        // and belongs with the other two, not with the unconfirmed `.timedOut`
        // below — Stryker's schema has no separate "timed out, but confirmed"
        // status, and `.killed` is the one that keeps this export's `Killed`
        // count matching ours.
        case .killedByAssertion, .killedByCrash, .verifiedTimeout: .killed
        case .survived: .survived
        case .noCoverage: .noCoverage
        case .unviable: .compileError
        case .timedOut: .timeout
        case .flaky, .skipped: .ignored
        case .notApplied, .baselineMismatch, .infrastructureFailure: .runtimeError
        }
    }

    // MARK: Location

    /// Stryker wants an exclusive end position; we store only a start. The
    /// mutated text is the span, so the end is derivable from it exactly — no
    /// guessing, and no need to re-read the file.
    ///
    /// - Note on units: `column` (the start — always `MutationPoint.column`
    ///   in practice) is a 1-based **UTF-8 byte offset** from the start of
    ///   its line, exactly `SwiftSyntax.SourceLocation.column`'s own
    ///   contract ("the number of bytes ... occupy when encoded as UTF-8" —
    ///   see `SourceLocation.swift` in the vendored `swift-syntax` package),
    ///   which is where `MutationDiscovery.swift` reads it from. Neither the
    ///   Stryker schema nor SARIF constrains that unit further for a
    ///   byte-offset-sourced tool like this one, but the start and end of
    ///   *one* span must still agree with each other — so the length added
    ///   below is counted in UTF-8 bytes (`.utf8.count`) too, never Swift's
    ///   `Character` count (`.count`, extended grapheme clusters). The two
    ///   diverge for any span containing a multi-byte UTF-8 character
    ///   (accented letters, CJK, emoji, …): counting characters there would
    ///   land `end` short of where the mutated text actually stops, even
    ///   though `start` itself is correct.
    static func endLocation(line: Int, column: Int, originalText: String) -> (line: Int, column: Int) {
        let segments = originalText.split(separator: "\n", omittingEmptySubsequences: false)
        guard segments.count > 1 else {
            return (line, column + originalText.utf8.count)
        }
        // A multi-line span ends at the start of the column after its last
        // line — again counted in UTF-8 bytes, matching `column` above.
        return (line + segments.count - 1, (segments.last?.utf8.count ?? 0) + 1)
    }
}

// MARK: - Schema types

public extension StrykerReporter {
    /// Score thresholds the viewer colours against. Defaults match Stryker's own.
    struct Thresholds: Codable, Sendable, Hashable {
        public let high: Int
        public let low: Int

        public init(high: Int, low: Int) {
            self.high = high
            self.low = low
        }
    }

    /// Stryker's complete status vocabulary.
    ///
    /// `CaseIterable` exists so a schema-conformance test can derive "every
    /// status we can possibly emit" from this declaration itself rather than
    /// a hand-copied string list that could silently drift from it.
    enum MutantStatus: String, Codable, Sendable, CaseIterable {
        case killed = "Killed"
        case survived = "Survived"
        case noCoverage = "NoCoverage"
        case compileError = "CompileError"
        case runtimeError = "RuntimeError"
        case timeout = "Timeout"
        case ignored = "Ignored"
    }

    struct Position: Codable, Sendable, Hashable {
        public let line: Int
        public let column: Int
    }

    struct Location: Codable, Sendable, Hashable {
        public let start: Position
        public let end: Position
    }

    struct MutantResult: Codable, Sendable {
        public let id: String
        public let mutatorName: String
        public let replacement: String?
        public let location: Location
        public let status: MutantStatus
        public let statusReason: String?
        public let description: String?
    }

    struct FileResult: Codable, Sendable {
        public let language: String
        public let source: String?
        public var mutants: [MutantResult]
    }

    struct StrykerReport: Codable, Sendable {
        public let schema: String
        public let schemaVersion: String
        public let thresholds: Thresholds
        public let projectRoot: String?
        public let files: [String: FileResult]

        enum CodingKeys: String, CodingKey {
            case schema = "$schema"
            case schemaVersion
            case thresholds
            case projectRoot
            case files
        }
    }
}
