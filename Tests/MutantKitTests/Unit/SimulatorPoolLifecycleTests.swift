import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Unit tests for `SimulatorPool.prepare(udid:)`'s boot/bootstatus
/// sequence, using an injected `ProcessRunner` to script the subprocess
/// boundary without a real simulator.
///
/// These exist because a prior version string-matched `"already booted"`
/// in the boot command's output — a token CoreSimulator never prints (the
/// real message is `"Unable to boot device in current state: Booted"`),
/// which silently broke every warm run. The fix is to ignore the boot
/// command's exit code entirely and treat `simctl bootstatus` as the only
/// readiness gate. These tests pin that behaviour.
@Suite("Simulator pool: prepare(udid:) boot lifecycle")
struct SimulatorPoolLifecycleTests {
    private static let udid = "DEADBEAF-0000-0000-0000-000000000001"
    private static let workingDirectory = FileManager.default.temporaryDirectory

    private static let singleDeviceJSON = """
    {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
        {"udid": "\(udid)", "name": "iPhone 16", "state": "Shutdown", "isAvailable": true}
    ]}}
    """

    private static let bootedDeviceJSON = """
    {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
        {"udid": "\(udid)", "name": "iPhone 16", "state": "Booted", "isAvailable": true}
    ]}}
    """

    private static func success(_ stdout: String = "") -> ProcessResult {
        ProcessResult(
            exitCode: 0, standardOutput: Data(stdout.utf8), standardError: Data(),
            durationSeconds: 0.01, timedOut: false, terminatingSignal: nil
        )
    }

    private static func failure(exitCode: Int32 = 1, _ stderr: String = "") -> ProcessResult {
        ProcessResult(
            exitCode: exitCode, standardOutput: Data(), standardError: Data(stderr.utf8),
            durationSeconds: 0.01, timedOut: false, terminatingSignal: nil
        )
    }

    /// Builds a scripted ProcessRunner that answers `simctl list` with a
    /// payload containing the suite's device, and answers every subsequent
    /// call from `scripted`.
    private static func runner(
        deviceJSON: String = singleDeviceJSON,
        _ scripted: @escaping @Sendable (String, [String]) async throws -> ProcessResult
    ) -> SimulatorPool.ProcessRunner {
        { executable, arguments, _, _ in
            if arguments.contains("list") {
                return ProcessResult(
                    exitCode: 0,
                    standardOutput: Data(deviceJSON.utf8),
                    standardError: Data(),
                    durationSeconds: 0.01,
                    timedOut: false,
                    terminatingSignal: nil
                )
            }
            return try await scripted(executable, arguments)
        }
    }

    // MARK: - The bug that was fixed

    @Test("A warm device: boot exits non-zero, bootstatus succeeds — prepare succeeds")
    func warmDeviceBootFailureIsIgnored() async throws {
        // This is the exact path the prior version broke on: `simctl boot`
        // returns non-zero with CoreSimulator's actual message, and the
        // old code tried to match a nonexistent "already booted" token.
        // The fix ignores boot's exit code and gates on bootstatus alone.
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, arguments in
                if arguments.contains("boot"), !arguments.contains("bootstatus") {
                    return Self.failure(
                        exitCode: 1,
                        "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=164):\n"
                            + "Unable to boot device in current state: Booted"
                    )
                }
                return Self.success()
            }
        )

        try await pool.prepare(udid: Self.udid)
    }

    @Test("A cold device: boot succeeds, bootstatus succeeds — prepare succeeds")
    func coldDeviceBothSucceed() async throws {
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, _ in Self.success() }
        )

        try await pool.prepare(udid: Self.udid)
    }

    // MARK: - Boot outcome reporting

    @Test("prepare reports .prepared for a cold device it booted")
    func prepareReportsColdBoot() async throws {
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, _ in Self.success() }
        )

        let outcome = try await pool.prepare(udid: Self.udid)
        #expect(outcome == .prepared)
    }

    @Test("prepare reports .alreadyBooted for a warm device")
    func prepareReportsWarmBoot() async throws {
        // `simctl boot` exits non-zero for an already-booted device, but the
        // device list reports state "Booted" — that state, not boot's exit
        // code, is what distinguishes warm from cold.
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner(deviceJSON: Self.bootedDeviceJSON) { _, arguments in
                if arguments.contains("boot"), !arguments.contains("bootstatus") {
                    return Self.failure(
                        exitCode: 1,
                        "Unable to boot device in current state: Booted"
                    )
                }
                return Self.success()
            }
        )

        let outcome = try await pool.prepare(udid: Self.udid)
        #expect(outcome == .alreadyBooted)
    }

    // MARK: - Error paths

    @Test("bootstatus failure throws bootFailed regardless of boot's exit code")
    func bootstatusFailureThrows() async throws {
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, arguments in
                if arguments.contains("bootstatus") {
                    return Self.failure(exitCode: 1, "Device never became ready")
                }
                return Self.success()
            }
        )

        await #expect(throws: SimulatorPoolError.self) {
            try await pool.prepare(udid: Self.udid)
        }
    }

    // MARK: - Retry (transient CI host contention)

    /// The exact shape a real, overloaded CI runner produces: `bootstatus`
    /// fails on the first attempt (the device genuinely was not ready yet
    /// under host contention) and succeeds moments later with no other
    /// change. `prepare` must recover on its own rather than surfacing a
    /// failure a caller could have avoided by simply trying again.
    @Test("A transient bootstatus failure recovers on retry")
    func transientBootstatusFailureRecoversOnRetry() async throws {
        let bootstatusAttempts = Counter()
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, arguments in
                if arguments.contains("bootstatus") {
                    let attempt = await bootstatusAttempts.increment()
                    return attempt == 1 ? Self.failure(exitCode: 1, "Device never became ready") : Self.success()
                }
                return Self.success()
            }
        )

        let outcome = try await pool.prepare(udid: Self.udid, bootstatusRetries: 2, retryDelaySeconds: 0)
        #expect(outcome == .prepared)
        #expect(await bootstatusAttempts.count == 2, "one failed attempt, one successful retry")
    }

    /// Every retry re-issues `boot`, not just `bootstatus` — a device a
    /// failed `bootstatus` left in a bad state might need a fresh boot
    /// command to actually recover, not just another status poll.
    @Test("Each retry re-issues both boot and bootstatus")
    func retryReissuesBothBootAndBootstatus() async throws {
        let bootAttempts = Counter()
        let bootstatusAttempts = Counter()
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, arguments in
                if arguments.contains("boot"), !arguments.contains("bootstatus") {
                    await bootAttempts.increment()
                    return Self.success()
                }
                if arguments.contains("bootstatus") {
                    let attempt = await bootstatusAttempts.increment()
                    return attempt <= 2 ? Self.failure(exitCode: 1, "Device never became ready") : Self.success()
                }
                return Self.success()
            }
        )

        let outcome = try await pool.prepare(udid: Self.udid, bootstatusRetries: 2, retryDelaySeconds: 0)
        #expect(outcome == .prepared)
        #expect(await bootAttempts.count == 3, "one initial attempt plus two retries")
        #expect(await bootstatusAttempts.count == 3)
    }

    /// `bootstatusRetries: 0` disables retry entirely — the first failure is
    /// the only one, and it is what throws.
    @Test("bootstatusRetries: 0 fails on the first attempt, no retry")
    func zeroRetriesFailsImmediately() async throws {
        let bootstatusAttempts = Counter()
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, arguments in
                if arguments.contains("bootstatus") {
                    await bootstatusAttempts.increment()
                    return Self.failure(exitCode: 1, "Device never became ready")
                }
                return Self.success()
            }
        )

        await #expect(throws: SimulatorPoolError.self) {
            try await pool.prepare(udid: Self.udid, bootstatusRetries: 0, retryDelaySeconds: 0)
        }
        #expect(await bootstatusAttempts.count == 1)
    }

    /// A device that never recovers still eventually throws, after
    /// exhausting every retry — retrying must never turn a genuinely broken
    /// device into an infinite wait or a silently-swallowed failure.
    @Test("A device that never recovers still throws after exhausting every retry")
    func neverRecoveringDeviceStillThrowsAfterRetries() async throws {
        let bootstatusAttempts = Counter()
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, arguments in
                if arguments.contains("bootstatus") {
                    await bootstatusAttempts.increment()
                    return Self.failure(exitCode: 1, "Device never became ready")
                }
                return Self.success()
            }
        )

        await #expect(throws: SimulatorPoolError.self) {
            try await pool.prepare(udid: Self.udid, bootstatusRetries: 2, retryDelaySeconds: 0)
        }
        #expect(await bootstatusAttempts.count == 3, "one initial attempt plus two retries, then give up")
    }

    /// A cancelled `prepare` must never launch one more `simctl` process on
    /// the caller's behalf — a CLI stop or an overall run timeout has to
    /// actually stop things, not "stop, except for whatever retry was
    /// already in its delay".
    @Test("Cancellation during the retry delay aborts prepare without a second boot attempt")
    func cancellationDuringRetryDelayAbortsWithoutRetrying() async throws {
        let bootAttempts = Counter()
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, arguments in
                if arguments.contains("boot"), !arguments.contains("bootstatus") {
                    await bootAttempts.increment()
                    return Self.success()
                }
                if arguments.contains("bootstatus") {
                    return Self.failure(exitCode: 1, "Device never became ready")
                }
                return Self.success()
            }
        )

        let task = Task {
            try await pool.prepare(udid: Self.udid, bootstatusRetries: 2, retryDelaySeconds: 30)
        }
        // Long enough for the first attempt's real bootstatus failure to be
        // scripted and observed, short enough to land well inside the 30s
        // retry delay rather than racing it.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        let result = await task.result
        #expect(throws: (any Error).self) { try result.get() }
        #expect(await bootAttempts.count == 1, "cancellation during the retry delay must prevent the second boot attempt")
    }

    /// `boot`/`bootstatus` failing to even *launch* (a structural host
    /// problem — `xcrun` missing, a sandboxing failure) is not the
    /// transient-readiness case retry exists for; it must throw immediately,
    /// attempted exactly once.
    @Test("A fatal process-launch error is attempted exactly once, never retried")
    func fatalInvocationErrorAttemptedOnce() async throws {
        struct LaunchFailure: Error {}
        let bootAttempts = Counter()
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, arguments in
                if arguments.contains("boot"), !arguments.contains("bootstatus") {
                    await bootAttempts.increment()
                    throw LaunchFailure()
                }
                return Self.success()
            }
        )

        await #expect(throws: SimulatorPoolError.self) {
            try await pool.prepare(udid: Self.udid, bootstatusRetries: 2, retryDelaySeconds: 0)
        }
        #expect(await bootAttempts.count == 1, "a fatal launch failure must not be retried")
    }

    @Test("bootstatus timeout throws bootFailed")
    func bootstatusTimeoutThrows() async throws {
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, arguments in
                if arguments.contains("bootstatus") {
                    return ProcessResult(
                        exitCode: 0, standardOutput: Data(), standardError: Data(),
                        durationSeconds: 90, timedOut: true, terminatingSignal: nil
                    )
                }
                return Self.success()
            }
        )

        await #expect(throws: SimulatorPoolError.self) {
            try await pool.prepare(udid: Self.udid)
        }
    }

    @Test("A process runner that throws propagates as bootFailed")
    func processThrowPropagatesAsBootFailed() async throws {
        struct FakeError: Error {}
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, arguments in
                if arguments.contains("boot"), !arguments.contains("bootstatus") {
                    throw FakeError()
                }
                return Self.success()
            }
        )

        await #expect(throws: SimulatorPoolError.self) {
            try await pool.prepare(udid: Self.udid)
        }
    }

    @Test("An unknown UDID throws noneAvailable before any boot is attempted")
    func unknownUDIDThrowsBeforeBoot() async throws {
        let actor = BootCallTracker()
        let pool = SimulatorPool(
            workingDirectory: Self.workingDirectory,
            processRunner: Self.runner { _, arguments in
                if arguments.contains("boot") { await actor.markBootAttempted() }
                return Self.success()
            }
        )

        await #expect(throws: SimulatorPoolError.self) {
            try await pool.prepare(udid: "nonexistent-udid")
        }
        let attempted = await actor.bootAttempted
        #expect(!attempted, "boot must not be attempted for an unknown UDID")
    }

    // MARK: - Error descriptions

    @Test("bootFailed includes the underlying detail in its description")
    func bootFailedDescriptionCarriesDetail() {
        let error = SimulatorPoolError.bootFailed(detail: "simctl returned exit 1: device vanished")

        #expect(error.description == "Could not boot the simulator: simctl returned exit 1: device vanished")
    }

    @Test("noneAvailable and simctlFailed descriptions are unchanged alongside bootFailed")
    func existingDescriptionsUnchanged() {
        #expect(
            SimulatorPoolError.noneAvailable(runtimeHint: "iPhone 17").description
                == "No available simulator matches iPhone 17. Install one in Xcode > Settings > Components."
        )
        #expect(
            SimulatorPoolError.noneAvailable(runtimeHint: nil as String?).description
                == "No available simulators are installed. Add one in Xcode > Settings > Components."
        )
        #expect(
            SimulatorPoolError.simctlFailed(detail: "timeout").description
                == "Could not list simulators: timeout"
        )
    }
}

/// Tracks whether the scripted runner saw a `boot` call, without the
/// struct-of-arrays data race that a plain `var` in the test type would
/// create under Swift 6 strict concurrency.
private actor BootCallTracker {
    private(set) var bootAttempted = false
    func markBootAttempted() { bootAttempted = true }
}

/// Counts scripted-runner calls, for the retry tests — same data-race
/// concern as `BootCallTracker`, generalized to a count instead of a flag.
private actor Counter {
    private(set) var count = 0
    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}
