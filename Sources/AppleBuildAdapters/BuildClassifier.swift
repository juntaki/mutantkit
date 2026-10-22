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
    /// tool talking about itself, not a diagnostic about the source. An error
    /// inside a macro expansion has no file name and is printed as
    /// `macro expansion @Reducer:23:50: error:`.
    private static let diagnosticPattern = try? NSRegularExpression(
        pattern: #"^(?:.*\.(?:swift|h|m|mm|c|cpp)|macro expansion @[^:\n]+):\d+:\d+:\s*(?:error|fatal error):"#,
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
        // Specific phrasings only: a bare "toolchain" appears in ordinary build output (environment
        // dumps, `DT_TOOLCHAIN_DIR`, paths under `XcodeDefault.xctoolchain`) and, matched ahead of the
        // compiler diagnostics, would relabel a real compile error as an environment failure.
        "toolchain not found",
        "no such toolchain",
        "unable to find toolchain",
        "unable to locate toolchain",
        "failed to load toolchain",
        "could not find toolchain",
        "permission denied",
        "resource temporarily unavailable"
    ]

    /// ANSI CSI escape sequences (`ESC [ ... final byte`). Xcode 27's `swift build` passes
    /// `-color-diagnostics` to the frontend even when its output is a pipe, so a diagnostic arrives as
    /// `file.swift:12:34: ␛[1;31merror: ␛[1;39m...`, which no marker search would otherwise see.
    private static let escapeSequences = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    static func strippingEscapeSequences(_ text: String) -> String {
        guard let escapeSequences, text.contains("\u{1B}") else { return text }
        return escapeSequences.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
    }

    static func failure(from result: ProcessResult, command: CommandRecord) -> BuildFailure {
        let output = strippingEscapeSequences(result.combinedOutput)
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

        // The compiler process itself died: no diagnostic, but a crash banner and a stack dump. This is
        // only a candidate (see `BuildFailure.isCompilerCrashCandidate`); the classifier cannot show that
        // the crash is reproducible, so the kind stays `.infrastructure`.
        if isCompilerCrash(output) {
            return BuildFailure(
                kind: .infrastructure,
                diagnosis: """
                The build exited with \(result.exitCode) because a Swift compiler process crashed (stack dump \
                in the output) without a compiler diagnostic. A single crash does not show whether the mutated \
                source or the machine is at fault.
                """,
                command: command,
                output: redacted,
                isCompilerCrashCandidate: true,
                compilerCrashSignature: CompilerCrashSignature(output: output)
            )
        }

        return unattributedFailure(exitCode: result.exitCode, output: output, redacted: redacted, command: command)
    }

    /// Non-zero, but nothing identifies it as a compile error. Reporting this as
    /// `.compilationError` would invent a fact about the mutant; `.infrastructure`
    /// only claims that the build is unusable, which is all that is known.
    /// The tool's own error line is quoted when there is one, because it is
    /// usually the whole explanation (e.g. a local package SwiftPM cannot
    /// reach); it never changes the kind.
    private static func unattributedFailure(
        exitCode: Int32, output: String, redacted: String, command: CommandRecord
    ) -> BuildFailure {
        if let toolError = firstToolError(in: output) {
            return BuildFailure(
                kind: .infrastructure,
                diagnosis: """
                The build exited with \(exitCode) before compilation; the build tool reported:

                \(toolError)

                The failure cannot be attributed to the mutated source.
                """,
                command: command,
                output: redacted
            )
        }
        return BuildFailure(
            kind: .infrastructure,
            diagnosis: """
            The build exited with \(exitCode) but produced no compiler \
            diagnostic, so the failure cannot be attributed to the mutated source.
            """,
            command: command,
            output: redacted
        )
    }

    /// Whether the output shows a Swift compiler process crashing: its crash banner, a stack dump that
    /// contains compiler (`swift-frontend` / `swift-driver`) frames, and evidence that a signal was
    /// delivered (the signal-handler frame or a signal name). Deliberately all three: the banner alone is
    /// also printed for plain assertion output, and a bare "Stack dump" can come from any tool.
    static func isCompilerCrash(_ output: String) -> Bool {
        guard output.contains("Please submit a bug report"), output.contains("Stack dump:") else { return false }
        guard output.contains("swift-frontend") || output.contains("swift-driver") else { return false }
        let signals = ["_sigtramp", "Segmentation fault", "Illegal instruction", "Abort trap", "Bus error"]
        return signals.contains(where: output.contains)
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

    /// Longest tool error line quoted in a diagnosis, in characters.
    static let toolErrorLengthLimit = 300

    /// The first line that is a build tool's own error rather than a compiler
    /// diagnostic: it starts with `error: `, so it carries no `file:line:col`.
    /// Redacted, home-abbreviated and capped, because it lands verbatim in reports.
    static func firstToolError(in output: String) -> String? {
        guard let line = output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("error: ") })
        else { return nil }

        let cleaned = OutputRedactor.abbreviatingHomeDirectory(
            OutputRedactor.redact(String(line).trimmingCharacters(in: .whitespaces))
        )
        guard cleaned.count > toolErrorLengthLimit else { return cleaned }
        return String(cleaned.prefix(toolErrorLengthLimit)) + "…"
    }

    /// Whether the output carries any compiler diagnostic at all.
    static func containsCompilerDiagnostics(_ output: String) -> Bool {
        firstDiagnostic(in: output) != nil
    }
}
