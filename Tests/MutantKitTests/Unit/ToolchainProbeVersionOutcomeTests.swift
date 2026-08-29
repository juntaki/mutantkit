@testable import CLI
import Foundation
import Testing

/// Real, subprocess-backed regression for `ToolchainProbe.firstLine`'s own
/// `VersionProbeOutcome` classification — the exact seam a round-4 review
/// found conflated two genuinely different facts: a tool that plainly is
/// not on this machine (`.notPresent`, safe to hash into an identity) and a
/// tool that exists but whose probe could not be trusted this time
/// (`.probeFailed`, e.g. `xcodebuild -version` timing out or exiting
/// non-zero) — both of which previously collapsed into the same
/// `.unavailable` case. `ToolchainProbeCombinedCompletenessTests` proves the
/// *combining* logic treats the two differently once it has them; this
/// suite proves `firstLine` itself actually produces the right one for a
/// real, controlled subprocess, rather than only asserting it in the
/// abstract.
@Suite("ToolchainProbe.firstLine: real subprocess outcome classification")
struct ToolchainProbeVersionOutcomeTests {
    private let workingDirectory = FileManager.default.temporaryDirectory

    /// Writes an executable shell script at a fresh temporary path and
    /// returns it — real `posix_spawn`/exit-code/stdout behavior, not a
    /// hand-constructed `ProcessResult`, so this exercises exactly the path
    /// `firstLine` actually walks.
    private func script(_ body: String) throws -> String {
        let url = workingDirectory.appendingPathComponent("toolchain-probe-outcome-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func describe(_ outcome: ToolchainProbe.VersionProbeOutcome) -> String {
        switch outcome {
        case let .value(value): "value(\(value))"
        case .notPresent: "notPresent"
        case .probeFailed: "probeFailed"
        case .incomplete: "incomplete"
        }
    }

    @Test("A path with nothing executable at it resolves to .notPresent")
    func missingExecutableResolvesToNotPresent() async throws {
        let missingPath = workingDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)").path

        let outcome = await ToolchainProbe.firstLine(of: missingPath, arguments: [], in: workingDirectory)

        guard case .notPresent = outcome else {
            Issue.record("expected .notPresent, got \(describe(outcome))")
            return
        }
    }

    /// The exact real-machine shape the round-4 review described: the tool
    /// exists and runs, but exits non-zero — a genuinely different fact from
    /// "not present," and one that must not be allowed to collapse into the
    /// same identity-safe outcome.
    @Test("An executable that runs but exits non-zero resolves to .probeFailed, never .notPresent")
    func nonZeroExitResolvesToProbeFailedNotNotPresent() async throws {
        let path = try script("exit 7")

        let outcome = await ToolchainProbe.firstLine(of: path, arguments: [], in: workingDirectory)

        guard case .probeFailed = outcome else {
            Issue.record("expected .probeFailed, got \(describe(outcome))")
            return
        }
    }

    @Test("An executable that exits 0 but prints nothing parseable resolves to .probeFailed")
    func successfulExitWithNoOutputResolvesToProbeFailed() async throws {
        let path = try script("exit 0")

        let outcome = await ToolchainProbe.firstLine(of: path, arguments: [], in: workingDirectory)

        guard case .probeFailed = outcome else {
            Issue.record("expected .probeFailed, got \(describe(outcome))")
            return
        }
    }

    @Test("An executable that exits 0 and prints a version line resolves to .value with that line")
    func successfulExitWithOutputResolvesToValue() async throws {
        let path = try script("echo '1.2.3'")

        let outcome = await ToolchainProbe.firstLine(of: path, arguments: [], in: workingDirectory)

        #expect(outcome.value == "1.2.3")
    }
}
