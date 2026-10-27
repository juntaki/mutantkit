import Foundation
import MutationExecution
import MutationModel

// Test-only conveniences. The production initializers of `ProcessResult` and
// `TestRunResult` deliberately have no default for `cleanupVerified`, so a
// production wrapper that forgets to carry the value forward fails to
// compile. Fixtures that are not about cleanup verification use these
// overloads, which state `true`; a test that is about it passes
// `cleanupVerified:` explicitly and so resolves to the production
// initializer.

extension ProcessResult {
    init(
        exitCode: Int32,
        standardOutput: Data,
        standardError: Data,
        durationSeconds: Double,
        timedOut: Bool,
        terminatingSignal: Int32?,
        stalled: Bool = false,
        outputComplete: Bool
    ) {
        self.init(
            exitCode: exitCode, standardOutput: standardOutput, standardError: standardError, durationSeconds: durationSeconds,
            timedOut: timedOut, terminatingSignal: terminatingSignal, stalled: stalled, outputComplete: outputComplete,
            cleanupVerified: true
        )
    }
}

extension TestRunResult {
    init(
        status: TestRunStatus,
        summary: TestOutcomeSummary?,
        command: CommandRecord,
        resultArtifactPath: URL?,
        diagnosis: String,
        isBatchAttributedTimeout: Bool = false,
        crashProvenance: CrashProvenance? = nil
    ) {
        self.init(
            status: status, summary: summary, command: command, resultArtifactPath: resultArtifactPath, diagnosis: diagnosis,
            isBatchAttributedTimeout: isBatchAttributedTimeout, crashProvenance: crashProvenance, cleanupVerified: true
        )
    }
}
