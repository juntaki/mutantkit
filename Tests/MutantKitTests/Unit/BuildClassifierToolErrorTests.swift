@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// A build that fails before the compiler runs (for example SwiftPM refusing
/// to resolve a local package) prints a bare `error: …` line with no source
/// location. The classifier must keep calling that `.infrastructure`, but the
/// diagnosis has to carry the tool's own line — otherwise the only thing a
/// user sees is "exited with 1 but produced no compiler diagnostic".
@Suite("BuildClassifier: surfaces a build tool error that has no source location")
struct BuildClassifierToolErrorTests {
    private func command() -> CommandRecord {
        CommandRecord(executable: "swift", arguments: ["build", "--build-tests"], workingDirectory: "/tmp")
    }

    private func result(stdout: String = "", stderr: String, complete: Bool = true) -> ProcessResult {
        ProcessResult(
            exitCode: 1,
            standardOutput: Data(stdout.utf8),
            standardError: Data(stderr.utf8),
            durationSeconds: 1,
            timedOut: false,
            terminatingSignal: nil,
            outputComplete: complete
        )
    }

    private var home: String {
        NSHomeDirectory()
    }

    @Test("SwiftPM's inaccessible-package error is quoted in the diagnosis, home-abbreviated, and stays .infrastructure")
    func inaccessibleLocalPackageIsQuoted() {
        let missing = "\(home)/src/Foundation/Core/.mutantkit/sandboxes/SwiftMapper"
        let stderr = "error: the package at '\(missing)' cannot be accessed (\(missing) doesn't exist in file system)\n"

        let failure = BuildClassifier.failure(from: result(stderr: stderr), command: command())

        #expect(failure.kind == .infrastructure)
        #expect(failure.diagnosis.contains(
            "error: the package at '~/src/Foundation/Core/.mutantkit/sandboxes/SwiftMapper' cannot be accessed"
        ))
        #expect(!failure.diagnosis.contains(home + "/"))
        #expect(failure.diagnosis.contains("before compilation"))
        #expect(failure.diagnosis.contains("cannot be attributed to the mutated source"))
    }

    @Test("Without a tool error line the diagnosis is the plain no-diagnostic fallback")
    func noToolErrorLineKeepsThePlainFallback() {
        let failure = BuildClassifier.failure(
            from: result(stdout: "Building for debugging...\n", stderr: "warning: something odd\n"),
            command: command()
        )

        #expect(failure.kind == .infrastructure)
        #expect(failure.diagnosis.contains("produced no compiler diagnostic"))
        #expect(!failure.diagnosis.contains("warning: something odd"))
        #expect(!failure.diagnosis.contains("before compilation"))
    }

    @Test("Only the first tool error line is quoted")
    func onlyTheFirstToolErrorIsQuoted() {
        let stderr = "error: first problem\nerror: second problem\n"

        let failure = BuildClassifier.failure(from: result(stderr: stderr), command: command())

        #expect(failure.diagnosis.contains("error: first problem"))
        #expect(!failure.diagnosis.contains("second problem"))
    }

    @Test("A very long tool error line is capped")
    func longToolErrorIsCapped() {
        let stderr = "error: " + String(repeating: "x", count: 5000) + "\n"

        let failure = BuildClassifier.failure(from: result(stderr: stderr), command: command())

        #expect(failure.kind == .infrastructure)
        #expect(failure.diagnosis.contains("error: xxx"))
        #expect(failure.diagnosis.count < 1000)
        #expect(failure.diagnosis.contains("…"))
    }

    @Test("Credentials in the quoted line are redacted")
    func credentialsInTheToolErrorAreRedacted() {
        let stderr = "error: failed to clone https://bot:hunter2secret@example.com/repo.git\n"

        let failure = BuildClassifier.failure(from: result(stderr: stderr), command: command())

        #expect(failure.diagnosis.contains("error: failed to clone"))
        #expect(!failure.diagnosis.contains("hunter2secret"))
    }

    @Test("A located compiler diagnostic still wins and classifies as .compilationError")
    func compilerDiagnosticStillWins() {
        let stderr = """
        error: emit-module command failed with exit code 1
        Sources/Core/Mutant.swift:12:34: error: cannot find 'x' in scope
        """

        let failure = BuildClassifier.failure(from: result(stderr: stderr), command: command())

        #expect(failure.kind == .compilationError)
        #expect(failure.diagnosis.contains("Mutant.swift:12:34: error: cannot find 'x' in scope"))
        #expect(!failure.diagnosis.contains("emit-module"))
    }

    @Test("Incomplete output never quotes a tool error line")
    func incompleteOutputKeepsTheCaptureGuard() {
        let stderr = "error: the package at '/tmp/x' cannot be accessed\n"

        let failure = BuildClassifier.failure(from: result(stderr: stderr, complete: false), command: command())

        #expect(failure.kind == .infrastructure)
        #expect(failure.diagnosis.contains("could not be fully captured"))
        #expect(!failure.diagnosis.contains("cannot be accessed"))
    }
}
