import Foundation
import MutationExecution
import MutationModel

/// Decides whether a failed build means "this mutant is not valid Swift" or
/// "this machine cannot build anything".
///
/// The distinction decides a mutant's fate, so it is drawn from evidence rather
/// than from the exit code. `xcodebuild` and `swift build` both exit non-zero for
/// a syntax error, a full disk, an expired certificate and a missing simulator
/// alike. Calling all of those `.compilationError` would quietly relabel a broken
/// machine as a directory full of unviable mutants and report a clean run.
enum BuildClassifier {
    /// Markers that only a compiler frontend emits.
    ///
    /// Matched against `file.swift:12:34: error:` rather than the bare word
    /// "error", because `xcodebuild: error:` and `** BUILD FAILED **` are the
    /// tool talking about itself, not a diagnostic about the source.
    private static let diagnosticPattern = try? NSRegularExpression(
        pattern: #"^.*\.(?:swift|h|m|mm|c|cpp):\d+:\d+:\s*(?:error|fatal error):"#,
        options: [.anchorsMatchLines]
    )

    /// Failures that are never a mutant's fault, matched on the phrases the
    /// tools actually print.
    private static let infrastructureMarkers = [
        "no space left on device",
        "device is full",
        "code signing",
        "code sign error",
        "no certificate",
        "provisioning profile",
        "unable to find a destination",
        "does not contain a scheme",
        "unable to boot",
        "simulator device failed",
        "could not find developer disk image",
        "xcode-select",
        "no such module 'xctest'",
        "sdk not found",
        "toolchain",
        "permission denied",
        "resource temporarily unavailable"
    ]

    static func failure(from result: ProcessResult, command: CommandRecord) -> BuildFailure {
        let output = result.combinedOutput
        let redacted = OutputRedactor.redactAndTruncate(output)

        if result.timedOut {
            return BuildFailure(
                kind: .timedOut,
                diagnosis: """
                The build exceeded its time limit and was terminated after \
                \(String(format: "%.1f", result.durationSeconds))s.
                """,
                command: command,
                output: redacted
            )
        }

        // Checked before any marker/diagnostic search below: those searches
        // treat "the marker is absent" as meaningful evidence ("not an
        // infrastructure failure", "not a compiler error"), which only holds
        // if `output` is actually everything the build wrote. Truncated
        // output can omit the very diagnostic or marker that would have
        // explained the failure, making a real compiler error read as an
        // unattributable one, or worse, letting a truncated-but-coincidental
        // string match invent a classification from partial evidence — see
        // `ProcessResult.outputComplete`'s own doc comment for the real
        // incident this guards against. `.infrastructure`, never
        // `.compilationError`: this is a statement that the evidence cannot
        // be trusted, not a claim that the mutated source is fine.
        guard result.outputComplete else {
            return BuildFailure(
                kind: .infrastructure,
                diagnosis: """
                The build's output could not be fully captured before the subprocess exited, so the \
                actual failure reason cannot be reliably determined. No mutant can be scored from this build.
                """,
                command: command,
                output: redacted
            )
        }

        let haystack = output.lowercased()

        // Checked before compiler diagnostics: a failing build prints cascading
        // errors after the real cause, and the real cause is what decides the kind.
        if let marker = infrastructureMarkers.first(where: haystack.contains) {
            return BuildFailure(
                kind: .infrastructure,
                diagnosis: """
                The build failed for an environment reason ("\(marker)"), not because \
                of the mutated source. No mutant can be scored from this build.
                """,
                command: command,
                output: redacted
            )
        }

        if let diagnostic = firstDiagnostic(in: output) {
            return BuildFailure(
                kind: .compilationError,
                diagnosis: "The mutated source does not compile: \(diagnostic)",
                command: command,
                output: redacted
            )
        }

        // Non-zero, but nothing identifies it as a compile error. Reporting this as
        // `.compilationError` would invent a fact about the mutant; `.infrastructure`
        // only claims that the build is unusable, which is all that is known.
        return BuildFailure(
            kind: .infrastructure,
            diagnosis: """
            The build exited with \(result.exitCode) but produced no compiler \
            diagnostic, so the failure cannot be attributed to the mutated source.
            """,
            command: command,
            output: redacted
        )
    }

    /// The first real compiler diagnostic line, for the diagnosis sentence.
    static func firstDiagnostic(in output: String) -> String? {
        guard let diagnosticPattern else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = diagnosticPattern.firstMatch(in: output, range: range),
              let matched = Range(match.range, in: output)
        else { return nil }

        // The message continues past the `error:` marker to the end of the line.
        let lineEnd = output[matched.lowerBound...].firstIndex(of: "\n") ?? output.endIndex
        return String(output[matched.lowerBound ..< lineEnd])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whether the output carries any compiler diagnostic at all.
    static func containsCompilerDiagnostics(_ output: String) -> Bool {
        firstDiagnostic(in: output) != nil
    }
}
