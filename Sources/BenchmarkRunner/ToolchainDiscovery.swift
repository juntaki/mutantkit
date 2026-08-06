import Foundation

/// Enumerates real, locally-installed toolchain candidates — every
/// `/Applications/Xcode*.app` and every side-by-side toolchain under
/// `/Library/Developer/Toolchains`/`~/Library/Developer/Toolchains` — and
/// probes each one for real. "Muter compiled" is not enough to call a
/// candidate compatible; `probe(candidate:project:)` requires at least one
/// completed mutation run from *both* tools before accepting it (see
/// `ToolchainCandidateResult.isCompatible`).
public enum ToolchainDiscovery {
    /// One installed toolchain this machine could plausibly run a
    /// benchmark under, before it has been probed.
    public struct Candidate: Sendable {
        public let developerDirectory: String
        public let toolchainsDirectory: String?

        public init(developerDirectory: String, toolchainsDirectory: String? = nil) {
            self.developerDirectory = developerDirectory
            self.toolchainsDirectory = toolchainsDirectory
        }
    }

    /// Every `/Applications/Xcode*.app/Contents/Developer` directory that
    /// actually exists, plus any side-by-side toolchain bundle under the
    /// two standard `Toolchains` directories Xcode itself searches. Real
    /// filesystem enumeration, never a hard-coded guess at version numbers.
    public static func discoverCandidates(fileManager: FileManager = .default) -> [Candidate] {
        var candidates: [Candidate] = []

        if let applications = try? fileManager.contentsOfDirectory(atPath: "/Applications") {
            for entry in applications.sorted() where entry.hasPrefix("Xcode") && entry.hasSuffix(".app") {
                let developerDirectory = "/Applications/\(entry)/Contents/Developer"
                if fileManager.fileExists(atPath: developerDirectory) {
                    candidates.append(Candidate(developerDirectory: developerDirectory))
                }
            }
        }

        for toolchainsDirectory in ["/Library/Developer/Toolchains", "\(NSHomeDirectory())/Library/Developer/Toolchains"] {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: toolchainsDirectory) else { continue }
            for entry in entries.sorted() where entry.hasSuffix(".xctoolchain") {
                // A side-by-side toolchain still resolves through the
                // *current* Xcode's own `Developer` directory with
                // `TOOLCHAINS` set to select it — it is not a standalone
                // `DEVELOPER_DIR` the way a whole separate Xcode is.
                if let developerDirectory = candidates.first?.developerDirectory {
                    candidates.append(Candidate(
                        developerDirectory: developerDirectory, toolchainsDirectory: "\(toolchainsDirectory)/\(entry)"
                    ))
                }
            }
        }

        return candidates
    }

    /// Reads `swift --version` under `candidate`'s own environment,
    /// without building or running anything — the cheap first filter
    /// before a real, expensive build+run probe.
    public static func swiftVersion(for candidate: Candidate) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "--version"]
        process.environment = ToolchainEnvironmentBuilder.environment(
            base: ProcessInfo.processInfo.environment,
            profile: BenchmarkToolchainProfile(
                id: "probe", purpose: .crossToolCompatibility, developerDirectory: candidate.developerDirectory,
                toolchainsDirectory: candidate.toolchainsDirectory, swiftExecutable: "swift", swiftVersion: ""
            )
        )
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
    }
}

/// Observes toolchain identity before/after a run and rejects the run if
/// it drifted — `BenchmarkFailure.toolchainDrift`, never a silently
/// mismatched result.
public enum ToolchainDriftGuard {
    public static func observe(environment: [String: String]) -> ObservedToolchainIdentity {
        ObservedToolchainIdentity(
            swiftVersion: run(["swift", "--version"], environment: environment) ?? "unknown",
            xcodeBuildVersion: run(["xcodebuild", "-version"], environment: environment),
            swiftExecutablePath: run(["xcrun", "--find", "swift"], environment: environment),
            sdkVersions: [:],
            developerDirectory: environment["DEVELOPER_DIR"],
            architecture: architecture()
        )
    }

    public static func requireNoDrift(before: ObservedToolchainIdentity, after: ObservedToolchainIdentity) throws {
        guard before == after else {
            throw BenchmarkFailure.toolchainDrift(before: before, after: after)
        }
    }

    private static func architecture() -> String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }

    private static func run(_ arguments: [String], environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
