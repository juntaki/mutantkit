import Foundation

/// How far an interruption request has escalated. Each further signal moves a
/// run one step along: finish what is running, then terminate it, then give up
/// waiting for any cleanup at all.
public enum RunStopPhase: Int, Comparable, Sendable {
    /// Not interrupted.
    case running
    /// Stop starting new mutants; let those already in flight finish.
    case graceful
    /// Terminate in-flight work through the normal cancellation path.
    case forced
    /// Leave immediately. Only the CLI acts on this; the engine never sees it
    /// as anything beyond `forced`.
    case abort

    public static func < (lhs: RunStopPhase, rhs: RunStopPhase) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A run's "please stop" switch. Injectable on purpose: the CLI feeds it from
/// SIGINT/SIGTERM/SIGHUP, a test feeds it by calling `request` — neither the
/// engine nor its tests ever need a real signal.
///
/// A class guarded by a lock, not an actor: the signal handler and the
/// per-mutant dispatch loop both poll it from synchronous code.
public final class RunStopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var currentPhase = RunStopPhase.running
    private var firstSignal: String?
    private var discarded: Set<MutationID> = []

    public init() {}

    public var phase: RunStopPhase {
        lock.lock()
        defer { lock.unlock() }
        return currentPhase
    }

    /// True from the first request on: no new mutant may be started.
    public var isStopRequested: Bool { phase >= .graceful }

    /// True once in-flight work is being terminated, so whatever it then
    /// reports is an artifact of the termination and not a verdict.
    public var isForced: Bool { phase >= .forced }

    /// The name of the signal that started the interruption (`"SIGINT"`...).
    public var signalName: String? {
        lock.lock()
        defer { lock.unlock() }
        return firstSignal
    }

    /// Records one more stop request and returns the phase it escalated to.
    @discardableResult
    public func request(signal: String) -> RunStopPhase {
        lock.lock()
        defer { lock.unlock() }
        if firstSignal == nil { firstSignal = signal }
        currentPhase = RunStopPhase(rawValue: min(currentPhase.rawValue + 1, RunStopPhase.abort.rawValue)) ?? .abort
        return currentPhase
    }

    /// A mutant whose evaluation was cut short by termination. Its result is
    /// not persisted and not reported: a half-finished build is not a verdict.
    public func markDiscarded(_ id: MutationID) {
        lock.lock()
        discarded.insert(id)
        lock.unlock()
    }

    public func wasDiscarded(_ id: MutationID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return discarded.contains(id)
    }
}

/// Recorded on a `RunReport` that covers only part of its plan because the run
/// was interrupted. Its presence is the whole "this is partial" statement; the
/// report's integrity record independently lists every unfinished mutant, so
/// no score is produced from it.
public struct RunInterruption: Codable, Sendable, Equatable {
    /// The signal that started the interruption.
    public let signal: String
    /// Planned mutants that have a result in this report.
    public let completedMutants: Int
    /// Planned mutants in total.
    public let plannedMutants: Int

    public init(signal: String, completedMutants: Int, plannedMutants: Int) {
        self.signal = signal
        self.completedMutants = completedMutants
        self.plannedMutants = plannedMutants
    }
}
