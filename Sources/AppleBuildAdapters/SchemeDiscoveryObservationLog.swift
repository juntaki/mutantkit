import Foundation
import MutationExecution

/// Records how long each `xcodebuild -list -json` attempt actually took, and
/// how it ended, when `MUTANTKIT_SCHEME_DISCOVERY_LOG` names a file to append
/// to. Off unless that variable is set, so a normal run writes nothing and
/// behaves identically.
///
/// This exists to answer a question this codebase currently cannot:
/// `XcodeBuildAdapter.schemeListTimeoutSeconds` is 120, and three CI failures
/// have now been observed at 120.056s, 120.119s and 120.164s — all three
/// killed at the deadline with empty output. Those establish that 120 seconds
/// touches the edge of the current distribution. They do not say what a
/// correct budget is, because nothing records the *successful* attempts'
/// durations, and a budget chosen from failures alone is a guess dressed up
/// as a measurement. Widening the timeout first would make "hid a flake" and
/// "added headroom" indistinguishable afterwards, so the measurement comes
/// first and the budget is left alone until there is a distribution to read.
///
/// Deliberately an append-only log of individual attempts rather than an
/// aggregate: the interesting shape is the tail, and a mean would hide it.
///
/// Never fails a run. Every error — an unwritable path, a full disk, a
/// removed directory — is dropped silently, because an observation that can
/// break the thing it observes is worse than no observation.
enum SchemeDiscoveryObservationLog {
    /// Absolute path of the file to append one JSON object per attempt to.
    /// Unset (the default) disables the log entirely.
    static let environmentVariable = "MUTANTKIT_SCHEME_DISCOVERY_LOG"

    /// How one attempt ended, in the vocabulary the diagnosis uses — so a
    /// row in this log and the message a user saw can be matched up without
    /// re-deriving either.
    enum Outcome: String {
        /// `xcodebuild` answered with at least one scheme.
        case schemesFound = "schemes-found"
        /// `xcodebuild` was asked, answered, and the answer was none. The
        /// only outcome that justifies telling a user their schemes are
        /// misconfigured.
        case answeredNone = "answered-none"
        /// The process could not be started at all.
        case notStarted = "not-started"
        /// The process ran but did not succeed — killed at the budget,
        /// killed by another signal, or a non-zero exit. Which of those it
        /// was is recorded in the row's own fields, not in this label.
        case didNotSucceed = "did-not-succeed"
        /// Exited cleanly and read as empty, but the supervisor never
        /// confirmed the output was fully drained, so the emptiness is not
        /// evidence.
        case outputIncomplete = "output-incomplete"
        /// Empty, complete, and another attempt is still available.
        case emptyRetrying = "empty-retrying"
    }

    /// `path` is `XcodeBuildAdapter.schemeDiscoveryLogPath`, which resolves
    /// the environment variable once per adapter. `nil` or empty disables the
    /// row, which is the normal case.
    static func record(
        attempt: Int,
        outcome: Outcome,
        result: ProcessResult?,
        schemeCount: Int,
        budgetSeconds: Double,
        path: String?,
        now: Date = Date()
    ) {
        guard let path, !path.isEmpty else { return }
        append(line(
            attempt: attempt,
            outcome: outcome,
            result: result,
            schemeCount: schemeCount,
            budgetSeconds: budgetSeconds,
            now: now
        ), to: path)
    }

    /// One JSON object, newline-terminated. Built by hand rather than through
    /// `JSONEncoder` so the key order is stable and a human reading the raw
    /// file sees the timing first, which is the reason the file exists.
    static func line(
        attempt: Int,
        outcome: Outcome,
        result: ProcessResult?,
        schemeCount: Int,
        budgetSeconds: Double,
        now: Date = Date()
    ) -> String {
        var fields: [String] = [
            "\"time\":\"\(ISO8601DateFormatter().string(from: now))\"",
            "\"attempt\":\(attempt)",
            "\"outcome\":\"\(outcome.rawValue)\"",
            "\"budgetSeconds\":\(number(budgetSeconds))"
        ]
        if let result {
            fields.append("\"durationSeconds\":\(number(result.durationSeconds))")
            fields.append("\"exitCode\":\(result.exitCode)")
            fields.append("\"timedOut\":\(result.timedOut)")
            fields.append("\"outputComplete\":\(result.outputComplete)")
            if let signal = result.terminatingSignal {
                fields.append("\"terminatingSignal\":\(signal)")
            }
        }
        fields.append("\"schemeCount\":\(schemeCount)")
        return "{\(fields.joined(separator: ","))}\n"
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    /// Appends with `O_APPEND` rather than seek-then-write: acceptance runs
    /// have several workers discovering schemes at once, in separate
    /// processes, into the same file. A seek-then-write pair from two of them
    /// interleaves and loses a row; a single `write` to an `O_APPEND`
    /// descriptor does not, for a line this short.
    private static func append(_ text: String, to path: String) {
        guard let bytes = text.data(using: .utf8) else { return }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = bytes.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
    }
}
