import Foundation
import MutationModel

/// Turns SIGINT/SIGTERM/SIGHUP into a `RunStopRequest` for the lifetime of a
/// run, and escalates on repeats:
///
/// 1. first signal: stop starting new mutants; mutants already running finish
///    (each is bounded by the mutant timeout) and are checkpointed as usual;
/// 2. second signal: cancel the run, which terminates the in-flight child
///    process trees through `ProcessSupervisor`'s own termination path;
/// 3. third signal: exit immediately. Nothing is lost by this — every finished
///    mutant was already flushed to the checkpoint when it completed.
///
/// The decision logic lives in `handle(signalName:)` so tests drive it
/// directly instead of signalling the test process.
final class RunSignalHandler: @unchecked Sendable {
    static let handledSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private let stop: RunStopRequest
    private let onForce: @Sendable () -> Void
    private let onAbort: @Sendable () -> Void
    private let log: @Sendable (String) -> Void
    private var sources: [DispatchSourceSignal] = []
    private let queue = DispatchQueue(label: "mutantkit.run.signals")

    init(
        stop: RunStopRequest,
        onForce: @escaping @Sendable () -> Void,
        onAbort: @escaping @Sendable () -> Void = { _exit(MutantKitExit.interrupted) },
        log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        self.stop = stop
        self.onForce = onForce
        self.onAbort = onAbort
        self.log = log
    }

    static func name(of signalNumber: Int32) -> String {
        switch signalNumber {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        case SIGHUP: "SIGHUP"
        default: "signal \(signalNumber)"
        }
    }

    func start() {
        for number in Self.handledSignals {
            // The default disposition would kill the process before the
            // dispatch source ever saw the signal.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [self] in handle(signalName: Self.name(of: number)) }
            source.resume()
            sources.append(source)
        }
    }

    /// Restores the default dispositions, so a signal after the run no longer
    /// goes to a handler nobody is listening to.
    func finish() {
        for source in sources { source.cancel() }
        sources = []
        for number in Self.handledSignals { signal(number, SIG_DFL) }
    }

    func handle(signalName: String) {
        switch stop.request(signal: signalName) {
        case .running:
            break
        case .graceful:
            log("\n\(signalName): no new mutants will start; waiting for the ones in flight. Results so far are checkpointed. "
                + "Signal again to terminate them now.\n")
        case .forced:
            log("\n\(signalName): terminating in-flight work. Signal again to exit immediately.\n")
            onForce()
        case .abort:
            log("\n\(signalName): exiting immediately. Finished mutants are already in the checkpoint.\n")
            onAbort()
        }
    }
}

extension RunCommand {
    /// Runs `body` in its own task so a forced stop can cancel it, with
    /// `stop`'s signal handling installed for exactly that long. With no
    /// `stop` (strategies that do not honour one) signals keep their default
    /// behaviour.
    static func withInterruptHandling(
        stop: RunStopRequest?, body: @escaping @Sendable () async throws -> RunReport
    ) async throws -> RunReport {
        guard let stop else { return try await body() }
        let work = Task { try await body() }
        let handler = RunSignalHandler(stop: stop, onForce: { work.cancel() })
        handler.start()
        defer { handler.finish() }
        return try await work.value
    }

    /// Quotes an argument only when a shell would otherwise split or expand it.
    private static func shellQuoted(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command that continues an interrupted run: the one that was typed,
    /// minus `--no-resume` (which would throw the checkpoint away).
    static func resumeCommand(arguments: [String]) -> String {
        arguments.filter { $0 != "--no-resume" }.map(shellQuoted).joined(separator: " ")
    }

    /// What to tell the user after an interrupted run. `nil` when the run was
    /// not interrupted, or the signal arrived too late to change anything (a
    /// complete report that passed integrity is just a complete report).
    static func interruptionSummary(
        report: RunReport, stop: RunStopRequest?, checkpointURL: URL, arguments: [String]
    ) -> String? {
        guard let stop, stop.isStopRequested, report.interruption != nil || !report.baseline.passed else { return nil }
        let resumable = !checkpointURL.lastPathComponent.hasSuffix("-unfingerprinted.jsonl")
        var lines: [String] = []
        if let interruption = report.interruption {
            lines.append(
                "Interrupted (\(interruption.signal)): \(interruption.completedMutants) of \(interruption.plannedMutants) "
                    + "mutants have a result. This report is PARTIAL: it has no score and is not a trustworthy measurement."
            )
        } else {
            lines.append("Interrupted (\(stop.signalName ?? "signal")) before the baseline finished; nothing was recorded.")
        }
        if resumable {
            lines.append("Finished mutants are saved in \(checkpointURL.path).")
            lines.append("Resume with: \(resumeCommand(arguments: arguments))")
        } else {
            lines.append("This run could not fingerprint its inputs, so its results are not saved for resume.")
        }
        return lines.joined(separator: "\n")
    }
}
