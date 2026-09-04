@testable import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// Fast, no-subprocess coverage for `SwiftPackageMacOSAdapter
/// .isLikelySharedModuleCacheCorruption` — the guard deciding whether a
/// failed shared-module-cache build gets one delete-and-retry, or is
/// reported as a real build failure. Real, end-to-end proof that the
/// underlying reproduction this heuristic is built from actually happens
/// against a live toolchain lives in `SharedModuleCacheTests` (Acceptance);
/// this pins the decision function itself against hand-built fixtures so
/// the safety-critical branches — a real compile error must never be
/// retried, a real hang must never be retried, only cache-implicated
/// infrastructure failures ever are — stay pinned without spawning `swift
/// build` for every case.
@Suite("SwiftPackageMacOSAdapter: shared module cache corruption-recovery heuristic")
struct SwiftPackageMacOSAdapterSharedCacheRecoveryTests {
    private static let cachePath = URL(fileURLWithPath: "/tmp/example-scratch-root/.module-cache-deadbeefcafef00d")

    private static func failure(
        kind: BuildFailureKind,
        output: String
    ) -> BuildFailure {
        BuildFailure(
            kind: kind,
            diagnosis: "diagnosis text unrelated to the check itself",
            command: CommandRecord(executable: "/usr/bin/xcrun", arguments: ["swift", "build"], workingDirectory: "/tmp"),
            output: output
        )
    }

    @Test("A real compile error is NEVER treated as cache corruption, even if its output happened to mention the cache path")
    func compilationErrorIsNeverRetried() {
        // Adversarial: even handing the guard the one string it looks for,
        // a `.compilationError` must still refuse — the kind check has to
        // come first and be unconditional, never merely "usually excluded".
        let output = "Sources/Calc/Calc.swift:3:59: error: cannot find operator '+++' in scope\nmentions \(Self.cachePath.path) too"
        let result = SwiftPackageMacOSAdapter.isLikelySharedModuleCacheCorruption(
            Self.failure(kind: .compilationError, output: output), cachePath: Self.cachePath
        )
        #expect(result == false)
    }

    @Test("A genuine compile error's real output (reproduced live) never mentions the cache path either")
    func realCompileErrorOutputNeverMentionsCachePath() {
        // Captured live, this task's own investigation: `swift build` under
        // `-Xswiftc -module-cache-path -Xswiftc <path>` against a source
        // file with a genuine syntax error.
        let realOutput = """
        Building for debugging...
        [7/9] Compiling Calc Calc.swift
        /path/to/fixture/Sources/Calc/Calc.swift:3:59: error: cannot find operator '+++' in scope
        1 | public struct Calc {
        2 |     public init() {}
        3 |     public func add(_ a: Int, _ b: Int) -> Int { return a +++ b }
          |                                                           `- error: cannot find operator '+++' in scope
        4 | }
        """
        let result = SwiftPackageMacOSAdapter.isLikelySharedModuleCacheCorruption(
            Self.failure(kind: .compilationError, output: realOutput), cachePath: Self.cachePath
        )
        #expect(result == false)
        #expect(!realOutput.contains(Self.cachePath.path))
    }

    @Test("A timeout is never retried, even if the (impossible in practice) output happened to mention the cache path")
    func timedOutIsNeverRetried() {
        let output = "the build hung; \(Self.cachePath.path) appears here only to prove the kind check dominates"
        let result = SwiftPackageMacOSAdapter.isLikelySharedModuleCacheCorruption(
            Self.failure(kind: .timedOut, output: output), cachePath: Self.cachePath
        )
        #expect(result == false)
    }

    @Test("A generic infrastructure failure unrelated to the cache (e.g. a full disk) is never retried")
    func unrelatedInfrastructureFailureIsNotRetried() {
        let output = "error: no space left on device"
        let result = SwiftPackageMacOSAdapter.isLikelySharedModuleCacheCorruption(
            Self.failure(kind: .infrastructure, output: output), cachePath: Self.cachePath
        )
        #expect(result == false)
    }

    @Test("An infrastructure failure whose output names this build's own cache path IS treated as cache corruption")
    func cacheImplicatedInfrastructureFailureIsRetried() {
        // Real shape reproduced live: making the resolved cache directory
        // unwritable before a cold build fails with exactly this kind of
        // diagnostic, naming the cache path verbatim.
        let output = """
        <unknown>:0: error: error opening '\(Self.cachePath.path)/Swift-3HU3Q7STZFO0T.swiftmodule' for output: \
        \(Self.cachePath.path)/Swift-3HU3Q7STZFO0T.swiftmodule: Permission denied
        <unknown>:0: error: unable to load standard library for target 'arm64-apple-macosx10.13'
        """
        let result = SwiftPackageMacOSAdapter.isLikelySharedModuleCacheCorruption(
            Self.failure(kind: .infrastructure, output: output), cachePath: Self.cachePath
        )
        #expect(result == true)
    }

    @Test("An infrastructure failure that mentions some OTHER path, not this build's own resolved cache path, is not retried")
    func infrastructureFailureMentioningADifferentPathIsNotRetried() {
        let otherCachePath = URL(fileURLWithPath: "/tmp/some-other-scratch-root/.module-cache-11111111aaaaaaaa")
        let output = "error opening '\(otherCachePath.path)/Foo.pcm' for output: Permission denied"
        let result = SwiftPackageMacOSAdapter.isLikelySharedModuleCacheCorruption(
            Self.failure(kind: .infrastructure, output: output), cachePath: Self.cachePath
        )
        #expect(result == false)
    }

    @Test("A generic swift-frontend crash is never cache corruption, despite its crash report echoing -module-cache-path verbatim")
    func genericFrontendCrashIsNeverRetried() {
        // Real shape reproduced live, the same way the false positive this
        // guard used to have was originally found: `xcrun swift build
        // --build-tests -Xswiftc -module-cache-path -Xswiftc <cachePath>
        // -Xswiftc -Xfrontend -Xswiftc -debug-crash-after-parse` against a
        // trivial SwiftPM fixture. Nothing about this crash has anything to
        // do with the module cache -- `-debug-crash-after-parse` forces the
        // crash unconditionally, right after parsing, before the cache is
        // ever touched -- yet the frontend's own crash report unconditionally
        // echoes its full command line, `-module-cache-path <cachePath>`
        // included, in the `Program arguments:` line below. `BuildClassifier`
        // reaches `.infrastructure` for this output too (no `file.swift:
        // LINE:COL: error:` diagnostic anywhere, so it is not
        // `.compilationError`), which is exactly why the bare-substring
        // version of this guard used to fire here: `cachePath.path` really
        // does appear in `output`. It must not appear inside an `error
        // opening '` diagnostic anywhere, and it does not, so the guard must
        // return `false`.
        let output = """
        error: emit-module command failed due to signal 5 (use -v to see invocation)
        error: compile command failed due to signal 5 (use -v to see invocation)
        Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace.
        Stack dump:
        0.\tProgram arguments: /usr/bin/swift-frontend -frontend -emit-module Sources/Calc/Calc.swift \
        -target arm64-apple-macosx10.13 -module-cache-path \(Self.cachePath.path) -swift-version 5 \
        -debug-crash-after-parse -module-name Calc
        1.\tApple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
        2.\tCompiling with effective version 5.10
        Stack dump without symbol names (ensure you have llvm-symbolizer in your PATH...):
        0  swift-frontend  0x0000000100b946cc performCompile(swift::CompilerInstance&, ...) + 4840
        """
        #expect(output.contains(Self.cachePath.path), "the fixture must actually reproduce the echoed path, or this test proves nothing")
        let result = SwiftPackageMacOSAdapter.isLikelySharedModuleCacheCorruption(
            Self.failure(kind: .infrastructure, output: output), cachePath: Self.cachePath
        )
        #expect(
            result == false,
            "a generic frontend crash must never be classified as cache corruption merely because its crash report echoed the cache path"
        )
    }
}
