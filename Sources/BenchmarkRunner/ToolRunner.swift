import Foundation
#if canImport(Darwin)
    import Darwin
#endif

/// One external-process invocation to make — either tool, always run as a
/// plain subprocess (never linked in-process), so the harness measures
/// exactly what a real command-line user experiences.
public struct ToolInvocation: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let environment: [String: String]
    public let timeoutSeconds: Double

    public init(
        executableURL: URL, arguments: [String], workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment, timeoutSeconds: Double
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct ToolExecutionResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let wallSeconds: Double
    /// `true` when the process was killed by `ToolRunner` itself for
    /// exceeding `timeoutSeconds` — `exitCode` in that case reflects the
    /// forced termination, not a real tool-reported exit status, and
    /// `ResultNormalizer` must never interpret it as a genuine result.
    public let timedOut: Bool
    /// The root process ID, for a caller (`MeasurementCollector`) that
    /// wants to have sampled the process tree while this ran — `ToolRunner`
    /// itself does not sample resource usage; that is a distinct concern
    /// with its own type.
    public let processID: pid_t

    public init(exitCode: Int32, standardOutput: String, standardError: String, wallSeconds: Double, timedOut: Bool, processID: pid_t) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.wallSeconds = wallSeconds
        self.timedOut = timedOut
        self.processID = processID
    }
}

public enum ToolRunnerError: Error, CustomStringConvertible {
    case launchFailed(String)

    public var description: String {
        switch self {
        case let .launchFailed(reason): "could not launch the tool process: \(reason)"
        }
    }
}

/// Runs one external tool invocation to completion (or to its timeout),
/// capturing everything a benchmark measurement needs about how the
/// process itself behaved — exit code, output, wall time. Deliberately
/// ignorant of what the tool *means* by its output; `ResultNormalizer`
/// interprets `standardOutput`/report files, this type never does.
public struct ToolRunner: Sendable {
    public init() {}

    /// While the process runs, `onProcessStarted` is invoked once with its
    /// PID — the hook `MeasurementCollector` uses to start sampling the
    /// process tree concurrently, since RSS/CPU time cannot be recovered
    /// after a process has already exited.
    public func run(
        _ invocation: ToolInvocation, onProcessStarted: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> ToolExecutionResult {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        process.environment = invocation.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let started = Date()
        do {
            try process.run()
        } catch {
            throw ToolRunnerError.launchFailed("\(error)")
        }
        onProcessStarted?(process.processIdentifier)

        let timedOut = await waitWithTimeout(process, timeoutSeconds: invocation.timeoutSeconds)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ToolExecutionResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: stdoutData, as: UTF8.self),
            standardError: String(decoding: stderrData, as: UTF8.self),
            wallSeconds: Date().timeIntervalSince(started),
            timedOut: timedOut,
            processID: process.processIdentifier
        )
    }

    /// Races the process's own termination against a timeout task. On
    /// timeout, `SIGTERM` first (letting a well-behaved tool clean up its
    /// own child processes), then `SIGKILL` after a short grace period if
    /// it is still alive — the same two-stage discipline `ProcessSupervisor`
    /// (MutantKit's own isolated-mode process control) uses, reimplemented
    /// here rather than depending on it, since `BenchmarkRunner` must not
    /// couple to MutantKit's execution engine.
    private func waitWithTimeout(_ process: Process, timeoutSeconds: Double) async -> Bool {
        let exited = LockedFlag()
        let timedOut = LockedFlag()

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(timeoutSeconds, 0) * 1_000_000_000))
            guard !exited.get(), process.isRunning else { return }
            timedOut.set(true)
            process.terminate()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if process.isRunning {
                Foundation.kill(process.processIdentifier, SIGKILL)
            }
        }

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                exited.set(true)
                watchdog.cancel()
                continuation.resume()
            }
        }
        return timedOut.get()
    }
}

/// A plain `Bool` guarded by a lock — `Process.terminationHandler` and the
/// timeout `DispatchWorkItem` both run on arbitrary `DispatchQueue.global()`
/// threads, so this needs real synchronization, not just `@unchecked Sendable`
/// on an unguarded var.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
