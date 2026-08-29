@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// The consumer-side regression for `BuildClassifier`'s `outputComplete`
/// guard: a build whose output could not be proven fully captured must
/// classify as `.infrastructure`, never `.compilationError` — even when the
/// (truncated) bytes that did make it through look exactly like a real
/// compiler diagnostic. Trusting a marker/diagnostic search against
/// incomplete output would let a coincidental partial match invent a
/// classification the actual, unseen bytes might not support at all — see
/// `ProcessResult.outputComplete`'s own doc comment for the real incident
/// this class of check exists to guard against.
///
/// Hand-constructed, not run against a real subprocess: `outputComplete`'s
/// only job here is to gate a pure string classification, so a directly
/// built `ProcessResult` with the field forced to `false` exercises the
/// exact branch `BuildClassifier.failure` takes without needing to
/// reproduce the drain-timeout condition itself (already proven real and
/// deterministic by `ForcedIncompleteOutputFixture`/
/// `ProcessSupervisorOutputCompletenessTests`).
@Suite("BuildClassifier: refuses to classify from incomplete output")
struct BuildClassifierOutputCompletenessTests {
    private func command() -> CommandRecord {
        CommandRecord(executable: "xcodebuild", arguments: ["build"], workingDirectory: "/tmp")
    }

    @Test("Output that looks exactly like a compiler error, but is marked incomplete, classifies as .infrastructure, not .compilationError")
    func incompleteOutputWithAnErrorLookingMarkerIsInfrastructureNotCompilationError() throws {
        // Exactly the shape `firstDiagnostic(in:)` matches — if `outputComplete`
        // were ignored, this would classify as `.compilationError`.
        let diagnosticLookingOutput = "Mutant.swift:12:34: error: cannot find 'x' in scope\n"
        let result = ProcessResult(
            exitCode: 1,
            standardOutput: Data(diagnosticLookingOutput.utf8),
            standardError: Data(),
            durationSeconds: 1,
            timedOut: false,
            terminatingSignal: nil,
            outputComplete: false
        )

        let failure = BuildClassifier.failure(from: result, command: command())

        #expect(failure.kind == .infrastructure)
        #expect(failure.diagnosis.localizedCaseInsensitiveContains("could not be fully captured"))
        // Never silently promoted to a compilation error just because the
        // captured bytes happen to contain a diagnostic-shaped line.
        #expect(!failure.diagnosis.localizedCaseInsensitiveContains("does not compile"))
    }

    @Test("Complete output with the identical diagnostic still classifies as .compilationError")
    func completeOutputWithTheSameDiagnosticIsStillCompilationError() throws {
        // Same bytes as above, only `outputComplete` differs — isolates the
        // guard as the one thing responsible for the different verdict.
        let diagnosticLookingOutput = "Mutant.swift:12:34: error: cannot find 'x' in scope\n"
        let result = ProcessResult(
            exitCode: 1,
            standardOutput: Data(diagnosticLookingOutput.utf8),
            standardError: Data(),
            durationSeconds: 1,
            timedOut: false,
            terminatingSignal: nil,
            outputComplete: true
        )

        let failure = BuildClassifier.failure(from: result, command: command())

        #expect(failure.kind == .compilationError)
    }
}
