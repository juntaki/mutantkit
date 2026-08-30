import Foundation
import MutationExecution

/// Runs one Swift Testing test directly through SwiftPM's own
/// `swiftpm-testing-helper` — bypassing `xcrun swift test`'s own CLI/
/// package-graph layer entirely — with a per-test-unique event stream and
/// `LLVM_PROFILE_FILE`, so per-test coverage attribution no longer needs a
/// full `swift test --skip-build --filter <id>` process per test.
///
/// Every path/mechanism here was confirmed against the real toolchain before
/// being written, not assumed from documentation:
/// - `swiftpm-testing-helper` lives at a fixed path relative to
///   `xcode-select -p`'s own `Toolchains/XcodeDefault.xctoolchain`, not
///   something `xcrun --find` can locate.
/// - It needs `Testing.framework` (`Platforms/MacOSX.platform/Developer/
///   Library/Frameworks`), `XCTestCore.framework`/`XCTestSupport.framework`
///   (`.../PrivateFrameworks`), and `libXCTestSwiftSupport.dylib`
///   (`.../Developer/usr/lib`) on `DYLD_FRAMEWORK_PATH`/`DYLD_LIBRARY_PATH`
///   to `dlopen` the test bundle's own Mach-O binary at all.
/// - Unlike `xcodebuild -enableCodeCoverage YES` (confirmed, separately, to
///   silently ignore a caller-supplied `LLVM_PROFILE_FILE` and merge every
///   configuration in a batch into one inseparable `Coverage.profdata` — see
///   the F1-A2 spike notes), a **direct** invocation of an LLVM-instrumented
///   binary honors `LLVM_PROFILE_FILE` exactly the way any other
///   instrumented binary does: a literal path, no `%p` needed, one process,
///   one profile.
enum SwiftPMDirectCoverageRunner {
    struct Outcome: Sendable, Equatable {
        let evidence: SwiftTestingEventStreamParser.RunEvidence
        /// Where this one test's raw LLVM profile was written. Confirmed to
        /// exist on disk before this outcome is returned — never returned
        /// as a promise the caller has to re-check.
        let profileURL: URL
    }

    enum RunResult: Sendable, Equatable {
        case succeeded(Outcome)
        /// Anything short of "this one test's evidence and profile are both
        /// present and trustworthy" — a launch failure, a timeout, an
        /// unsupported/malformed event stream, or a missing profile.
        /// `SwiftPMDirectCoverageRunner` never returns a partial result; the
        /// caller's own contract (`PerTestCoverageProfileAttempt`) has no
        /// partial case either, and this is the type one level down that
        /// makes that possible.
        case unavailable(reason: String)
    }

    /// - Parameters:
    ///   - testBundleBinary: `SwiftPMTestProductResolver`'s own result — the
    ///     actual Mach-O binary inside the `.xctest` bundle, not the bundle
    ///     directory itself (`dlopen` needs a file).
    ///   - test: the single test to isolate. Filtered with the same
    ///     anchored-regex scheme `TestIdentifier`'s own `swiftTestFilterArgument`
    ///     uses for `swift test --filter` (confirmed empirically to match
    ///     identically through the direct helper) — an unanchored filter
    ///     risks matching more than the one intended test, the same class of
    ///     bug P12-B Finding A/B fixed for the existing serial path.
    ///   - scratchDirectory: where this run's unique event-stream and
    ///     `.profraw` files are written. Caller-owned; this runner neither
    ///     creates nor cleans up anything outside files directly inside it.
    ///   - developerRoot: `xcode-select -p`'s own output, injectable for
    ///     tests. `nil` triggers real discovery.
    static func run(
        testBundleBinary: URL,
        test: TestIdentifier,
        workingDirectory: URL,
        scratchDirectory: URL,
        timeoutSeconds: Double,
        developerRoot: URL? = nil,
        processRunner: ProcessRunner = defaultProcessRunner
    ) async -> RunResult {
        let resolvedDeveloperRoot: URL
        if let developerRoot {
            resolvedDeveloperRoot = developerRoot
        } else {
            guard let discovered = await Self.discoverDeveloperRoot(processRunner: processRunner) else {
                return .unavailable(reason: "could not resolve the active Xcode developer directory (xcode-select -p)")
            }
            resolvedDeveloperRoot = discovered
        }

        let helper = resolvedDeveloperRoot
            .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            return .unavailable(reason: "swiftpm-testing-helper not found at \(helper.path)")
        }

        let platformDeveloper = resolvedDeveloperRoot.appendingPathComponent("Platforms/MacOSX.platform/Developer")
        let frameworksPath = platformDeveloper.appendingPathComponent("Library/Frameworks").path
        let privateFrameworksPath = platformDeveloper.appendingPathComponent("Library/PrivateFrameworks").path
        let libPath = platformDeveloper.appendingPathComponent("usr/lib").path
        let productsDirectory = testBundleBinary
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // <name>.xctest
            .deletingLastPathComponent() // products directory

        let runID = UUID().uuidString
        let eventStreamURL = scratchDirectory.appendingPathComponent("event-stream-\(runID).jsonl")
        let profileURL = scratchDirectory.appendingPathComponent("profile-\(runID).profraw")
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_FRAMEWORK_PATH"] = "\(frameworksPath):\(privateFrameworksPath)"
        environment["DYLD_LIBRARY_PATH"] = "\(productsDirectory.path):\(libPath)"
        environment["LLVM_PROFILE_FILE"] = profileURL.path

        let arguments = [
            "--test-bundle-path", testBundleBinary.path,
            "--testing-library", "swift-testing",
            "--event-stream-output-path", eventStreamURL.path,
            "--event-stream-version", "0",
            "--filter", filterArgument(for: test)
        ]

        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: helper.path,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            return .unavailable(reason: "could not launch swiftpm-testing-helper: \(error)")
        }

        // Exit status is authority on its own, independent of what the event
        // stream claims: a crash or an infrastructure-level failure could in
        // principle still leave a stream that reads as clean (a signal
        // arriving after the last event was flushed, for instance), and
        // trusting the stream alone there would be exactly the kind of gap
        // structured evidence exists to close, not reopen.
        guard result.succeeded else {
            return .unavailable(reason: "swiftpm-testing-helper did not exit successfully (exit \(result.exitCode))")
        }
        guard result.outputComplete else {
            return .unavailable(reason: "swiftpm-testing-helper's own output could not be fully captured")
        }

        switch SwiftTestingEventStreamParser.parse(contentsOf: eventStreamURL) {
        case .unsupported(let reason):
            return .unavailable(reason: "event stream: \(reason)")
        case .parsed(let evidence):
            if let reason = Self.disqualifyingReason(for: test, evidence: evidence) {
                return .unavailable(reason: reason)
            }
            guard FileManager.default.fileExists(atPath: profileURL.path) else {
                return .unavailable(reason: "no coverage profile was written to \(profileURL.path)")
            }
            return .succeeded(Outcome(evidence: evidence, profileURL: profileURL))
        }
    }

    /// `nil` when `evidence` proves exactly `test`, and only `test`, ran to
    /// a trustworthy completion; otherwise the specific reason it does not.
    private static func disqualifyingReason(for test: TestIdentifier, evidence: SwiftTestingEventStreamParser.RunEvidence) -> String? {
        guard evidence.runStarted, evidence.runEnded else {
            return "the event stream never reported both runStarted and runEnded"
        }
        guard evidence.declaredTests.contains(test) else {
            return "\(test) was never declared in its own isolated run's event stream"
        }
        // Exactness, not mere containment: an anchored filter regex is
        // still only a request, never proof on its own that the helper
        // actually honored it -- exactly the class of gap #26/P12-B
        // Finding A/B closed for the existing xcodebuild/xctest paths,
        // reopened here through a different mechanism if only "contains"
        // were checked. `startedTests`/`endedTests` are the structured
        // evidence this backend exists to provide instead of trusting the
        // filter string; both must equal exactly `{test}`, or this
        // isolated run did not isolate what it claimed to.
        guard evidence.startedTests == [test] else {
            return "the isolated filter executed unexpected tests: started \(evidence.startedTests)"
        }
        guard evidence.endedTests == [test] else {
            return "the isolated run did not end exactly the requested test: ended \(evidence.endedTests)"
        }
        guard evidence.skippedTests.isEmpty else {
            return "the isolated run reported a skipped test: \(evidence.skippedTests)"
        }
        guard evidence.cancelledTests.isEmpty else {
            return "the isolated run reported a cancelled test or test case: \(evidence.cancelledTests)"
        }
        // Positive pass evidence, not merely "no fail symbol seen" --
        // `passedTests`/`failedTests` are mutually exclusive by
        // construction (`SwiftTestingEventStreamParser
        // .recordTerminalOutcome` fails the whole stream closed on
        // anything else), so this pair of checks is equivalent to "exactly
        // one recognized terminal outcome, and it was pass." Parity with
        // the serial oracle's own contract (`SwiftPackageMacOSAdapter
        // .measurePerTestCoverage`: `guard run.status == .passed else {
        // return nil }`) -- a test that fails in isolation is an
        // unprovable run, not evidence to trust, even though it did
        // complete and produced a real profile.
        guard evidence.passedTests == [test] else {
            return "the isolated test run did not report the requested test as passed: passed \(evidence.passedTests)"
        }
        guard evidence.failedTests.isEmpty else {
            return "the isolated test run reported a failure (parity with the serial oracle)"
        }
        return nil
    }

    /// Same anchored-regex construction as `TestIdentifier.swiftTestFilterArgument`
    /// (private to `SwiftPackageMacOSAdapter.swift`) — duplicated rather than
    /// shared across files because that property is intentionally
    /// `private`, and this runner's own correctness depends on the exact
    /// same anchoring, confirmed separately (not assumed) to work identically
    /// through `swiftpm-testing-helper --filter`.
    static func filterArgument(for test: TestIdentifier) -> String {
        let escapedTarget = NSRegularExpression.escapedPattern(for: test.target)
        let escapedQualifiedName = NSRegularExpression.escapedPattern(for: test.qualifiedName)
        return "^\(escapedTarget)\\.\(escapedQualifiedName)(?:/.*)?$"
    }

    private static func discoverDeveloperRoot(processRunner: ProcessRunner) async -> URL? {
        guard let result = try? await processRunner(
            "/usr/bin/xcode-select", ["-p"], FileManager.default.temporaryDirectory, 30
        ), result.succeeded, result.outputComplete else { return nil }
        let path = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
