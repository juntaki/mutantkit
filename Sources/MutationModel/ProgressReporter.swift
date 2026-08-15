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
    private let startedAt: Date
    private var completed = 0

    public init(total: Int, startedAt: Date = Date()) {
        self.total = total
        self.startedAt = startedAt
    }

    public func recordCompletion() {
        completed += 1
        guard total > 0 else { return }

        let elapsed = Date().timeIntervalSince(startedAt)
        let percent = Int((Double(completed) / Double(total) * 100).rounded())
        // ETA extrapolates linearly from the mean per-mutant time so far —
        // a rough estimate, not a promise; the point is "roughly how much
        // longer", not a precise countdown.
        let etaText = completed > 0
            ? Self.formatDuration(elapsed / Double(completed) * Double(total - completed))
            : "?"

        let line = "[\(completed)/\(total)] \(percent)% — elapsed \(Self.formatDuration(elapsed)), ETA ~\(etaText)\n"
        FileHandle.standardError.write(Data(line.utf8))
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
