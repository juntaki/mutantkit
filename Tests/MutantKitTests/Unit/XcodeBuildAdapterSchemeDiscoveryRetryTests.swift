@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Real CI evidence (2026-09-12, `xcode-project`'s own recurring "No
/// schemes are available here" flake, reproduced with the identical
/// signature 4 times): `discoverSchemes`'s underlying
/// `xcodebuild -list -json` call reported zero schemes for a project
/// whose shared scheme a *separate*, immediately preceding poll of the
/// identical invocation had just confirmed visible. `xcodebuild`'s own
/// scheme-visibility state can genuinely flicker under real resource
/// pressure — a real robustness gap for any user on a loaded machine, not
/// only a CI artifact.
///
/// Scripted `ProcessRunner`, no real `xcodebuild` involved: the property
/// under test is the retry *policy* itself (retry a clean empty result,
/// never a timeout or crash), which does not need reproducing the real
/// flicker condition to pin — the same rationale
/// `XcodeBuildAdapterUninstallFailureTests` already gives for its own
/// scripted doubles.
@Suite("XcodeBuildAdapter.discoverSchemes: retries a clean empty result")
struct XcodeBuildAdapterSchemeDiscoveryRetryTests {
    private func adapter(processRunner: @escaping ProcessRunner) -> XcodeBuildAdapter {
        let root = FileManager.default.temporaryDirectory
        return XcodeBuildAdapter(
            configuration: Configuration(),
            kind: .xcodeProject,
            projectFile: nil,
            projectRoot: root,
            resolvedDestination: nil,
            simulators: SimulatorPool(workingDirectory: root),
            processRunner: processRunner
        )
    }

    private func result(schemes: [String]?) -> ProcessResult {
        let json = if let schemes {
            Data("{\"project\":{\"name\":\"Demo\",\"schemes\":\(schemes)}}".utf8)
        } else {
            Data("{\"project\":{\"name\":\"Demo\",\"schemes\":[]}}".utf8)
        }
        return ProcessResult(
            exitCode: 0, standardOutput: json, standardError: Data(),
            durationSeconds: 0.1, timedOut: false, terminatingSignal: nil, outputComplete: true
        )
    }

    private actor CallCountTracker {
        private(set) var count = 0
        @discardableResult
        func increment() -> Int {
            count += 1
            return count
        }
    }

    @Test("A clean empty result on the first call is retried, and a subsequent non-empty result is used")
    func retriesOnceAfterCleanEmptyResult() async {
        let tracker = CallCountTracker()
        let empty = result(schemes: [])
        let found = result(schemes: ["MatrixEvidenceLib"])
        let runner: ProcessRunner = { _, _, _, _ in
            let count = await tracker.increment()
            return count == 1 ? empty : found
        }

        let schemes = await adapter(processRunner: runner).discoverSchemes(in: FileManager.default.temporaryDirectory)

        #expect(schemes == ["MatrixEvidenceLib"])
        await #expect(tracker.count == 2)
    }

    @Test("A clean empty result on every attempt gives up after emptyResultRetryCount retries, not before")
    func givesUpAfterConfiguredRetryCount() async {
        let tracker = CallCountTracker()
        let empty = result(schemes: [])
        let runner: ProcessRunner = { _, _, _, _ in
            _ = await tracker.increment()
            return empty
        }

        let schemes = await adapter(processRunner: runner)
            .discoverSchemes(in: FileManager.default.temporaryDirectory, emptyResultRetryCount: 2)

        #expect(schemes.isEmpty)
        await #expect(tracker.count == 3, "1 initial attempt + 2 retries = 3 total calls")
    }

    @Test("A genuine process failure is never retried")
    func genuineFailureIsNotRetried() async {
        let tracker = CallCountTracker()
        let failure = ProcessResult(
            exitCode: 1, standardOutput: Data(), standardError: Data("xcodebuild: error: ...".utf8),
            durationSeconds: 0.1, timedOut: false, terminatingSignal: nil, outputComplete: true
        )
        let runner: ProcessRunner = { _, _, _, _ in
            _ = await tracker.increment()
            return failure
        }

        let schemes = await adapter(processRunner: runner).discoverSchemes(in: FileManager.default.temporaryDirectory)

        #expect(schemes.isEmpty)
        await #expect(tracker.count == 1)
    }
}
