import Foundation
import MutationModel
@testable import Reporting
import Testing

/// Stryker's vocabulary is narrower than ours, and the direction of travel is
/// lossy. The specific laundering this suite guards against: folding
/// `notApplied` / `baselineMismatch` / `infrastructureFailure` into `Survived`.
/// A phantom mutant rendered as `Survived` would look exactly like a real gap
/// in the test suite, and the score-side fail-closed could not catch it once
/// the export had left the building.
@Suite("Stryker reporter")
struct StrykerReporterTests {
    /// The complete status mapping. Every outcome has a deterministic Stryker
    /// status, and the three "tool failed" outcomes never become `Survived`.
    @Test("Every outcome maps to a known Stryker status and never to a false Survived")
    func mappingNeverLaunderedAsSurvived() {
        let survivorsLaundered: [MutationOutcome] = [
            .notApplied, .baselineMismatch, .infrastructureFailure,
            .unviable, .timedOut, .flaky, .skipped, .noCoverage,
            .killedByAssertion, .killedByCrash
        ]

        for outcome in survivorsLaundered {
            let status = StrykerReporter.strykerStatus(for: outcome)
            // The four outcome-to-status mappings the schema permits.
            #expect([
                .killed, .survived, .noCoverage, .compileError,
                .runtimeError, .timeout, .ignored
            ].contains(status))

            // Only `survived` becomes `Survived`. Anything else laundered as
            // `Survived` is the bug this suite exists to prevent.
            if outcome != .survived {
                #expect(status != .survived, "\(outcome.displayName) laundered as Survived")
            }
        }

        // The exact mappings, restated so a change shows up as a single line.
        #expect(StrykerReporter.strykerStatus(for: .killedByAssertion) == .killed)
        #expect(StrykerReporter.strykerStatus(for: .killedByCrash) == .killed)
        #expect(StrykerReporter.strykerStatus(for: .survived) == .survived)
        #expect(StrykerReporter.strykerStatus(for: .noCoverage) == .noCoverage)
        #expect(StrykerReporter.strykerStatus(for: .unviable) == .compileError)
        #expect(StrykerReporter.strykerStatus(for: .timedOut) == .timeout)
        #expect(StrykerReporter.strykerStatus(for: .flaky) == .ignored)
        #expect(StrykerReporter.strykerStatus(for: .skipped) == .ignored)
        #expect(StrykerReporter.strykerStatus(for: .notApplied) == .runtimeError)
        #expect(StrykerReporter.strykerStatus(for: .baselineMismatch) == .runtimeError)
        #expect(StrykerReporter.strykerStatus(for: .infrastructureFailure) == .runtimeError)
    }

    /// `killedByCrash` is collapsed to `Killed`, but the distinction survives
    /// in `statusReason`. The status alone is what feeds the viewer's score, so
    /// that direction is allowed to lose information; the reason is what a
    /// reader uses to investigate, so the loss has to be visible there.
    @Test("A crash kill carries its distinction in statusReason")
    func crashKillPreservesDistinction() throws {
        let report = try reportWithOutcome(.killedByCrash, diagnosis: "trapped with SIGTRAP")
        let parsed = try Self.renderAndDecode(report)

        let mutant = try #require(parsed.files.values.flatMap(\.mutants).first)
        #expect(mutant.status == .killed)
        #expect(mutant.statusReason?.contains("crash") == true)
    }

    /// A `flaky` mutant is excluded from our score, which is exactly what
    /// Stryker's `Ignored` means. The mapping is honest in both directions.
    @Test("A flaky mutant maps to ignored")
    func flakyMapsToIgnored() throws {
        let report = try reportWithOutcome(.flaky)
        let parsed = try Self.renderAndDecode(report)

        let mutant = try #require(parsed.files.values.flatMap(\.mutants).first)
        #expect(mutant.status == .ignored)
    }

    @Test("Mutants inside a file are sorted by ID for byte-stable export")
    func mutantsAreSortedByID() throws {
        let a = try Self.anchoredPoint(file: "Sources/Q.swift", line: 1, marker: "A")
        let b = try Self.anchoredPoint(file: "Sources/Q.swift", line: 2, marker: "B")
        let c = try Self.anchoredPoint(file: "Sources/Q.swift", line: 3, marker: "C")

        let plan = Self.plan(mutations: [a, b, c])
        let results = [a, b, c].map {
            Self.result(point: $0, outcome: .killedByAssertion, diagnosis: "killed")
        }
        let report = Self.report(plan: plan, results: results)

        let parsed = try Self.renderAndDecode(report)
        let fileMutants = parsed.files["Sources/Q.swift"]?.mutants
        let mutantIDs = try #require(fileMutants).map { $0.id }

        #expect(mutantIDs == mutantIDs.sorted())
    }

    @Test("Thresholds are recorded verbatim")
    func thresholdsAreRecorded() throws {
        let report = try reportWithOutcome(.killedByAssertion)
        let parsed = try StrykerReporter(thresholds: .init(high: 90, low: 70))
            .render(report)
            |> Self.decode

        #expect(parsed.thresholds.high == 90)
        #expect(parsed.thresholds.low == 70)
    }

    /// A source provider is optional. When supplied, the source is recorded
    /// verbatim; when absent, the `source` key is omitted so the viewer fails
    /// schema validation loudly rather than drawing an empty file.
    @Test("Source is included when a provider is supplied, omitted when not")
    func sourceProviderContract() throws {
        let report = try reportWithOutcome(.killedByAssertion)

        let withSource = try Self.renderAndDecode(
            report, reporter: StrykerReporter(sourceProvider: { _ in "let x = 1" })
        )
        let withoutSource = try Self.renderAndDecode(report)

        #expect(withSource.files.values.first?.source == "let x = 1")
        #expect(withoutSource.files.values.first?.source == nil)
    }

    // MARK: - Location derivation

    /// Stryker wants an exclusive end position. A single-line span ends at the
    /// start column plus the source's UTF-8 byte length — `column` is itself
    /// a UTF-8 byte offset (see `endLocation`'s own doc comment), and this
    /// fixture is ASCII-only, so byte count and `Character` count coincide
    /// and cannot tell the two apart; `singleLineEndLocationCountsUTF8Bytes`
    /// below is the test that actually distinguishes them.
    @Test("A single-line span ends at column + length")
    func singleLineEndLocation() {
        let end = StrykerReporter.endLocation(line: 3, column: 8, originalText: "true")
        #expect(end.line == 3)
        #expect(end.column == 12)
    }

    /// A multi-line span ends at the start of the column after its last line,
    /// matching how editors compute selections.
    @Test("A multi-line span ends on the last line")
    func multiLineEndLocation() {
        let end = StrykerReporter.endLocation(
            line: 4, column: 3, originalText: "foo\nbar\nbaz"
        )
        #expect(end.line == 6)
        #expect(end.column == 4)
    }

    @Test("An empty original text ends where it starts")
    func emptyEndLocation() {
        let end = StrykerReporter.endLocation(line: 5, column: 9, originalText: "")
        #expect(end.line == 5)
        #expect(end.column == 9)
    }

    /// `column` is a UTF-8 byte offset (see `endLocation`'s own doc comment
    /// and `discoveredPositionsAreOneBasedWithNoOffByOne` below, which proves
    /// it empirically for real discovered points). A span whose text holds a
    /// multi-byte UTF-8 character must therefore advance `end.column` by its
    /// *byte* count, not its `Character` (grapheme cluster) count — "é" is
    /// one `Character` but two UTF-8 bytes, and "🎉" is one `Character` but
    /// four. Before the fix this test guards, `endLocation` added
    /// `originalText.count` (2 here) instead of `originalText.utf8.count`
    /// (6 here), landing `end.column` four bytes short of the text's real
    /// extent — inside the mutated text's own byte range, not past its end
    /// as an exclusive end position must be.
    @Test("A single-line span with multi-byte UTF-8 characters ends at column + UTF-8 byte length, not Character count")
    func singleLineEndLocationCountsUTF8Bytes() {
        let text = "é🎉" // 2 Characters, 2 Unicode scalars, 6 UTF-8 bytes
        #expect(text.count == 2)
        #expect(text.utf8.count == 6)

        let end = StrykerReporter.endLocation(line: 1, column: 1, originalText: text)
        #expect(end.column == 1 + text.utf8.count)
    }

    /// Same fix, exercised on the multi-line branch: the trailing partial
    /// line's contribution to `end.column` must also be counted in UTF-8
    /// bytes, matching the single-line branch and `column` itself.
    @Test("A multi-line span with multi-byte UTF-8 characters on its last line ends at the UTF-8 byte column, not Character count")
    func multiLineEndLocationCountsUTF8BytesOnLastLine() {
        let end = StrykerReporter.endLocation(line: 1, column: 1, originalText: "a\nb🎉")
        // Last line is "b🎉": 2 Characters, 5 UTF-8 bytes ("b" + 4-byte emoji).
        #expect(end.column == 5 + 1)
    }

    // MARK: - Real schema conformance

    //
    // Everything above decodes the export back through `StrykerReport`
    // itself, which is Codable and therefore silently tolerant of a missing
    // *optional* key — exactly the shape a real conformance gap takes here
    // (see `sourceProviderContract` above: an absent `source` decodes to
    // `nil` without complaint). These tests instead parse the rendered JSON
    // as a bare `[String: Any]` and check it against `Schema/stryker-v1.7.json`
    // — the real, vendored, official Mutation Testing Report Schema this
    // reporter's own `schemaURL`/`schemaVersion` claim compatibility with —
    // using `StrykerSchemaValidator` (see that type for what "conformance"
    // means here and what it deliberately does not check).

    /// Every outcome, rendered on its own (so fail-closed dilution from one
    /// outcome can't mask another's shape — see `reportWithOutcome`'s own
    /// comment on why two distinct files keep the score non-nil), conforms to
    /// the real schema when a source provider is supplied. This is the
    /// reporter's advertised contract (`RunCommand.emit` always supplies one
    /// for real runs) and the case the schema was checked against here.
    @Test("Every real outcome, rendered with a source provider, conforms to the real Stryker schema")
    func everyOutcomeConformsToRealSchemaWithSource() throws {
        let schema = try Self.loadRealStrykerSchema()
        let validator = StrykerSchemaValidator(schemaDocument: schema)
        var failures: [String] = []

        for outcome in MutationOutcome.allCases {
            let report = try reportWithOutcome(outcome, diagnosis: "diagnosis for \(outcome.rawValue)")
            let rendered = try StrykerReporter(sourceProvider: { _ in "// source\n" }).render(report)
            let document = try Self.parseJSONObject(rendered)
            let errors = validator.validate(document)
            if !errors.isEmpty {
                failures.append("outcome \(outcome.rawValue):\n  " + errors.joined(separator: "\n  "))
            }
        }

        #expect(failures.isEmpty, "Real schema violations found:\n\(failures.joined(separator: "\n"))")
    }

    /// The real, currently-existing conformance gap this pass found: the
    /// schema's `FileResult` requires `source` (`"required": ["language",
    /// "source", "mutants"]`), but `StrykerReporter.FileResult.source` is
    /// `String?`, and Swift's synthesized `Encodable` omits a `nil` optional's
    /// key entirely rather than encoding `null` — so the common case (no
    /// `sourceProvider`, or one that can't read a given file — `RunCommand
    /// .emit` builds its provider with `try?`, which turns a read failure
    /// into exactly this) silently produces a document a real Stryker viewer
    /// would reject. The reporter's own comment calls this "the honest
    /// failure" on the theory that an absent key "fails schema validation
    /// loudly" — this test is what makes that failure actually loud (a real,
    /// running check) rather than a claim nothing enforced. Not fixed here:
    /// the two honest fixes (require a provider, or read the file from disk
    /// by default) are both real behavior changes to a reporter whose
    /// existing no-faking rationale is deliberate, not an oversight — see the
    /// task report for the two options.
    @Test("Without a source provider, the export violates the real schema's required `source` field")
    func missingSourceProviderViolatesRealSchema() throws {
        let schema = try Self.loadRealStrykerSchema()
        let validator = StrykerSchemaValidator(schemaDocument: schema)

        let report = try reportWithOutcome(.survived)
        let rendered = try StrykerReporter().render(report) // no sourceProvider
        let document = try Self.parseJSONObject(rendered)
        let errors = validator.validate(document)

        #expect(!errors.isEmpty)
        #expect(errors.contains { $0.contains("source") && $0.contains("missing required key") })
    }

    /// Guards the exact concern the task flagged in other tools: a status
    /// string leaking outside the schema's own enum (its report named
    /// `Crash`/`Unviable` as the kind of thing to check for). Derived from
    /// the schema's own parsed `enum` array and from `MutantStatus
    /// .allCases`, not from a hand-copied literal list on either side, so a
    /// future case added to either without the other shows up here.
    @Test("Every MutantStatus we can emit is a member of the real schema's status enum")
    func everyStatusIsInTheRealSchemaEnum() throws {
        let schema = try Self.loadRealStrykerSchema()
        let properties = try #require(schema["properties"] as? [String: Any])
        let files = try #require(properties["files"] as? [String: Any])
        let fileSchema = try #require(files["additionalProperties"] as? [String: Any])
        let fileProperties = try #require(fileSchema["properties"] as? [String: Any])
        let mutants = try #require(fileProperties["mutants"] as? [String: Any])
        let items = try #require(mutants["items"] as? [String: Any])
        let mutantProperties = try #require(items["properties"] as? [String: Any])
        let statusSchema = try #require(mutantProperties["status"] as? [String: Any])
        let realEnum = try #require(statusSchema["enum"] as? [String])

        let ours = Set(StrykerReporter.MutantStatus.allCases.map(\.rawValue))
        let real = Set(realEnum)
        #expect(ours.isSubset(of: real), "MutantKit emits a status the real v1.7 schema doesn't know: \(ours.subtracting(real))")
    }

    /// The "column off-by-one" the task named as a known failure mode in
    /// other tools, checked empirically rather than by trusting `MutationPoint
    /// .line`/`.column`'s own doc comment: for several real, independently
    /// discovered points across operators and lines, the byte at
    /// `(line, column)` — both 1-based, exactly as the real schema's
    /// `Position` definition requires ("Both line and column start at one")
    /// — in the *original* source text is genuinely the first byte of
    /// `originalText`, with no off-by-one in either direction.
    @Test("A discovered point's (line, column) is 1-based and lands exactly on its originalText, not one byte off")
    func discoveredPositionsAreOneBasedWithNoOffByOne() throws {
        let source = """
        struct Calculator {
            func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
                if value < lower { return lower }
                if value > upper && lower <= upper { return upper }
                return value
            }
        }
        """
        let points = try discover(source, path: "Sources/Calculator.swift", using: Operators.relational)
        #expect(!points.isEmpty)

        let lines = source.components(separatedBy: "\n")
        for point in points {
            #expect(point.line >= 1 && point.line <= lines.count, "point claims line \(point.line), source has \(lines.count) lines")
            guard point.line >= 1, point.line <= lines.count else { continue }
            let lineBytes = Array(lines[point.line - 1].utf8)
            let startByte = point.column - 1 // schema/point column is 1-based
            let expectedByteCount = point.originalText.utf8.count
            #expect(startByte >= 0, "column \(point.column) on line \(point.line) is < 1")
            #expect(startByte + expectedByteCount <= lineBytes.count, "originalText runs past end of line \(point.line)")
            guard startByte >= 0, startByte + expectedByteCount <= lineBytes.count else { continue }
            let actual = String(decoding: lineBytes[startByte ..< startByte + expectedByteCount], as: UTF8.self)
            #expect(actual == point.originalText, "line \(point.line) col \(point.column): expected '\(point.originalText)', found '\(actual)'")
        }
    }

    // MARK: - Helpers

    private static func loadRealStrykerSchema() throws -> [String: Any] {
        let url = Acceptance.packageRoot.appendingPathComponent("Schema/stryker-v1.7.json")
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func parseJSONObject(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func reportWithOutcome(
        _ outcome: MutationOutcome,
        diagnosis: String = "test diagnosis"
    ) throws -> RunReport {
        // Two distinct source files give two distinct anchored IDs without
        // hand-writing them — and the IDs recompute identically, which is what
        // lets integrity pass and the score be non-nil.
        let point = try Self.anchoredPoint(file: "Sources/Q.swift", line: 7, marker: "Q")
        let plan = Self.plan(mutations: [point])
        let results = [Self.result(point: point, outcome: outcome, diagnosis: diagnosis)]
        return Self.report(plan: plan, results: results)
    }

    private static func renderAndDecode(
        _ report: RunReport,
        reporter: StrykerReporter = StrykerReporter()
    ) throws -> StrykerReporter.StrykerReport {
        try reporter.render(report) |> decode
    }

    private static func decode(_ json: String) throws -> StrykerReporter.StrykerReport {
        try MutationPlan.decoder().decode(
            StrykerReporter.StrykerReport.self,
            from: Data(json.utf8)
        )
    }

    /// Discover a real, anchored point. `marker` differentiates sources so two
    /// points in the same file still get distinct, stable IDs.
    private static func anchoredPoint(file: String, line: Int, marker: String) throws -> MutationPoint {
        let source = """
        struct \(marker) {
            var enabled = true
        }
        """
        return try discover(source, path: file, using: Operators.boolLiteral)[0]
    }

    private static func plan(mutations: [MutationPoint]) -> MutationPlan {
        MutationPlan(
            planID: "plan_stryker",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projectRoot: "/p",
            toolchain: ToolchainFingerprint(
                toolVersion: "0.1.0", toolCommitSHA: nil,
                swiftVersion: "6.3.3", swiftSyntaxVersion: "603.0.2",
                xcodeVersion: nil
            ),
            configurationHash: ContentHash.of("config"),
            sourceFileHashes: [:],
            mutations: mutations,
            skipped: [],
            operators: []
        )
    }

    private static func result(
        point: MutationPoint, outcome: MutationOutcome, diagnosis: String
    ) -> MutationResult {
        makeResult(
            point: point,
            outcome: outcome,
            evidence: MutationEvidence(
                sourceBeforeHash: ContentHash.of("before"),
                sourceAfterHash: ContentHash.of("after"),
                sourceDiff: "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-true\n+false\n",
                buildProductHash: ContentHash.of("mutant"),
                applicationEvidence: .isolated(.buildProductDiffersFromBaseline(
                    mutantHash: ContentHash.of("mutant"),
                    baselineHash: ContentHash.of("baseline")
                ))
            ),
            testSummary: TestOutcomeSummary(
                total: 1, passed: outcome == .survived ? 1 : 0,
                failed: outcome == .survived ? 0 : 1,
                failingTests: outcome == .survived ? [] : ["X/y()"],
                durationSeconds: 0.1
            ),
            diagnosis: diagnosis,
            durationSeconds: 0.5
        )
    }

    private static func report(plan: MutationPlan, results: [MutationResult]) -> RunReport {
        RunReport(
            planID: plan.planID,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 100),
            projectRoot: plan.projectRoot,
            toolchain: plan.toolchain,
            baseline: BaselineRecord(
                passed: true,
                testSummary: TestOutcomeSummary(
                    total: 1, passed: 1, failed: 0, failingTests: [], durationSeconds: 0.1
                ),
                durationSeconds: 0.5,
                buildProductHash: ContentHash.of("baseline"),
                buildCommand: nil, testCommand: nil
            ),
            ledger: makeLedger(results),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger(results), baselinePassed: true)
        )
    }
}

/// The pipeline operator Swift doesn't have, but reads cleanly in tests that
/// chain "render this, then decode that".
infix operator |>: AdditionPrecedence
func |> <A, B>(value: A, transform: (A) throws -> B) rethrows -> B { try transform(value) }

// MARK: - Minimal JSON Schema (draft-07) structural validator

/// Checks a parsed JSON document against a parsed JSON Schema document,
/// supporting exactly the subset the real, vendored `Schema/stryker-v1.7.json`
/// needs: `type`, `required`, `properties`, `items`, `enum`, `pattern`,
/// `minimum`/`maximum`, `$ref` (resolved only within the same document's
/// `definitions`), and a *schema-valued* `additionalProperties` (used by the
/// real schema's `files`/`testFiles`, each keyed by an arbitrary path rather
/// than a fixed property list — every value under such a key must satisfy
/// that schema, the draft-07 meaning of "additionalProperties as a schema").
///
/// Deliberately not a general JSON Schema engine — no `oneOf`/`anyOf`/`not`,
/// no `uniqueItems`, no `format`, no boolean-`false` `additionalProperties`
/// enforcement (unneeded here: the real schema never sets it to `false`).
/// This follows the same "narrow, honest, real requirements only" precedent
/// as `ConfigurationSchemaParityTests.unknownPropertyPaths`, which validates
/// this repo's *own* `Schema/mutantkit-v1.json` the same way — the whole
/// difference here is which side of the wire the checked-in schema is on.
///
/// Every requirement enforced is read from the schema document at run time,
/// not hand-copied into Swift — so re-vendoring a newer `stryker-v1.x.json`
/// changes what this validates without editing this type.
struct StrykerSchemaValidator {
    private let root: [String: Any]

    init(schemaDocument: [String: Any]) {
        root = schemaDocument
    }

    /// Violations as human-readable `"path: message"` strings; empty means
    /// the document conforms to every constraint this validator understands.
    func validate(_ document: [String: Any]) -> [String] {
        validate(document as Any, against: root, path: "$")
    }

    private func resolved(_ schema: [String: Any]) -> [String: Any] {
        guard let ref = schema["$ref"] as? String, ref.hasPrefix("#/") else { return schema }
        var current: Any = root
        for component in ref.dropFirst(2).split(separator: "/") {
            guard let dictionary = current as? [String: Any], let next = dictionary[String(component)] else { return schema }
            current = next
        }
        return (current as? [String: Any]) ?? schema
    }

    private func validate(_ value: Any, against rawSchema: [String: Any], path: String) -> [String] {
        let schema = resolved(rawSchema)

        if let expectedType = schema["type"] as? String, !typeMatches(value, expectedType) {
            return ["\(path): expected type '\(expectedType)', found \(describe(value))"]
        }

        return scalarConstraintErrors(value, schema, path)
            + objectConstraintErrors(value, schema, path)
            + arrayConstraintErrors(value, schema, path)
    }

    /// `enum`, `pattern`, `minimum`, `maximum` — every constraint this
    /// validator checks against a scalar (string/number) value.
    private func scalarConstraintErrors(_ value: Any, _ schema: [String: Any], _ path: String) -> [String] {
        var errors: [String] = []

        if let allowed = schema["enum"] as? [String], let string = value as? String, !allowed.contains(string) {
            errors.append("\(path): '\(string)' is not one of the schema's allowed values \(allowed)")
        }
        if let pattern = schema["pattern"] as? String, let string = value as? String,
           string.range(of: pattern, options: .regularExpression) == nil {
            errors.append("\(path): '\(string)' does not match required pattern '\(pattern)'")
        }
        if let minimum = schema["minimum"] as? Int, let number = value as? Int, number < minimum {
            errors.append("\(path): \(number) is below the schema's minimum \(minimum)")
        }
        if let maximum = schema["maximum"] as? Int, let number = value as? Int, number > maximum {
            errors.append("\(path): \(number) is above the schema's maximum \(maximum)")
        }
        return errors
    }

    /// `required` plus recursion into either a fixed `properties` list or a
    /// schema-valued `additionalProperties` (never both — see this type's
    /// doc comment). A no-op when `value` isn't an object.
    private func objectConstraintErrors(_ value: Any, _ schema: [String: Any], _ path: String) -> [String] {
        guard let object = value as? [String: Any] else { return [] }
        var errors: [String] = []

        let required = schema["required"] as? [String] ?? []
        for key in required where object[key] == nil {
            errors.append("\(path): missing required key '\(key)'")
        }

        if let properties = schema["properties"] as? [String: Any] {
            for (key, subschema) in properties {
                guard let member = object[key], let subschemaObject = subschema as? [String: Any] else { continue }
                errors += validate(member, against: subschemaObject, path: "\(path).\(key)")
            }
        } else if let additionalSchema = schema["additionalProperties"] as? [String: Any] {
            // No fixed `properties` list: every key present is validated
            // against the shared schema (`files`/`testFiles`'s shape).
            for (key, member) in object {
                errors += validate(member, against: additionalSchema, path: "\(path).\(key)")
            }
        }
        return errors
    }

    /// `items`, recursively, against every element. A no-op when `value`
    /// isn't an array.
    private func arrayConstraintErrors(_ value: Any, _ schema: [String: Any], _ path: String) -> [String] {
        guard let array = value as? [Any], let itemSchema = schema["items"] as? [String: Any] else { return [] }
        var errors: [String] = []
        for (index, item) in array.enumerated() {
            errors += validate(item, against: itemSchema, path: "\(path)[\(index)]")
        }
        return errors
    }

    private func typeMatches(_ value: Any, _ expected: String) -> Bool {
        switch expected {
        case "object": value is [String: Any]
        case "array": value is [Any]
        case "string": value is String
        case "integer": value is Int
        case "number": value is Int || value is Double
        case "boolean": value is Bool
        default: true
        }
    }

    private func describe(_ value: Any) -> String {
        switch value {
        case is [String: Any]: "object"
        case is [Any]: "array"
        case is String: "string"
        case is Int, is Double: "number"
        case is Bool: "boolean"
        default: "\(type(of: value))"
        }
    }
}
