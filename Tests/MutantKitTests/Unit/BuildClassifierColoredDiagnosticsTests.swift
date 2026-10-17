@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Xcode 27's `swift build` colors compiler diagnostics even when its output is a pipe, so the line
/// `file.swift:12:34: error: ...` arrives with escape sequences between the pieces. A compile-invalid mutant
/// must still classify as a compilation error, and a failure with no diagnostic must stay unattributable.
@Suite("BuildClassifier: colored compiler diagnostics")
struct BuildClassifierColoredDiagnosticsTests {
    private func failure(_ output: String) -> BuildFailure {
        let result = ProcessResult(
            exitCode: 1, standardOutput: Data(output.utf8), standardError: Data(), durationSeconds: 1, timedOut: false,
            terminatingSignal: nil, outputComplete: true
        )
        return BuildClassifier.failure(
            from: result, command: CommandRecord(executable: "xcrun", arguments: ["swift", "build"], workingDirectory: "/tmp")
        )
    }

    @Test("a diagnostic printed with ANSI colors is a compilation error and names the real message")
    func coloredDiagnosticIsCompilationError() {
        let output = "/p/ArgumentDecoder.swift:122:30: \u{1B}[1;31merror: \u{1B}[1;39mbinary operator '-' "
            + "cannot be applied to two '[any CodingKey]' operands\u{1B}[0;0m\n"
        let result = failure(output)
        #expect(result.kind == .compilationError)
        #expect(result.diagnosis.contains("binary operator '-' cannot be applied"))
        #expect(!result.diagnosis.contains("\u{1B}"))
    }

    /// An error inside a macro expansion carries no file name, only `macro expansion @Name:L:C:`.
    @Test("an error reported inside a macro expansion is a compilation error")
    func macroExpansionDiagnosticIsCompilationError() {
        let output = """
        error: SwiftCompile normal arm64 /p/CompileTimeTests.swift failed with a nonzero exit code.
        macro expansion @Reducer:23:50: \u{1B}[1;31merror: \u{1B}[1;39mcannot convert return expression of type 'some Reducer<A, B>' to return type 'Reduce<A, B>'\u{1B}[0;0m
        error: Build failed

        """
        let result = failure(output)
        #expect(result.kind == .compilationError)
        #expect(result.diagnosis.contains("cannot convert return expression"))
    }

    @Test("the tool's own error lines mentioning a macro are not a compiler diagnostic")
    func macroMentionWithoutLocationIsNotADiagnostic() {
        #expect(failure("error: macro expansion failed\nerror: Build failed\n").kind == .infrastructure)
    }

    @Test("a colored failure with no compiler diagnostic is still unattributable, not a compilation error")
    func coloredNonDiagnosticIsStillInfrastructure() {
        let result = failure("\u{1B}[1;31merror: \u{1B}[1;39mBuild failed\u{1B}[0;0m\n")
        #expect(result.kind == .infrastructure)
    }

    @Test("an environment failure printed in color is still an environment failure")
    func coloredInfrastructureMarkerIsStillInfrastructure() {
        let result = failure("\u{1B}[1;31merror: \u{1B}[1;39mno space left on device\u{1B}[0;0m\n")
        #expect(result.kind == .infrastructure)
        #expect(result.diagnosis.contains("environment"))
    }

    @Test("stripping leaves plain text and non-CSI bytes alone")
    func strippingIsMinimal() {
        #expect(BuildClassifier.strippingEscapeSequences("plain [1;31m text") == "plain [1;31m text")
        #expect(BuildClassifier.strippingEscapeSequences("a\u{1B}[0;36m|\u{1B}[0;0m b") == "a| b")
    }
}
