import Foundation

/// Reports "N/total" progress to stderr as mutants finish. An actor, not a
/// lock — like `OperationalIssueLog`, completions come from the same
/// concurrent task group that runs `MutationRunner.finalize` for each
/// mutation, so recording a completion has to be safe to call concurrently.
///
/// A long real-project run (hundreds of mutants, each its own build/test
/// cycle) previously gave a human watching it no signal beyond silence
/// until the final report — this exists so "is it stuck or just slow" has
/// an answer without reaching for `wc -l` on the checkpoint file.
public actor ProgressReporter {
    private let total: Int
    private let label: String
    private let startedAt: Date
    private var completed = 0
    private let interactive: Bool
    private var tally = OutcomeTally()
    private var lineIsOpen = false

    /// What the finished mutants so far turned out to be, in the buckets a
    /// person watching a run cares about. `other` is everything else
    /// (no coverage, infrastructure failures...) so the parts always add up.
    struct OutcomeTally: Equatable {
        var killed = 0
        var survived = 0
        var unviable = 0
        var unstable = 0
        var notMaterialized = 0
        var other = 0

        var total: Int { killed + survived + unviable + unstable + notMaterialized + other }

        mutating func add(_ outcome: MutationOutcome) {
            switch outcome {
            case .killedByAssertion, .killedByCrash, .verifiedTimeout: killed += 1
            case .survived: survived += 1
            case .unviable: unviable += 1
            case .flaky, .timedOut: unstable += 1
            case .notMaterialized: notMaterialized += 1
            default: other += 1
            }
        }

        var description: String? {
            guard total > 0 else { return nil }
            var parts = ["killed \(killed)", "survived \(survived)"]
            if unviable > 0 { parts.append("unviable \(unviable)") }
            if unstable > 0 { parts.append("unstable \(unstable)") }
            if notMaterialized > 0 { parts.append("not materialized \(notMaterialized)") }
            if other > 0 { parts.append("other \(other)") }
            return parts.joined(separator: ", ")
        }
    }

    /// - Parameter label: what is being counted, when that is not obvious
    ///   from context. A run reports more than one kind of progress — the
    ///   per-test coverage pass counts tests, the schemata backend counts
    ///   chunks, the isolated backend counts mutants — and two unlabelled
    ///   `[12/50]` streams interleaved on one terminal cannot be told apart.
    ///
    /// - Parameter interactive: whether stderr is a terminal. A terminal gets
    ///   one line rewritten in place; anything else (CI logs, files, pipes)
    ///   gets one plain line per completion, which stays greppable.
    public init(total: Int, label: String = "", startedAt: Date = Date(), interactive: Bool = isatty(STDERR_FILENO) != 0) {
        self.total = total
        self.label = label
        self.startedAt = startedAt
        self.interactive = interactive
    }

    /// How many completions have been recorded so far.
    public var completedCount: Int { completed }

    /// - Parameter outcome: the finished mutant's outcome, when it is a
    ///   mutant (the coverage and chunk counters have none), for the
    ///   killed/survived/... breakdown.
    public func recordCompletion(outcome: MutationOutcome? = nil, now: Date = Date()) {
        completed += 1
        if let outcome { tally.add(outcome) }
        guard let line = line(now: now) else { return }
        FileHandle.standardError.write(Data(Self.rendered(line, interactive: interactive, final: completed >= total).utf8))
        lineIsOpen = interactive && completed < total
    }

    /// Ends a rewritten-in-place line so whatever prints next starts on a
    /// fresh one. A no-op for plain output and for a line already ended.
    public func finish() {
        guard lineIsOpen else { return }
        lineIsOpen = false
        FileHandle.standardError.write(Data("\n".utf8))
    }

    /// The bytes written for one `line`. Pure, for the same reason `line` is.
    static func rendered(_ line: String, interactive: Bool, final: Bool) -> String {
        guard interactive else { return line }
        let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
        return "\r\u{1B}[2K" + body + (final ? "\n" : "")
    }

    /// The line `recordCompletion` writes, or `nil` when there is nothing to
    /// report. Pulled out as a pure function — the same split
    /// `DryRunCommand.passedOutput` makes — so the format, the label and the
    /// ETA arithmetic are directly testable, rather than only observable by
    /// watching a real hours-long run's stderr.
    func line(now: Date) -> String? {
        guard total > 0 else { return nil }

        let elapsed = now.timeIntervalSince(startedAt)
        let percent = Int((Double(completed) / Double(total) * 100).rounded())
        // ETA extrapolates linearly from the mean per-unit time so far —
        // a rough estimate, not a promise; the point is "roughly how much
        // longer", not a precise countdown. It is also the only answer a
        // first run gets to "how long will this take", since the cost
        // depends on the project's own suite, which nothing can know in
        // advance of measuring it.
        let etaText = completed > 0
            ? Self.formatDuration(elapsed / Double(completed) * Double(total - completed))
            : "?"

        let prefix = label.isEmpty ? "" : "\(label) "
        let breakdown = tally.description.map { " — \($0)" } ?? ""
        return "\(prefix)[\(completed)/\(total)] \(percent)% — elapsed \(Self.formatDuration(elapsed)), ETA ~\(etaText)\(breakdown)\n"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 { return String(format: "%dh%02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm%02ds", minutes, secs) }
        return "\(secs)s"
    }
}
