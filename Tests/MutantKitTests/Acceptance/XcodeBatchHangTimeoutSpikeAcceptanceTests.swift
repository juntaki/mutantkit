import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// Gate 3, Phase H1 spike: can XCTest's own native per-test timeout
/// (`-test-timeouts-enabled`/`-maximum-test-execution-time-allowance`)
/// contain a hang *inside* a batched `.xctestrun`, so one hanging
/// configuration no longer holds the whole `xcodebuild` invocation's outer
/// timeout hostage — the same defect already recorded, unfixed, for
/// isolated-mode wave batching (`testWaveChunk`'s summed per-member
/// timeout).
///
/// Drives `xcodebuild`/`xcresulttool` directly rather than through the
/// `mutantkit` binary: this spike is about raw Xcode flag behavior and
/// `.xcresult` shape, not anything `mutantkit run` currently wires up (it
/// does not pass `-test-timeouts-enabled` today). Reuses
/// `BatchXCTestRunBuilder` and `XCResultAdapter.classifyBatch` (both
/// production code) — the latter's own native-timeout classification
/// branch (Phase H2, `XCResultAdapter.Failure.isNativeTimeout`) is
/// exercised here end to end, against a real bundle, not just the unit
/// fixtures in `XCResultAdapterBatchTests`.
///
/// See `Research/benchmarks/gate3-ios-schemata-2026-08-23/GATE3-RESULT.md`
/// ("Phase H1"/"Phase H2") for the full write-up this test's assertions
/// back.
@Suite("Acceptance: native XCTest timeout as batch hang containment (Gate 3 Phase H1 spike)", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeBatchHangTimeoutSpikeAcceptanceTests {
    /// Both the allowance passed to `xcodebuild` and the value every
    /// assertion below expects a genuine timeout's own `durationInSeconds`
    /// to land on. Kept small (spike-only, per the Gate 3 instruction not to
    /// design a production value here) but must stay above simulator
    /// install/launch overhead observed for this fixture (a few seconds) so
    /// the passing configurations never risk tripping it themselves.
    private static let allowanceSeconds = 60

    /// One real build + one real (slow — the hang always burns the full
    /// allowance) `xcodebuild test-without-building` invocation, shared
    /// across every `@Test` below via `Task` memoization — the async
    /// counterpart to the `Result { ... }`-backed `sharedRun` every other
    /// suite in this file uses, needed here only because `classifyBatch`
    /// itself is `async`.
    private static let sharedRun = Task { try await Self.run() }

    private func run() async throws -> SpikeRun {
        try await Self.sharedRun.value
    }

    private static func run() async throws -> SpikeRun {
        let directory = try Acceptance.stageFixture("XcodeProject")
        let destination = try Acceptance.iPhoneDestination()
        let derivedData = directory.appendingPathComponent("SpikeDerivedData")

        try shell(
            "/usr/bin/xcodebuild",
            [
                "build-for-testing", "-project", "Checkout.xcodeproj", "-scheme", "Checkout",
                "-destination", destination, "-derivedDataPath", derivedData.path
            ],
            in: directory
        )

        guard let xctestrunPath = try FileManager.default
            .contentsOfDirectory(at: derivedData.appendingPathComponent("Build/Products"), includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "xctestrun" })
        else {
            throw SpikeError.xctestrunMissing
        }

        let batchItems = [
            BatchTestItem(
                configurationName: "A", xctestrunPath: xctestrunPath,
                onlyTestingIdentifiers: [TestIdentifier(target: "CheckoutTests", qualifiedName: "CheckoutTests/testCouponAboveMinimum")]
            ),
            BatchTestItem(
                configurationName: "B", xctestrunPath: xctestrunPath,
                onlyTestingIdentifiers: [TestIdentifier(target: "CheckoutTests", qualifiedName: "HangSpikeTests/testIntentionalHang")],
                environmentVariables: ["MUTANTKIT_SPIKE_HANG": "1"]
            ),
            BatchTestItem(
                configurationName: "C", xctestrunPath: xctestrunPath,
                onlyTestingIdentifiers: [TestIdentifier(target: "CheckoutTests", qualifiedName: "CheckoutTests/testCouponAtMinimum")]
            )
        ]
        let batchData = try BatchXCTestRunBuilder.build(items: batchItems)
        let batchPath = directory.appendingPathComponent("batch.xctestrun")
        try batchData.write(to: batchPath)

        let resultBundle = directory.appendingPathComponent("batch.xcresult")
        // Exit code is deliberately unchecked here — a batch with one
        // failing configuration always exits non-zero; that is the
        // condition under test, not a failure of this harness.
        _ = try? shell(
            "/usr/bin/xcodebuild",
            [
                "test-without-building", "-xctestrun", batchPath.path, "-destination", destination,
                "-test-timeouts-enabled", "YES",
                "-default-test-execution-time-allowance", String(allowanceSeconds),
                "-maximum-test-execution-time-allowance", String(allowanceSeconds),
                "-resultBundlePath", resultBundle.path
            ],
            in: directory
        )

        let classified = await XCResultAdapter().classifyBatch(
            resultBundle: resultBundle, workingDirectory: directory,
            configurationTestIdentifiers: [
                "A": ["CheckoutTests/testCouponAboveMinimum"],
                "B": ["HangSpikeTests/testIntentionalHang"],
                "C": ["CheckoutTests/testCouponAtMinimum"]
            ]
        )

        return SpikeRun(resultBundle: resultBundle, workingDirectory: directory, classified: classified)
    }

    @Test("xcodebuild itself exits normally, never killed by the outer supervisor")
    func processCompletesRatherThanHanging() async throws {
        // `run()` above already completed synchronously by the time this
        // assertion runs — a hung, never-returning `xcodebuild` would have
        // failed this whole test file at the harness's own outer timeout,
        // not landed here. The real assertion is structural: getting this
        // far at all is the evidence.
        let run = try await self.run()
        #expect(FileManager.default.fileExists(atPath: run.resultBundle.path))
    }

    @Test("Configuration B (the hang) fails with the native-timeout signature, at the configured allowance")
    func hangIsCutOffAtTheConfiguredAllowance() async throws {
        let run = try await self.run()

        let detail = try await testResultsTestDetail(
            resultBundle: run.resultBundle, workingDirectory: run.workingDirectory,
            testIdentifier: "HangSpikeTests/testIntentionalHang()"
        )
        #expect(detail.testResult == "Failed")
        #expect(detail.durationInSeconds == Double(Self.allowanceSeconds))

        let summary = try await testResultsSummary(resultBundle: run.resultBundle, workingDirectory: run.workingDirectory)
        let failure = summary.testFailures.first { $0.testIdentifierString == "HangSpikeTests/testIntentionalHang()" }
        #expect(failure != nil)
        // The one Apple-authored, fixed-format prefix this failure mode
        // writes — same pattern `XCResultAdapter.Failure.isCrash` already
        // relies on (`failureText.hasPrefix("Crash:")`) against the same
        // structured JSON field, not a grep of console output.
        #expect(failure?.failureText.hasPrefix("Test exceeded execution time allowance") == true)
    }

    @Test("Configurations A and C both still ran and passed — B's hang did not stop its siblings")
    func siblingsRunToCompletionAroundTheHang() async throws {
        let run = try await self.run()

        let summary = try await testResultsSummary(resultBundle: run.resultBundle, workingDirectory: run.workingDirectory)
        let byConfiguration = Dictionary(uniqueKeysWithValues: summary.devicesAndConfigurations.map {
            ($0.testPlanConfiguration.configurationName, $0)
        })

        #expect(byConfiguration["A"]?.passedTests == 1)
        #expect(byConfiguration["A"]?.failedTests == 0)
        #expect(byConfiguration["C"]?.passedTests == 1)
        #expect(byConfiguration["C"]?.failedTests == 0)
        #expect(byConfiguration["B"]?.failedTests == 1)
    }

    @Test("XCResultAdapter.classifyBatch itself tells the native timeout apart from an ordinary failure (Gate 3 Phase H2)")
    func classifierDistinguishesNativeTimeoutFromAnOrdinaryFailure() async throws {
        let run = try await self.run()
        #expect(run.classified["A"]?.status == .passed)
        #expect(run.classified["B"]?.status == .timedOut)
        #expect(run.classified["C"]?.status == .passed)
    }
}

private struct SpikeRun: Sendable {
    let resultBundle: URL
    let workingDirectory: URL
    let classified: [String: XCResultAdapter.Outcome]
}

private enum SpikeError: Error {
    case xctestrunMissing
}

@discardableResult
private func shell(_ executable: String, _ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw ShellError.failed(executable: executable, arguments: arguments, exitCode: process.terminationStatus, output: output)
    }
    return output
}

private enum ShellError: Error, CustomStringConvertible {
    case failed(executable: String, arguments: [String], exitCode: Int32, output: String)

    var description: String {
        switch self {
        case let .failed(executable, arguments, exitCode, output):
            "\(executable) \(arguments.joined(separator: " ")) exited \(exitCode):\n\(output)"
        }
    }
}

// MARK: - Raw xcresulttool reads (spike-only; production reads go through XCResultAdapter)

private struct TestDetail: Decodable {
    let testResult: String
    let durationInSeconds: Double
}

private func testResultsTestDetail(resultBundle: URL, workingDirectory: URL, testIdentifier: String) async throws -> TestDetail {
    let output = try shell(
        "/usr/bin/xcrun",
        ["xcresulttool", "get", "test-results", "test-details", "--path", resultBundle.path, "--test-id", testIdentifier, "--compact"],
        in: workingDirectory
    )
    return try JSONDecoder().decode(TestDetail.self, from: Data(output.utf8))
}

private struct TestResultsSummary: Decodable {
    let devicesAndConfigurations: [DeviceConfiguration]
    let testFailures: [Failure]

    struct DeviceConfiguration: Decodable {
        let passedTests: Int
        let failedTests: Int
        let testPlanConfiguration: Configuration

        struct Configuration: Decodable {
            let configurationName: String
        }
    }

    struct Failure: Decodable {
        let failureText: String
        let testIdentifierString: String?
    }
}

private func testResultsSummary(resultBundle: URL, workingDirectory: URL) async throws -> TestResultsSummary {
    let output = try shell(
        "/usr/bin/xcrun",
        ["xcresulttool", "get", "test-results", "summary", "--path", resultBundle.path, "--compact"],
        in: workingDirectory
    )
    return try JSONDecoder().decode(TestResultsSummary.self, from: Data(output.utf8))
}
