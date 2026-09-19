import Foundation
import MutationExecution

/// The diagnosis text a run gets when no scheme could be resolved.
///
/// Split out of `resolveScheme` because the one thing that was actually
/// wrong there was that a single sentence served two unrelated events.
/// `discoverSchemes`' own doc comment used to state the collapse as a
/// design decision — "every caller treats 'could not ask' and 'there are
/// none' the same way: both mean no scheme can be resolved, and both are
/// reported with the same remedy" — and a real CI failure (2026-09-19,
/// `Acceptance (xcode-project-schemata)`) showed the second half of that
/// sentence is false:
///
/// ```
/// exitCode: 143   durationSeconds: 120.056   output: ""
/// diagnosis: "No schemes are available here. Open the project in Xcode
///             and mark a scheme shared, or set project.scheme in
///             mutantkit.yml."
/// ```
///
/// `143` is `128 + SIGTERM` and the duration is exactly the 120-second
/// budget: `xcodebuild -list -json` was killed at its own timeout having
/// written nothing. The project's schemes were configured correctly and
/// shared; the run simply never got an answer. Telling that user to go mark
/// a scheme shared in Xcode sends them to fix something that is not broken,
/// and — worse for a tool whose whole value is trustworthy verdicts —
/// states as fact ("no schemes are available") a thing the evidence in hand
/// positively does not support.
///
/// The evidence needed to tell the two apart was already being collected:
/// `discoverSchemesWithDiagnostics` keeps the raw `ProcessResult` expressly
/// so this failure can carry "the real exit code/stdout/stderr", and its
/// retry policy already distinguishes a clean empty answer from a timeout
/// or a crash ("Only a clean empty result is retried"). Only the message
/// collapsed them. So this is not new machinery: it is the existing
/// evidence finally reaching the sentence the user reads.
enum SchemeResolutionDiagnosis {
    /// `nil` scheme list, explained by what actually happened.
    ///
    /// - Parameter answered: whether `xcodebuild` actually produced a
    ///   scheme list to read. `false` covers every way the question went
    ///   unanswered — not started, killed at its timeout, killed by
    ///   another signal, non-zero exit, or an exit whose output was never
    ///   confirmed complete — and every one of those means the emptiness
    ///   is an absence of evidence, not evidence of absence.
    static func noSchemeResolved(
        answered: Bool,
        lastResult: ProcessResult?,
        timeoutSeconds: Double
    ) -> String {
        guard answered else { return couldNotAsk(lastResult, timeoutSeconds: timeoutSeconds) }
        return """
        No schemes are available here. Open the project in Xcode and mark a \
        scheme shared, or set project.scheme in mutantkit.yml.
        """
    }

    /// Every branch here says the same two things in the same order: what
    /// was observed, and that the project's own configuration is *not*
    /// what it implicates. The remedy differs because the cause differs —
    /// which is the entire point of separating them from the message
    /// above.
    private static func couldNotAsk(_ result: ProcessResult?, timeoutSeconds: Double) -> String {
        let unknown = """
        No scheme list was produced at all, so whether this project has any is still unknown — \
        nothing here says its schemes are misconfigured.
        """
        let skip = "set project.scheme in mutantkit.yml to skip discovery entirely"

        guard let result else {
            return """
            `xcodebuild -list -json` could not be started. \(unknown) Check that Xcode's command \
            line tools are installed and selected (`xcode-select -p`), then retry.
            """
        }
        if result.timedOut {
            return """
            `xcodebuild -list -json` was killed after \(seconds(result.durationSeconds)) without \
            answering, at its \(seconds(timeoutSeconds)) budget. \(unknown) A machine loaded \
            enough that `xcodebuild` cannot finish starting up is the usual cause; retry, or \
            \(skip).
            """
        }
        if let signal = result.terminatingSignal {
            return """
            `xcodebuild -list -json` was killed by signal \(signal) after \
            \(seconds(result.durationSeconds)). \(unknown) Retry, or \(skip).
            """
        }
        if result.exitCode != 0 {
            return """
            `xcodebuild -list -json` exited with status \(result.exitCode) without producing a \
            scheme list; its own output is below. \(unknown)
            """
        }
        return """
        `xcodebuild -list -json` exited cleanly, but its output was never confirmed complete, so \
        the empty scheme list read from it is not evidence. \(unknown) Retry, or \(skip).
        """
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.1fs", value)
    }
}
