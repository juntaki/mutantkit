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

    // MARK: - resolveScheme: real diagnostics on failure (2026-09-14)

    /// `resolveScheme` used to pass `result: nil` unconditionally into its
    /// thrown `BuildFailure`, so a "no schemes" failure's own `command`/
    /// `output` were always empty regardless of what `xcodebuild` actually
    /// returned — indistinguishable from a genuine process failure in the
    /// failure's own diagnosis. It now threads the real last `ProcessResult`
    /// through, so a caller reading the thrown error sees the real exit
    /// code and combined stdout/stderr.
    @Test("resolveScheme on a failed discovery throws with the real exit code and combined output, not nil/empty")
    func resolveSchemeWithZeroSchemesCarriesRealDiagnostics() async throws {
        let failure = ProcessResult(
            exitCode: 66, standardOutput: Data("{\"project\":{\"name\":\"Demo\",\"schemes\":[]}}".utf8),
            standardError: Data("xcodebuild: note: transient scheme cache miss".utf8),
            durationSeconds: 0.2, timedOut: false, terminatingSignal: nil, outputComplete: true
        )
        let runner: ProcessRunner = { _, _, _, _ in failure }

        do {
            _ = try await adapter(processRunner: runner).resolveScheme(in: FileManager.default.temporaryDirectory)
            Issue.record("expected resolveScheme to throw")
        } catch let error as BuildFailure {
            #expect(error.command.exitCode == 66)
            #expect(error.output.contains("transient scheme cache miss"))
        }
    }

    @Test("resolveScheme with more than one scheme throws with the real exit code and combined output")
    func resolveSchemeWithMultipleSchemesCarriesRealDiagnostics() async throws {
        let success = result(schemes: ["A", "B"])
        let runner: ProcessRunner = { _, _, _, _ in success }

        do {
            _ = try await adapter(processRunner: runner).resolveScheme(in: FileManager.default.temporaryDirectory)
            Issue.record("expected resolveScheme to throw")
        } catch let error as BuildFailure {
            #expect(error.command.exitCode == 0)
            #expect(error.output.contains("\"A\""))
        }
    }

    // MARK: - An unanswered question is not an answer of "none" (2026-09-19)

    /// The real CI failure `SchemeResolutionDiagnosis` was written for:
    /// `xcodebuild -list -json` killed at its own 120-second budget, output
    /// empty, reported to the user as "No schemes are available here. Open
    /// the project in Xcode and mark a scheme shared" — a claim about the
    /// user's project that the evidence in hand positively did not support.
    @Test("A discovery killed at its timeout is not reported as the project having no schemes")
    func timedOutDiscoveryIsNotReportedAsNoSchemes() async throws {
        let killed = ProcessResult(
            exitCode: 143, standardOutput: Data(), standardError: Data(),
            durationSeconds: 120.056, timedOut: true, terminatingSignal: 15, outputComplete: false
        )
        let runner: ProcessRunner = { _, _, _, _ in killed }

        do {
            _ = try await adapter(processRunner: runner).resolveScheme(in: FileManager.default.temporaryDirectory)
            Issue.record("expected resolveScheme to throw")
        } catch let error as BuildFailure {
            #expect(!error.diagnosis.contains("No schemes are available here"))
            #expect(error.diagnosis.contains("killed after 120.1s"))
            #expect(error.diagnosis.contains("120.0s budget"))
            #expect(error.diagnosis.contains("still unknown"))
        }
    }

    /// The other half, and the reason this is a split rather than a
    /// softening: a project that genuinely has no shared scheme must still
    /// be told so, with the remedy that actually fixes it.
    @Test("A discovery that really did answer 'none' keeps the original diagnosis")
    func answeredEmptyDiscoveryKeepsNoSchemesDiagnosis() async throws {
        let empty = result(schemes: [])
        let runner: ProcessRunner = { _, _, _, _ in empty }

        do {
            _ = try await adapter(processRunner: runner).resolveScheme(in: FileManager.default.temporaryDirectory)
            Issue.record("expected resolveScheme to throw")
        } catch let error as BuildFailure {
            #expect(error.diagnosis.contains("No schemes are available here"))
            #expect(error.diagnosis.contains("mark a scheme shared"))
        }
    }

    /// `ProcessResult.outputComplete`'s own contract: a consumer deriving a
    /// failure classification from a result must fail closed when the
    /// supervisor could not confirm it had drained the process's output.
    /// "This project has no schemes" is exactly such a classification, and
    /// it was being read straight out of possibly-truncated bytes.
    @Test("A clean exit whose output was never confirmed complete is not an answer of 'none'")
    func incompleteOutputIsNotReportedAsNoSchemes() async throws {
        let truncated = ProcessResult(
            exitCode: 0, standardOutput: Data(), standardError: Data(),
            durationSeconds: 0.3, timedOut: false, terminatingSignal: nil, outputComplete: false
        )
        let tracker = CallCountTracker()
        let runner: ProcessRunner = { _, _, _, _ in
            _ = await tracker.increment()
            return truncated
        }

        do {
            _ = try await adapter(processRunner: runner).resolveScheme(in: FileManager.default.temporaryDirectory)
            Issue.record("expected resolveScheme to throw")
        } catch let error as BuildFailure {
            #expect(!error.diagnosis.contains("No schemes are available here"))
            #expect(error.diagnosis.contains("never confirmed complete"))
        }
        await #expect(tracker.count == 1, "an unconfirmed empty result is not the clean empty result the retry is for")
    }

    /// A discovery that could not be started at all — `processRunner` itself
    /// threw, so there is no `ProcessResult` to reason from. Still not a
    /// statement about the project.
    @Test("A discovery that never ran points at the toolchain, not at the project's schemes")
    func unstartedDiscoveryPointsAtTheToolchain() async throws {
        struct SpawnFailure: Error {}
        let runner: ProcessRunner = { _, _, _, _ in throw SpawnFailure() }

        do {
            _ = try await adapter(processRunner: runner).resolveScheme(in: FileManager.default.temporaryDirectory)
            Issue.record("expected resolveScheme to throw")
        } catch let error as BuildFailure {
            #expect(!error.diagnosis.contains("No schemes are available here"))
            #expect(error.diagnosis.contains("xcode-select -p"))
        }
    }

    /// A non-zero exit that is not a signal and not a timeout: `xcodebuild`
    /// ran, refused, and said why. The remedy is to read what it said.
    @Test("A non-zero exit reports the status and points at the command's own output")
    func failedExitReportsStatusAndOutput() async throws {
        let refused = ProcessResult(
            exitCode: 66, standardOutput: Data(), standardError: Data("xcodebuild: error: no project".utf8),
            durationSeconds: 0.4, timedOut: false, terminatingSignal: nil, outputComplete: true
        )
        let runner: ProcessRunner = { _, _, _, _ in refused }

        do {
            _ = try await adapter(processRunner: runner).resolveScheme(in: FileManager.default.temporaryDirectory)
            Issue.record("expected resolveScheme to throw")
        } catch let error as BuildFailure {
            #expect(!error.diagnosis.contains("No schemes are available here"))
            #expect(error.diagnosis.contains("exited with status 66"))
            #expect(error.output.contains("no project"))
        }
    }
}
