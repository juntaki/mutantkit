import Foundation
import MutationExecution

/// Parses the JSON Lines event stream `swiftpm-testing-helper --event-stream-
/// output-path` writes for a `--testing-library swift-testing` run — Swift
/// Testing's own `@_spi(ForToolsIntegrationOnly)` ABI
/// (`ABI.Record`/`ABI.EncodedEvent`, documented in
/// `swift-testing`'s `Documentation/ABI/EventStreamHandling.md`).
///
/// Confirmed empirically (real toolchain, `swiftpm-testing-helper` invoked
/// directly against a built `.xctest` bundle), not reconstructed from the
/// documentation alone: each line is one JSON object,
/// `{"kind": "test" | "event", "payload": {...}, "version": Int}`. A `"test"`
/// record declares one suite or function (`payload.kind`, `payload.id`,
/// `payload.isParameterized`) — a *suite*'s own id (e.g.
/// `"PricingTests.PricingTests"`) also gets `testStarted`/`testEnded` events
/// around its member tests', confirmed live; those container events are not
/// a leaf test's evidence and must not be mistaken for malformed evidence
/// just because they don't parse as one. An `"event"` record reports
/// `runStarted`, `testStarted`/`testEnded` (with `payload.testID`), or
/// `runEnded`.
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

    /// One test function's start/end evidence, keyed by the `TestIdentifier`
    /// derived from its event-stream `testID` (see `testIdentifier(fromEventStreamID:)`).
    /// Parameterized test cases (multiple `testStarted`/`testEnded` pairs
    /// sharing one function's `TestIdentifier`, one per case) are folded into
    /// this same identifier — this parser does not do case-level selection,
    /// matching the plan's explicit scope limit.
    struct RunEvidence: Sendable, Equatable {
        var runStarted = false
        var runEnded = false
        /// Every function-level test this stream declared (`payload.kind ==
        /// "function"`), regardless of whether it ever started or ended —
        /// the set a caller checks "was every discovered test accounted
        /// for" against.
        var declaredTests: Set<TestIdentifier> = []
        var startedTests: Set<TestIdentifier> = []
        /// Test identifiers whose *every* declared case reported `testEnded`
        /// — a parameterized test with three cases needs all three, not one,
        /// before its union identifier counts as ended.
        var endedTests: Set<TestIdentifier> = []
        /// Test identifiers with at least one case whose own `testEnded`
        /// event carried a `messages[].symbol == "fail"` entry — Swift
        /// Testing's own ABI reports pass/fail this way (confirmed live: a
        /// deliberately-failing `@Test` still emits `testStarted`/
        /// `testEnded` like any other, with `"symbol":"fail"` on the ending
        /// message, plus a separate `issueRecorded` event for the failure
        /// detail this parser does not otherwise need). A structured field
        /// on a well-typed record, not console-text scraping. Any failed
        /// case marks the whole union identifier failed, matching the
        /// serial oracle's own "an unprovable isolated run invalidates the
        /// whole test" contract.
        var failedTests: Set<TestIdentifier> = []
    }

    enum ParseResult: Sendable, Equatable {
        case parsed(RunEvidence)
        /// Malformed JSON, an unrecognized top-level shape, an unsupported
        /// `"version"`, or a `testID` this parser cannot confidently map back
        /// to a `TestIdentifier` — all evidence this parser refuses to guess
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
    /// `TestIdentifier`s (with their case counts) *before* pass 2
    /// (`events(in:declaredSuiteIDs:declaredCaseCounts:)`) interprets a
    /// single event, so this parser never depends on declarations arriving
    /// before the events that reference them — true in every real capture
    /// seen so far, but not a contract this parser is willing to assume.
    static func parse(_ data: Data) -> ParseResult {
        do {
            let records = try decodeRecords(from: data)
            let declarations = try Self.declarations(in: records)
            let evidence = try events(in: records, declaredSuiteIDs: declarations.suiteIDs, declaredCaseCounts: declarations.caseCounts)
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
    ) throws -> (suiteIDs: Set<String>, caseCounts: [TestIdentifier: Int]) {
        var suiteIDs: Set<String> = []
        var caseCounts: [TestIdentifier: Int] = [:]

        for record in records where record["kind"] as? String == "test" {
            guard let payload = record["payload"] as? [String: Any] else { continue }
            guard let testKind = payload["kind"] as? String, let rawID = payload["id"] as? String else {
                throw UnsupportedEvidence(reason: "a test-declaration record was missing its own kind/id")
            }
            switch testKind {
            case "suite":
                suiteIDs.insert(rawID)
            case "function":
                guard let identifier = testIdentifier(fromEventStreamID: rawID) else {
                    throw UnsupportedEvidence(reason: "could not derive a TestIdentifier from event-stream id \(rawID)")
                }
                caseCounts[identifier, default: 0] += 1
            default:
                throw UnsupportedEvidence(reason: "unrecognized test-declaration kind: \(testKind)")
            }
        }
        return (suiteIDs, caseCounts)
    }

    private static func events(
        in records: [[String: Any]],
        declaredSuiteIDs: Set<String>,
        declaredCaseCounts: [TestIdentifier: Int]
    ) throws -> RunEvidence {
        var evidence = RunEvidence()
        evidence.declaredTests = Set(declaredCaseCounts.keys)
        var endedCaseCounts: [TestIdentifier: Int] = [:]

        for record in records where record["kind"] as? String == "event" {
            guard let payload = record["payload"] as? [String: Any] else { continue }
            guard let eventKind = payload["kind"] as? String else {
                throw UnsupportedEvidence(reason: "an event record was missing its own kind")
            }
            switch eventKind {
            case "runStarted":
                evidence.runStarted = true
            case "runEnded":
                evidence.runEnded = true
            case "testStarted", "testEnded":
                try recordTestEvent(
                    kind: eventKind, payload: payload, declaredSuiteIDs: declaredSuiteIDs,
                    evidence: &evidence, endedCaseCounts: &endedCaseCounts
                )
            default:
                // Other event kinds (issueRecorded, testSkipped, ...) are
                // not this parser's concern yet; not an error to see them.
                continue
            }
        }

        for (identifier, declaredCount) in declaredCaseCounts
        where (endedCaseCounts[identifier] ?? 0) >= declaredCount {
            // A non-parameterized function has exactly one implicit case, so
            // its own single testEnded already satisfies a declared count of
            // 1. A parameterized function's case-level testStarted/testEnded
            // pairs each increment endedCaseCounts under the SAME union
            // identifier (see `testIdentifier(fromEventStreamID:)`), so this
            // comparison naturally requires every case, not just one.
            evidence.endedTests.insert(identifier)
        }

        return evidence
    }

    private static func recordTestEvent(
        kind: String,
        payload: [String: Any],
        declaredSuiteIDs: Set<String>,
        evidence: inout RunEvidence,
        endedCaseCounts: inout [TestIdentifier: Int]
    ) throws {
        guard let rawID = payload["testID"] as? String else {
            throw UnsupportedEvidence(reason: "a \(kind) event was missing its own testID")
        }
        // A suite's own container start/end, never a leaf test's evidence —
        // legitimate, not malformed.
        if declaredSuiteIDs.contains(rawID) { return }
        guard let identifier = testIdentifier(fromEventStreamID: rawID) else {
            throw UnsupportedEvidence(reason: "a \(kind) event's testID \(rawID) did not resolve to a declared or suite id")
        }
        if kind == "testStarted" {
            evidence.startedTests.insert(identifier)
        } else {
            endedCaseCounts[identifier, default: 0] += 1
            if Self.hasFailSymbol(in: payload) {
                evidence.failedTests.insert(identifier)
            }
        }
    }

    /// `true` when `payload["messages"]` (an array of `{"symbol": String,
    /// "text": String}`) contains any entry whose `symbol` is `"fail"`.
    /// Missing/wrong-typed `messages` is not itself malformed — some event
    /// kinds legitimately carry none — it simply means no failure was
    /// reported by this event.
    private static func hasFailSymbol(in payload: [String: Any]) -> Bool {
        guard let messages = payload["messages"] as? [[String: Any]] else { return false }
        return messages.contains { ($0["symbol"] as? String) == "fail" }
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
    /// contain a slash-separated, digit-ending component of its own (a
    /// parameterized test's case label, for instance).
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
