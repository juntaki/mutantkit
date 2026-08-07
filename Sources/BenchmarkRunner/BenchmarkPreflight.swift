import Foundation

/// Which layer made a project/tool combination not comparable — never a
/// bare "it failed." Distinguishing these is the whole point of running
/// preflight before spending a full cold/warm/incremental sweep on a
/// project that was never going to produce a comparable result.
public enum BenchmarkPreflightFailure: String, Codable, Sendable {
    case repositoryMaterializationFailed
    case unsupportedHostPlatform
    case unsupportedSwiftToolchain
    case unsupportedXcodeToolchain
    /// The project's own unmutated build failed — nothing about either
    /// tool has been exercised yet.
    case projectBaselineBuildFailed
    /// The project's own unmutated test run failed outright (a real,
    /// reproducible test failure in the pinned commit's own suite).
    case projectBaselineTestFailed
    /// The project's own test run's exit code and its own reported
    /// per-test summary disagree in a way genuinely attributable to the
    /// *project* (e.g. a test target the summary parser cannot see failing
    /// independently) — not a tool bug, and not silently treated as a
    /// pass. See `BenchmarkPreflight`'s own doc comment for the concrete
    /// case this was written for (`swift-argument-parser`'s
    /// `GenerateManualTests`, confirmed via a fully manual repro before
    /// this case was added — never guessed at).
    case projectBaselineInconsistent
    case toolInstallationFailed
    case toolCompilationFailed
    case toolConfigurationFailed
    case toolPlanFailed
    case noComparableMutations
}

/// One stage's own preflight outcome — `succeeded` carries no payload
/// (nothing more to say); a failure carries its classification, the exact
/// command that failed, and a stderr/stdout excerpt, so a report reader
/// never has to reproduce the failure just to see what happened.
public struct PreflightStageResult: Codable, Sendable {
    public let succeeded: Bool
    public let failure: BenchmarkPreflightFailure?
    public let command: String?
    public let exitCode: Int32?
    public let outputExcerpt: String?

    public init(
        succeeded: Bool, failure: BenchmarkPreflightFailure? = nil, command: String? = nil,
        exitCode: Int32? = nil, outputExcerpt: String? = nil
    ) {
        self.succeeded = succeeded
        self.failure = failure
        self.command = command
        self.exitCode = exitCode
        self.outputExcerpt = outputExcerpt
    }

    public static let notAttempted = PreflightStageResult(
        succeeded: false, failure: nil, command: nil, exitCode: nil, outputExcerpt: "not attempted (an earlier stage already failed)"
    )

    public static func ok() -> PreflightStageResult { PreflightStageResult(succeeded: true) }

    public static func failed(
        _ failure: BenchmarkPreflightFailure, command: String, exitCode: Int32?, output: String
    ) -> PreflightStageResult {
        PreflightStageResult(
            succeeded: false, failure: failure, command: command, exitCode: exitCode, outputExcerpt: String(output.suffix(2000))
        )
    }
}

/// The exact toolchain identity a preflight (and every measurement it
/// gates) was taken under — recorded so "current-environment usability"
/// results are never silently compared across two different machines or
/// toolchain versions without saying so.
public struct BenchmarkEnvironment: Codable, Hashable, Sendable {
    public let macOSVersion: String
    public let architecture: String
    public let swiftVersion: String
    public let xcodeVersion: String?
    public let xcodeBuildVersion: String?
    public let sdkVersions: [String: String]

    public init(
        macOSVersion: String, architecture: String, swiftVersion: String,
        xcodeVersion: String? = nil, xcodeBuildVersion: String? = nil, sdkVersions: [String: String] = [:]
    ) {
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.swiftVersion = swiftVersion
        self.xcodeVersion = xcodeVersion
        self.xcodeBuildVersion = xcodeBuildVersion
        self.sdkVersions = sdkVersions
    }

    /// A short, filesystem-safe identity for this environment — used as
    /// `Benchmarks/results/preflight/<environment-id>/...`, so results
    /// taken under two different toolchains are never written into the
    /// same directory and silently merged.
    public var identifier: String {
        let raw = "\(macOSVersion)-\(architecture)-\(swiftVersion)"
        let sanitized = raw.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return String(sanitized)
    }
}

public struct BenchmarkPreflightResult: Codable, Sendable {
    public let projectID: String
    public let toolchainProfileID: String
    public let environment: BenchmarkEnvironment
    public let projectBaseline: PreflightStageResult
    public let mutantKit: PreflightStageResult
    public let muter: PreflightStageResult
    public let comparable: Bool

    public init(
        projectID: String, toolchainProfileID: String, environment: BenchmarkEnvironment, projectBaseline: PreflightStageResult,
        mutantKit: PreflightStageResult, muter: PreflightStageResult, comparable: Bool
    ) {
        self.projectID = projectID
        self.toolchainProfileID = toolchainProfileID
        self.environment = environment
        self.projectBaseline = projectBaseline
        self.mutantKit = mutantKit
        self.muter = muter
        self.comparable = comparable
    }
}

/// Runs a project through every stage that must succeed before a real
/// cold/warm/incremental sweep is worth attempting — a benchmark run that
/// starts on a project whose own baseline never passes just burns wall
/// time to report a foregone conclusion. Every stage's failure is
/// classified, never collapsed into "the project failed."
public struct BenchmarkPreflight: Sendable {
    private let toolRunner: ToolRunner

    public init(toolRunner: ToolRunner = ToolRunner()) {
        self.toolRunner = toolRunner
    }

    public static func currentEnvironment() -> BenchmarkEnvironment {
        let process = ProcessInfo.processInfo
        let os = process.operatingSystemVersion
        let macOSVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
            let architecture = "arm64"
        #elseif arch(x86_64)
            let architecture = "x86_64"
        #else
            let architecture = "unknown"
        #endif
        return BenchmarkEnvironment(macOSVersion: macOSVersion, architecture: architecture, swiftVersion: swiftVersionString())
    }

    private static func swiftVersionString() -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "--version"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "unknown" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").first.map(String.init) ?? "unknown"
    }

    /// Builds and tests the pinned commit exactly as checked out, with
    /// neither tool involved yet — a failure here means nothing about
    /// either tool has been exercised, and both `mutantKit`/`muter` stages
    /// are recorded as `.notAttempted`.
    public func checkBaseline(project: MaterializedBenchmarkProject) async throws -> PreflightStageResult {
        let build = try await toolRunner.run(ToolInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["swift", "build", "--build-tests"],
            workingDirectory: project.directory, timeoutSeconds: 1800
        ))
        guard build.exitCode == 0 else {
            return .failed(
                .projectBaselineBuildFailed, command: "swift build --build-tests", exitCode: build.exitCode,
                output: build.standardError + build.standardOutput
            )
        }

        let test = try await toolRunner.run(ToolInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["swift", "test", "--skip-build"],
            workingDirectory: project.directory, timeoutSeconds: 1800
        ))
        guard test.exitCode == 0 else {
            return .failed(
                .projectBaselineTestFailed, command: "swift test --skip-build", exitCode: test.exitCode,
                output: test.standardError + test.standardOutput
            )
        }
        return .ok()
    }
}
