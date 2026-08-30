import Foundation
import MutationExecution

/// Parses the JSON Lines event stream `swiftpm-testing-helper --event-stream-
/// output-path` writes for a `--testing-library swift-testing` run — Swift
/// Testing's own `@_spi(ForToolsIntegrationOnly)` ABI
/// (`ABI.Record`/`ABI.EncodedEvent`, documented in
/// `swift-testing`'s `Documentation/ABI/EventStreamHandling.md`).
///
/// Every shape below is confirmed empirically (real toolchain,
/// `swiftpm-testing-helper` invoked directly against a built `.xctest`
/// bundle, for a plain test, a failing test, a 3-case parameterized test,
/// and a `.disabled` test) — not reconstructed from documentation or
/// inferred. Each line is one JSON object,
/// `{"kind": "test" | "event", "payload": {...}, "version": Int}`.
///
/// A `"test"` record declares one suite or function
/// (`payload.kind`/`payload.id`/`payload.isParameterized`) — a
/// *parameterized* function still gets exactly **one** declaration record
/// (`isParameterized: true`, plus a `_testCases` array this parser does not
/// need), never one per case. A *suite*'s own id (e.g.
/// `"WidgetsTests.WidgetsTests"`) also gets `testStarted`/`testEnded` events
/// around its member tests'; those container events are not a leaf test's
/// evidence and must not be mistaken for malformed evidence just because
/// they don't parse as one.
///
/// An `"event"` record's `payload.kind` is one of: `runStarted`/`runEnded`
/// (no `testID`); `testStarted`/`testEnded`/`testSkipped`/`testCancelled`
/// (function-level, `testID` == the function's own declared id, exactly one
/// `testStarted`/`testEnded` pair even for a parameterized function — its
/// own `testEnded` message already aggregates every case, e.g. `"Test
/// parameterized(_:) with 3 test cases passed"`); `testCaseStarted`/
/// `testCaseEnded`/`testCaseCancelled` (case-level, same function `testID`,
/// a `_testCase` payload this parser does not need — case-level selection
/// is out of scope, see the plan; `testCaseCancelled` is the one case-level
/// signal this parser still surfaces, folded into its parent function's
/// `cancelledTests`); `issueRecorded` (failure detail this parser does not
/// otherwise need, `testID` present when tied to a specific test).
///
/// Every event kind this parser recognizes carries a `messages` array —
/// confirmed present even when empty (`testCaseEnded`'s own `messages` is
/// `[]`) — a well-typed, required field, not an optional one this parser
/// can treat as "no failure" when it is missing or malformed; each
/// message's own `symbol`/`text` are required `String`s too. A leaf test's
/// `testID` on any function- or case-scoped event must resolve to a test
/// this stream actually declared — an event about an undeclared test is
/// unaccountable evidence, not evidence about a real test, and fails the
/// whole stream closed rather than silently going uncounted.
///
/// `testEnded`'s own pass/fail authority comes from its `messages[].symbol`
/// set: exactly one of a recognized fail symbol (`"fail"`) or a recognized
/// pass symbol (`"pass"`, `"passWithKnownIssue"`) must be present — neither
/// (only informational messages) or both (contradictory) is unsupported
/// evidence, never a presumed pass or fail.
///
/// The per-record `"version"` field was observed to read `0` regardless of
/// the `--event-stream-version` CLI flag passed to the helper (tried 0, 2, 3,
/// 4, 5) — that flag is not a promise about this field's value, so this
/// parser validates the field it actually reads, not the flag it asked for.
enum SwiftTestingEventStreamParser {
    /// Record-level `"version"` values this parser has been verified
    /// against. Anything else is unsupported evidence, not a guess at a
    /// compatible superset — a schema this parser has never seen could mean
    /// anything, including a field rename that would make silently reading a
    /// wrong field worse than refusing to.
    static let supportedRecordVersions: Set<Int> = [0]

    /// Event kinds this parser understands the shape of and validates
    /// strictly (required `testID` where noted, required `messages`). Any
    /// other `payload.kind` is treated as a schema extension this parser
    /// does not know about yet and is safely ignored, per Swift Testing's
    /// own documented forward-compatibility stance for unknown record/event
    /// kinds -- the line between "ignore, unknown" and "validate strictly,
    /// known but malformed" is drawn here, once, rather than per call site.
    private static let functionScopedEventKinds: Set<String> = ["testStarted", "testEnded", "testSkipped", "testCancelled"]
    private static let caseScopedEventKinds: Set<String> = ["testCaseStarted", "testCaseEnded", "testCaseCancelled"]

    /// One test function's evidence, keyed by the `TestIdentifier` derived
    /// from its event-stream `testID` (see `testIdentifier(fromEventStreamID:)`).
    /// Case-level events (parameterized tests) are recognized but folded
    /// away entirely -- the function-level `testStarted`/`testEnded` pair is
    /// this parser's only unit of evidence, matching the plan's explicit
    /// scope limit (no case-level selection).
    struct RunEvidence: Sendable, Equatable {
        var runStarted = false
        var runEnded = false
        /// Every function-level test this stream declared (`payload.kind ==
        /// "function"`), regardless of whether it ever started or ended —
        /// the set a caller checks "was every discovered test accounted
        /// for" against, and the set every other test-scoped event's own
        /// `testID` is required to resolve into: an event about a test this
        /// stream never declared is unaccountable evidence, not evidence
        /// about a real test.
        var declaredTests: Set<TestIdentifier> = []
        var startedTests: Set<TestIdentifier> = []
        var endedTests: Set<TestIdentifier> = []
        /// A `testEnded` whose own `messages` carried a `"pass"` or
        /// `"passWithKnownIssue"` symbol and no `"fail"` symbol —
        /// positive evidence, not merely "no fail symbol seen". A
        /// `testEnded` with neither a recognized pass symbol nor `"fail"`
        /// (only informational messages, say) is unsupported evidence, not
        /// a presumed pass — "unknown evidence is not a verdict" applies to
        /// success exactly as much as to failure. A parameterized
        /// function's single `testEnded` already aggregates every case's
        /// own outcome, confirmed live.
        var passedTests: Set<TestIdentifier> = []
        /// A `testEnded` whose own `messages` carried a `"fail"` symbol.
        /// Swift Testing's own ABI reports pass/fail this way (a structured
        /// field on a well-typed record, not console-text scraping).
        var failedTests: Set<TestIdentifier> = []
        /// A `testSkipped` event for this test — it never gets `testStarted`/
        /// `testEnded` at all (confirmed live for a `.disabled` test), so
        /// `startedTests`/`endedTests` already exclude it; tracked
        /// separately so a caller can both report *why* clearly and require
        /// this set be empty as part of its own trust check.
        var skippedTests: Set<TestIdentifier> = []
        /// A `testCancelled` (function-scoped) or `testCaseCancelled`
        /// (case-scoped, folded to its parent function's identifier) event
        /// for this test. Not empirically captured (no reliable way to
        /// trigger one in a short-lived probe process), modeled by
        /// structural analogy to every other scoped event this parser has
        /// directly observed (`testID` + required, strictly-typed
        /// `messages`) rather than guessed at from nothing.
        var cancelledTests: Set<TestIdentifier> = []
    }

    enum ParseResult: Sendable, Equatable {
        case parsed(RunEvidence)
        /// Malformed JSON, an unrecognized top-level shape, an unsupported
        /// `"version"`, a known event/test record with a malformed payload,
        /// or a `testID` this parser cannot confidently map back to a
        /// `TestIdentifier` — all evidence this parser refuses to guess
        /// past. A caller must treat this exactly like "the fast path found
        /// nothing usable", never as "zero tests ran".
        case unsupported(reason: String)
    }

    /// Internal-only signal for the small `throws`-based helpers below; never
    /// escapes this file. `parse(_:)` catches it once and converts it to
    /// `ParseResult.unsupported`.
    private struct UnsupportedEvidence: Error {
        let reason: String
    }

    static func parse(contentsOf url: URL) -> ParseResult {
        guard let data = try? Data(contentsOf: url) else {
            return .unsupported(reason: "could not read event stream file at \(url.path)")
        }
        return parse(data)
    }

    /// Two passes over the stream, deliberately: pass 1 (`declarations(in:)`)
    /// builds the full set of declared suite ids and function
    /// `TestIdentifier`s *before* pass 2 (`events(in:declaredSuiteIDs:)`)
    /// interprets a single event, so this parser never depends on
    /// declarations arriving before the events that reference them — true
    /// in every real capture seen so far, but not a contract this parser is
    /// willing to assume.
    static func parse(_ data: Data) -> ParseResult {
        do {
            let records = try decodeRecords(from: data)
            let declarations = try Self.declarations(in: records)
            let evidence = try events(in: records, declaredSuiteIDs: declarations.suiteIDs, declaredTests: declarations.tests)
            return .parsed(evidence)
        } catch let error as UnsupportedEvidence {
            return .unsupported(reason: error.reason)
        } catch {
            return .unsupported(reason: "unexpected error decoding the event stream: \(error)")
        }
    }

    private static func decodeRecords(from data: Data) throws -> [[String: Any]] {
        let text = String(decoding: data, as: UTF8.self)
        var records: [[String: Any]] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(rawLine).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                throw UnsupportedEvidence(reason: "a line in the event stream was not a parseable JSON object: \(rawLine.prefix(200))")
            }
            guard let version = record["version"] as? Int, supportedRecordVersions.contains(version) else {
                throw UnsupportedEvidence(reason: "unrecognized or missing event-stream record version: \(record["version"] ?? "nil")")
            }
            records.append(record)
        }
        return records
    }

    private static func declarations(
        in records: [[String: Any]]
    ) throws -> (suiteIDs: Set<String>, tests: Set<TestIdentifier>) {
        var suiteIDs: Set<String> = []
        var tests: Set<TestIdentifier> = []

        for record in records where record["kind"] as? String == "test" {
            // A "test" declaration record's payload is always required —
            // this is a known top-level record kind, not a schema extension
            // this parser is free to skip past.
            guard let payload = record["payload"] as? [String: Any] else {
                throw UnsupportedEvidence(reason: "a test-declaration record had a missing or malformed payload")
            }
            guard let testKind = payload["kind"] as? String, let rawID = payload["id"] as? String else {
                throw UnsupportedEvidence(reason: "a test-declaration record was missing its own kind/id")
            }
            switch testKind {
            case "suite":
                suiteIDs.insert(rawID)
            case "function":
                // One declaration per function regardless of parameterization
                // -- confirmed live: a 3-case @Test(arguments:) function
                // still emits exactly one "test"/"function" record
                // (isParameterized: true, plus a _testCases array this
                // parser does not need), never one per case.
                guard let identifier = testIdentifier(fromEventStreamID: rawID) else {
                    throw UnsupportedEvidence(reason: "could not derive a TestIdentifier from event-stream id \(rawID)")
                }
                tests.insert(identifier)
            default:
                throw UnsupportedEvidence(reason: "unrecognized test-declaration kind: \(testKind)")
            }
        }
        return (suiteIDs, tests)
    }

    private static func events(
        in records: [[String: Any]],
        declaredSuiteIDs: Set<String>,
        declaredTests: Set<TestIdentifier>
    ) throws -> RunEvidence {
        var evidence = RunEvidence()
        evidence.declaredTests = declaredTests

        for record in records where record["kind"] as? String == "event" {
            // A known top-level record kind -- its payload is always
            // required, same as a "test" declaration's.
            guard let payload = record["payload"] as? [String: Any] else {
                throw UnsupportedEvidence(reason: "an event record had a missing or malformed payload")
            }
            guard let eventKind = payload["kind"] as? String else {
                throw UnsupportedEvidence(reason: "an event record was missing its own kind")
            }

            switch eventKind {
            case "runStarted", "runEnded":
                _ = try requiredMessages(in: payload, eventKind: eventKind)
                if eventKind == "runStarted" { evidence.runStarted = true } else { evidence.runEnded = true }

            case _ where functionScopedEventKinds.contains(eventKind):
                try recordFunctionScopedEvent(
                    kind: eventKind, payload: payload, declaredSuiteIDs: declaredSuiteIDs,
                    declaredTests: declaredTests, evidence: &evidence
                )

            case _ where caseScopedEventKinds.contains(eventKind):
                try recordCaseScopedEvent(kind: eventKind, payload: payload, declaredTests: declaredTests, evidence: &evidence)

            case "issueRecorded":
                // Failure detail this parser does not otherwise need (the
                // owning test's own testEnded message symbol is authority
                // on pass/fail) -- validated for shape only, so a malformed
                // one still fails the whole stream closed rather than
                // silently passing through as "no issue".
                _ = try requiredMessages(in: payload, eventKind: eventKind)

            default:
                // A genuinely unrecognized event kind -- a schema extension
                // this parser has never seen, safely ignored per Swift
                // Testing's own forward-compatibility stance. Anything this
                // parser *has* seen is listed above and validated strictly.
                continue
            }
        }

        return evidence
    }

    /// `runStarted`/`runEnded`/`testSkipped`/`testCancelled` (and the suite
    /// container's own `testStarted`/`testEnded`) — a leaf test's `testID`
    /// must resolve to a test this stream actually declared, or the event
    /// is unaccountable evidence, not evidence about a real test: without
    /// this check, an event naming an *undeclared* test would still parse
    /// (its `testID` syntactically resolves to a `TestIdentifier`) and
    /// silently vanish from every evidence set, exactly the same "count
    /// only what confirms, ignore what doesn't" gap this parser exists to
    /// close.
    private static func recordFunctionScopedEvent(
        kind: String,
        payload: [String: Any],
        declaredSuiteIDs: Set<String>,
        declaredTests: Set<TestIdentifier>,
        evidence: inout RunEvidence
    ) throws {
        let messages = try requiredMessages(in: payload, eventKind: kind)
        guard let rawID = payload["testID"] as? String else {
            throw UnsupportedEvidence(reason: "a \(kind) event was missing its own testID")
        }
        // A suite's own container start/end, never a leaf test's evidence —
        // legitimate, not malformed. Suites only ever emit testStarted/
        // testEnded, never testSkipped/testCancelled, but the check is kept
        // uniform across all four kinds rather than special-cased.
        if declaredSuiteIDs.contains(rawID) { return }
        guard let identifier = testIdentifier(fromEventStreamID: rawID) else {
            throw UnsupportedEvidence(reason: "a \(kind) event's testID \(rawID) did not resolve to a declared or suite id")
        }
        guard declaredTests.contains(identifier) else {
            throw UnsupportedEvidence(reason: "a \(kind) event named \(identifier), which this stream never declared")
        }

        switch kind {
        case "testStarted":
            evidence.startedTests.insert(identifier)
        case "testEnded":
            evidence.endedTests.insert(identifier)
            try recordTerminalOutcome(for: identifier, messages: messages, evidence: &evidence)
        case "testSkipped":
            evidence.skippedTests.insert(identifier)
        case "testCancelled":
            evidence.cancelledTests.insert(identifier)
        default:
            break
        }
    }

    /// `testCaseStarted`/`testCaseEnded`/`testCaseCancelled` — case-level
    /// lifecycle, same function `testID` as its parent. `testCaseStarted`/
    /// `testCaseEnded` are validated for shape (a malformed one still fails
    /// the whole stream closed) and otherwise ignored: the function-level
    /// `testStarted`/`testEnded` pair already covers this test's own
    /// start/end/pass-fail, and this parser does not do case-level
    /// selection. `testCaseCancelled` is different: a single cancelled
    /// case inside an otherwise-clean-looking parameterized run must still
    /// disqualify the whole function, so it is folded into
    /// `cancelledTests` under its parent's identifier, not discarded.
    private static func recordCaseScopedEvent(
        kind: String,
        payload: [String: Any],
        declaredTests: Set<TestIdentifier>,
        evidence: inout RunEvidence
    ) throws {
        _ = try requiredMessages(in: payload, eventKind: kind)
        guard let rawID = payload["testID"] as? String else {
            throw UnsupportedEvidence(reason: "a \(kind) event was missing its own testID")
        }
        guard let identifier = testIdentifier(fromEventStreamID: rawID) else {
            throw UnsupportedEvidence(reason: "a \(kind) event's testID \(rawID) did not resolve to a declared test")
        }
        guard declaredTests.contains(identifier) else {
            throw UnsupportedEvidence(reason: "a \(kind) event named \(identifier), which this stream never declared")
        }
        if kind == "testCaseCancelled" {
            evidence.cancelledTests.insert(identifier)
        }
    }

    /// A `testEnded` message symbol carrying a recognized pass variant.
    /// `"passWithKnownIssue"` is per Swift Testing's own documented symbol
    /// enumeration (not independently captured live — no reliable way to
    /// force a known-issue pass in a short probe — but named explicitly in
    /// the schema this parser otherwise verified live).
    private static let passSymbols: Set<String> = ["pass", "passWithKnownIssue"]

    /// Determines `testEnded`'s own pass/fail authority from its
    /// `messages[].symbol` set. Exactly one of "a recognized fail symbol"
    /// or "a recognized pass symbol" must be present — neither (only
    /// informational messages, say) or both (contradictory) is unsupported
    /// evidence, never guessed at as a default verdict. "Unknown evidence
    /// is not a verdict" applies to a presumed pass exactly as much as to a
    /// presumed fail.
    private static func recordTerminalOutcome(
        for identifier: TestIdentifier, messages: [[String: Any]], evidence: inout RunEvidence
    ) throws {
        // compactMap, not a force-cast: requiredMessages already validated
        // every message's own "symbol" is a String before this is ever
        // called, so nothing here is actually expected to drop.
        let symbols = Set(messages.compactMap { $0["symbol"] as? String })
        let hasFail = symbols.contains("fail")
        let hasPass = !symbols.isDisjoint(with: passSymbols)
        switch (hasFail, hasPass) {
        case (true, false):
            evidence.failedTests.insert(identifier)
        case (false, true):
            evidence.passedTests.insert(identifier)
        default:
            throw UnsupportedEvidence(
                reason: "\(identifier)'s testEnded reported no single recognized terminal outcome (symbols: \(symbols))"
            )
        }
    }

    /// `payload["messages"]` as `[[String: Any]]` (an array of `{"symbol":
    /// String, "text": String}` objects) — confirmed present, though
    /// sometimes empty (`testCaseEnded`'s own `messages` is `[]`), on every
    /// event kind this parser recognizes. Missing or wrong-typed — the
    /// array itself, or any individual message's `symbol`/`text` — is
    /// malformed evidence for a known event kind, never silently "no
    /// failure reported": this field is exactly what `testEnded`'s own
    /// pass/fail signal comes from, so trusting its *absence* the same way
    /// as its *presence-but-empty* would be the same partial-evidence gap
    /// #26/#28/#29 closed elsewhere, reopened here.
    @discardableResult
    private static func requiredMessages(in payload: [String: Any], eventKind: String) throws -> [[String: Any]] {
        guard let messages = payload["messages"] as? [[String: Any]] else {
            throw UnsupportedEvidence(reason: "a \(eventKind) event was missing its own messages array")
        }
        for message in messages {
            guard message["symbol"] is String, message["text"] is String else {
                throw UnsupportedEvidence(reason: "a \(eventKind) event had a message with a missing/wrong-typed symbol or text")
            }
        }
        return messages
    }

    /// Strips an event-stream test id's trailing `/<file>.swift:<line>:<column>`
    /// source-location suffix and maps what remains onto the same
    /// `<target>.<qualifiedName>` shape `SwiftPackageMacOSAdapter
    /// .parseTestIdentifiers` already derives from `swift test list` —
    /// confirmed empirically to be the *same string* for the same test
    /// (`"PricingTests.PricingTests/bulkDiscountRoughly()"` either way).
    /// Reusing that shape, rather than inventing a parallel one, is what
    /// lets this fast path's evidence compare directly against the serial
    /// oracle's own `TestIdentifier` values in F1-D.
    ///
    /// A suite id (`"PricingTests.PricingTests"`, no `/`) is not a leaf
    /// test and correctly fails this — callers check `declaredSuiteIDs`
    /// first, before ever reaching this function, for exactly that shape.
    static func testIdentifier(fromEventStreamID rawID: String) -> TestIdentifier? {
        let stripped = strippingSourceLocationSuffix(rawID)
        guard let dotIndex = stripped.firstIndex(of: ".") else { return nil }
        let target = String(stripped[stripped.startIndex ..< dotIndex])
        let qualifiedName = String(stripped[stripped.index(after: dotIndex)...])
        guard !target.isEmpty, !qualifiedName.isEmpty, qualifiedName.contains("/") else { return nil }
        return TestIdentifier(target: target, qualifiedName: qualifiedName)
    }

    /// `"Suite/method()/File.swift:12:6"` -> `"Suite/method()"`. Matches
    /// only a trailing component that is itself
    /// `<name>.swift:<digits>:<digits>` — anything else is left alone
    /// rather than risk truncating a real identifier that happens to
    /// contain a slash-separated, digit-ending component of its own.
    private static func strippingSourceLocationSuffix(_ id: String) -> String {
        guard let lastSlash = id.lastIndex(of: "/") else { return id }
        let candidate = id[id.index(after: lastSlash)...]
        let parts = candidate.split(separator: ":")
        guard parts.count == 3,
              parts[0].hasSuffix(".swift"),
              Int(parts[1]) != nil,
              Int(parts[2]) != nil
        else { return id }
        return String(id[id.startIndex..<lastSlash])
    }
}
