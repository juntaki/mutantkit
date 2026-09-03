import Darwin
import Foundation
@testable import MutationExecution
import Testing

/// F3 zero-base review, Finding 1: this is **not** a regression test —
/// it is a deliberately permanent, deterministic proof of a documented
/// boundary of `ProcessSupervisor`'s own ownership contract (see that
/// type's own top-level doc comment, "Ownership contract (F3 zero-base
/// review)"), not a bug this codebase is expected to eventually fix.
///
/// A descendant that escapes its process group and whose root exits
/// before that descendant was ever individually observed is
/// unconditionally undiscoverable by ancestry alone — proven structurally
/// in `EscapedDescendantOwnershipBoundaryDiagnostic
/// .groupEscapedDescendantIsUnrecoverableAfterZeroObservationWindow`
/// below, independent of `ProcessSupervisor`'s own poll timing entirely
/// (see that test's own doc comment). Investigated at length during the
/// zero-base review: no macOS API available to an ordinary, unprivileged
/// CLI closes this — `kqueue`/`EVFILT_PROC`'s `NOTE_TRACK`/`NOTE_CHILD`
/// (the one primitive that could make this atomic) is `ENOTSUP` on
/// Darwin, and bare `NOTE_FORK` carries no child-pid payload; Endpoint
/// Security could, in principle, but requires a restricted entitlement no
/// ordinary CLI can assume.
///
/// **Excluded from the default `swift test` run deliberately** — a
/// permanent RED left in the default suite either reads as "known
/// broken, ignore it" (train reviewers to skip real failures) or invites
/// "fix" it by turning the test around into "the escaped child must
/// survive" (asserting the *opposite*), which would silently regress the
/// moment a genuinely better mechanism becomes available, since a future
/// fix making ownership deterministic would then read as a test failure.
/// Run explicitly with `MUTANTKIT_DIAGNOSTIC_OWNERSHIP_BOUNDARY=1 swift
/// test --filter EscapedDescendantOwnershipBoundaryDiagnostic` to
/// re-confirm this boundary still holds (e.g. after a macOS release, in
/// case a future Darwin kernel adds `NOTE_TRACK` support) or after any
/// change to `ProcessTree`/`detectRootExit`'s own discovery mechanism.
@Suite(
    "Diagnostic: ProcessSupervisor's escaped-descendant ownership boundary",
    .enabled(if: ProcessInfo.processInfo.environment["MUTANTKIT_DIAGNOSTIC_OWNERSHIP_BOUNDARY"] == "1")
)
struct EscapedDescendantOwnershipBoundaryDiagnostic {
    /// Deterministic, **not** timing-dependent: proves the *structural*
    /// floor of `ProcessTree.descendantIdentities(of:)`'s ancestry walk,
    /// independent of `ProcessSupervisor`'s own poll timing entirely.
    ///
    /// Spawns a root via a real, separate process (never `fork()` inside
    /// this multithreaded Foundation-linked test binary, which is unsafe),
    /// whose only child immediately escapes into its own process group
    /// (`setpgid(0, 0)`, the exact shape `ProcessTree`'s own doc comment
    /// attributes to `swiftpm-testing-helper`) and then blocks, alive, for
    /// a full second -- ample time for any external observer to confirm it
    /// exists. `root` exits immediately after `fork()` returns, with zero
    /// artificial delay.
    ///
    /// The test then does the one thing no amount of polling frequency can
    /// improve on: it uses `Process.waitUntilExit()` -- a real, blocking
    /// reap, guaranteeing **zero** `ProcessTree` observations happened
    /// between the child's fork and root's exit -- and only *then* calls
    /// `ProcessTree.descendantIdentities(of: rootPID)`.
    /// `ProcessSupervisorZeroBaseReviewFindingsTests
    /// .reparentingToLaunchdIsAlreadyCompleteTheInstantRootExits`
    /// independently confirms, 5-for-5, that the child's own `ppid` has
    /// already flipped to `1` (launchd) by the time root has been reaped --
    /// i.e., this is not "polling might be too slow," it is "the ancestry
    /// proof this mechanism depends on is *already severed* before this
    /// call even runs." No amount of tightening `baselinePollIntervalMicroseconds`
    /// changes this outcome, because the outcome does not depend on when
    /// any poll ran at all.
    @Test("A group-escaped descendant is unconditionally undiscoverable by ancestry once root has exited with zero observation")
    func groupEscapedDescendantIsUnrecoverableAfterZeroObservationWindow() throws {
        let resultsPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkit-zbr-f1-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: resultsPath) }

        let script = """
        import os, time
        pid = os.fork()
        if pid == 0:
            os.setpgid(0, 0)
            with open(\(pythonLiteral(resultsPath)) + ".tmp", "w") as f:
                f.write(str(os.getpid()))
            os.rename(\(pythonLiteral(resultsPath)) + ".tmp", \(pythonLiteral(resultsPath)))
            time.sleep(1.0)
            os._exit(0)
        else:
            os._exit(0)
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let rootPID = process.processIdentifier

        // Fully blocking, real reap -- by construction, zero `ProcessTree`
        // observations can have happened in the window between the
        // child's fork() and this call returning, no matter how this test
        // binary happens to be scheduled.
        process.waitUntilExit()

        let discovered = ProcessTree.descendantIdentities(of: rootPID)

        let childPID = try waitForResultsFile(resultsPath)
        defer { if ProcessTree.isAlive(childPID) { kill(childPID, SIGKILL) } }

        #expect(
            discovered.contains { $0.pid == childPID },
            """
            a descendant that escaped its process group and forked before root exited must still be discoverable as owned, \
            even when root exited before any poll could observe it -- ancestry-only discovery cannot provide this
            """
        )
    }

    // MARK: - Support

    private func waitForResultsFile(_ path: String, timeoutSeconds: Double = 10) throws -> pid_t {
        struct SetupFailure: Error, CustomStringConvertible {
            let description: String
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            usleep(1000)
        }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw SetupFailure(description: "\(path) never appeared with a readable pid")
        }
        return pid
    }

    private func pythonLiteral(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}
