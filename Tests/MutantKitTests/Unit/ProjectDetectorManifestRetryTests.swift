@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Real CI evidence (2026-09-12, `swift-package-ios` acceptance leg under
/// extreme resource pressure — available memory ~1.8GB, system load ~211 on
/// 3 cores): `swift package dump-package` reached `ProjectDetector` with a
/// non-zero exit and an *empty* stderr, indistinguishable from a genuine
/// "manifest is broken" failure without checking `outputComplete` first —
/// the same incident shape `ProcessResult.outputComplete`'s own doc comment
/// already names for `simctl uninstall`. `ProjectDetector.declaredPlatforms`
/// had no `outputComplete` check at all before this fix, unlike every other
/// documented consumer of that field.
///
/// Hand-constructed `ProcessResult`s, not a real subprocess: the same
/// rationale as `BuildClassifierOutputCompletenessTests` — `outputComplete`'s
/// only job here is to gate a retry, so a directly built result with the
/// field forced exercises the exact branch without reproducing the real
/// drain-timeout condition itself (already proven real and deterministic by
/// `ForcedIncompleteOutputFixture`/`ProcessSupervisorOutputCompletenessTests`).
@Suite("ProjectDetector: retries a truncated manifest read once before failing")
struct ProjectDetectorManifestRetryTests {
    private func incompleteResult() -> ProcessResult {
        ProcessResult(
            exitCode: 1,
            standardOutput: Data(),
            standardError: Data(),
            durationSeconds: 0.1,
            timedOut: false,
            terminatingSignal: nil,
            outputComplete: false
        )
    }

    private func successResult(platformsJSON: String) -> ProcessResult {
        ProcessResult(
            exitCode: 0,
            standardOutput: Data(platformsJSON.utf8),
            standardError: Data(),
            durationSeconds: 0.1,
            timedOut: false,
            terminatingSignal: nil,
            outputComplete: true
        )
    }

    @Test("A single truncated capture is retried, and a subsequent real success is used")
    func retriesOnceAfterTruncatedCapture() async throws {
        let noPlatforms = successResult(platformsJSON: "{}")
        let incomplete = incompleteResult()
        let tracker = CallCountTracker()
        let runner: ProcessRunner = { _, _, _, _ in
            let count = await tracker.increment()
            return count == 1 ? incomplete : noPlatforms
        }

        let platforms = try await ProjectDetector.declaredPlatforms(
            in: FileManager.default.temporaryDirectory, timeoutSeconds: 5, processRunner: runner
        )

        #expect(platforms.isEmpty)
        await #expect(tracker.count == 2)
    }

    @Test("Two consecutive truncated captures fail closed, naming truncation rather than a generic manifest error")
    func failsClosedAfterTwoTruncatedCaptures() async throws {
        let incomplete = incompleteResult()
        let tracker = CallCountTracker()
        let runner: ProcessRunner = { _, _, _, _ in
            _ = await tracker.increment()
            return incomplete
        }

        await #expect(throws: ProjectDetectionError.self) {
            _ = try await ProjectDetector.declaredPlatforms(
                in: FileManager.default.temporaryDirectory, timeoutSeconds: 5, processRunner: runner
            )
        }
        await #expect(tracker.count == 2)
    }

    @Test("A genuine (fully-captured) failure is never retried")
    func genuineFailureIsNotRetried() async throws {
        let genuineFailure = ProcessResult(
            exitCode: 1,
            standardOutput: Data(),
            standardError: Data("error: manifest parse error".utf8),
            durationSeconds: 0.1,
            timedOut: false,
            terminatingSignal: nil,
            outputComplete: true
        )
        let tracker = CallCountTracker()
        let runner: ProcessRunner = { _, _, _, _ in
            _ = await tracker.increment()
            return genuineFailure
        }

        await #expect(throws: ProjectDetectionError.self) {
            _ = try await ProjectDetector.declaredPlatforms(
                in: FileManager.default.temporaryDirectory, timeoutSeconds: 5, processRunner: runner
            )
        }
        await #expect(tracker.count == 1)
    }
}

/// Counts `processRunner` invocations without the data race a plain `var`
/// capture in a `@Sendable` closure would create — mirrors
/// `ToolchainCacheIdentityCompletenessTests`'s own `CallTracker`.
private actor CallCountTracker {
    private(set) var count = 0
    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}
