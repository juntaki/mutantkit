@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// A mutant can make `swift-frontend` itself crash. The output then has no `file.swift:L:C: error:`
/// line, only the compiler's crash banner and a stack dump. That is a candidate for an unbuildable mutant,
/// never a proven one: the classifier keeps it an infrastructure failure and only flags it, and a failure
/// that has a diagnostic or an environment marker is never a candidate.
@Suite("BuildClassifier: compiler crashes")
struct BuildClassifierCompilerCrashTests {
    static let crashOutput = """
    Stack dump:
    0.\tProgram arguments: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c
    1.\tApple Swift version 6.3 (swiftlang-6.3.0.1 clang-2100.0.1)
    Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace.
    3  libsystem_platform.dylib 0x000000019cbec144 _sigtramp + 56
    4  swift-frontend           0x0000000105a7fb84 swift::Lowering::SILGenFunction::emitApplyExpr(swift::ApplyExpr*) + 528
    error: Build failed

    """

    private func failure(_ output: String, complete: Bool = true) -> BuildFailure {
        let result = ProcessResult(
            exitCode: 1, standardOutput: Data(output.utf8), standardError: Data(), durationSeconds: 1, timedOut: false,
            terminatingSignal: nil, outputComplete: complete
        )
        return BuildClassifier.failure(
            from: result, command: CommandRecord(executable: "xcrun", arguments: ["swift", "build"], workingDirectory: "/tmp")
        )
    }

    @Test("a compiler crash with no diagnostic is an infrastructure failure flagged as a crash candidate")
    func crashIsOnlyACandidate() {
        let result = failure(Self.crashOutput)
        #expect(result.kind == .infrastructure)
        #expect(result.isCompilerCrashCandidate)
    }

    @Test("a real diagnostic wins: it is a compilation error, not a crash candidate")
    func diagnosticWinsOverCrash() {
        let result = failure("/p/A.swift:3:5: error: cannot find 'x' in scope\n" + Self.crashOutput)
        #expect(result.kind == .compilationError)
        #expect(!result.isCompilerCrashCandidate)
    }

    @Test("an environment marker is never a crash candidate")
    func environmentMarkerIsNotACandidate() {
        let result = failure("error: no space left on device\n" + Self.crashOutput)
        #expect(result.kind == .infrastructure)
        #expect(!result.isCompilerCrashCandidate)
    }

    @Test("incomplete output is never a crash candidate")
    func incompleteOutputIsNotACandidate() {
        #expect(!failure(Self.crashOutput, complete: false).isCompilerCrashCandidate)
    }

    @Test("a crash banner without compiler frames or a signal is not enough")
    func partialSignatureIsNotACandidate() {
        #expect(!failure("Stack dump:\nPlease submit a bug report\nerror: Build failed\n").isCompilerCrashCandidate)
        let noSignal = Self.crashOutput.replacingOccurrences(of: "_sigtramp", with: "main")
        #expect(!failure(noSignal).isCompilerCrashCandidate)
    }

    @Test("a failure with no diagnostic and no crash is a plain, unflagged infrastructure failure")
    func plainFailureIsNotACandidate() {
        let result = failure("error: Build failed\n")
        #expect(result.kind == .infrastructure)
        #expect(!result.isCompilerCrashCandidate)
    }

    @Test("a colored crash is recognised too")
    func coloredCrashIsACandidate() {
        let colored = Self.crashOutput.replacingOccurrences(
            of: "error: Build failed", with: "\u{1B}[1;31merror: \u{1B}[1;39mBuild failed\u{1B}[0;0m"
        )
        #expect(failure(colored).isCompilerCrashCandidate)
    }
}
