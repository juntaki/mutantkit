import Foundation
@testable import MutationModel
import Testing

/// A second compiler crash confirms the first only when it is the same crash. The signature keeps what
/// identifies a crash (the signal, what the compiler was processing, its top frames) and drops what
/// differs between two runs of the same crash (addresses, offsets, the sandbox directory).
@Suite("CompilerCrashSignature")
struct CompilerCrashSignatureTests {
    private func crash(
        sandbox: String = "/tmp/run-1", address: String = "0x0000000105a7fb84", offset: Int = 528,
        context: String = "While type-checking declaration 'f' at SOURCE:3:5", topFrame: String = "swift::TypeChecker::checkBody",
        signal: String = "Segmentation fault: 11"
    ) -> String {
        let contextLine = context.replacingOccurrences(of: "SOURCE", with: "\(sandbox)/Sources/A.swift")
        return """
        \(signal)
        Stack dump:
        0.\tProgram arguments: /usr/bin/swift-frontend -frontend -c \(sandbox)/Sources/A.swift
        1.\tApple Swift version 6.3
        2.\t\(contextLine)
        Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace.
        0  swift-frontend           \(address) llvm::sys::PrintStackTrace(llvm::raw_ostream&, int) + 40
        1  swift-frontend           \(address) SignalHandler(int) + 392
        2  libsystem_platform.dylib 0x000000019cbec144 _sigtramp + 56
        3  swift-frontend           \(address) \(topFrame)(swift::Decl*) + \(offset)
        4  swift-frontend           \(address) swift::TypeChecker::typeCheckDecl(swift::Decl*) + 96
        """
    }

    @Test("the same crash in another sandbox, at other addresses and offsets, has the same signature")
    func sameCrashIsEqual() throws {
        let first = try #require(CompilerCrashSignature(output: crash()))
        let second = try #require(CompilerCrashSignature(output: crash(sandbox: "/var/run-2", address: "0x00000001099a0000", offset: 64)))
        #expect(first == second)
    }

    @Test("the printing and signal-handler frames are not part of the signature")
    func noiseFramesAreSkipped() throws {
        let signature = try #require(CompilerCrashSignature(output: crash()))
        #expect(signature.frames.first == "swift::TypeChecker::checkBody(swift::Decl*)")
        #expect(signature.frames.count == 2)
        #expect(signature.context == ["While type-checking declaration 'f' at A.swift:3:5"])
        #expect(signature.signal == "Segmentation fault")
    }

    @Test("a crash in another compiler frame is a different crash")
    func differentFrameIsDifferent() throws {
        let first = try #require(CompilerCrashSignature(output: crash()))
        let other = try #require(CompilerCrashSignature(output: crash(topFrame: "swift::SILGen::emitApply")))
        #expect(first != other)
    }

    @Test("a crash while processing something else is a different crash")
    func differentContextIsDifferent() throws {
        let first = try #require(CompilerCrashSignature(output: crash()))
        let other = try #require(CompilerCrashSignature(output: crash(context: "While type-checking declaration 'g' at SOURCE:9:1")))
        #expect(first != other)
    }

    @Test("a crash with another signal is a different crash")
    func differentSignalIsDifferent() throws {
        let first = try #require(CompilerCrashSignature(output: crash()))
        let other = try #require(CompilerCrashSignature(output: crash(signal: "Abort trap: 6")))
        #expect(first != other)
        #expect(other.signal == "Abort trap")
    }

    @Test("output with neither a compiler frame nor a While line has no signature, so it can never be confirmed")
    func unidentifiableOutputHasNoSignature() {
        let bannerOnly = "Stack dump:\nPlease submit a bug report\n3  libsystem_platform.dylib 0x1 _sigtramp + 56\n"
        #expect(CompilerCrashSignature(output: bannerOnly) == nil)
        #expect(CompilerCrashSignature(output: "") == nil)
    }
}
