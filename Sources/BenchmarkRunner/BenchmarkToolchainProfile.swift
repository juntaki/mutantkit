import Foundation

/// One toolchain identity a benchmark run can be pinned to — `current`
/// tracks whatever is installed on this machine right now (drifts with the
/// machine); `compatibility` is deliberately pinned so a pure MutantKit-
/// vs-Muter performance comparison is never confounded by "which tool
/// happened to compile on today's toolchain."
public struct BenchmarkToolchainProfile: Codable, Hashable, Sendable {
    public enum Purpose: String, Codable, Sendable {
        case currentEnvironment
        case crossToolCompatibility
    }

    public let id: String
    public let purpose: Purpose
    public let developerDirectory: String?
    public let toolchainsDirectory: String?
    public let swiftExecutable: String
    public let swiftVersion: String
    public let xcodeVersion: String?
    public let xcodeBuildVersion: String?
    public let sdkVersions: [String: String]

    public init(
        id: String, purpose: Purpose, developerDirectory: String? = nil, toolchainsDirectory: String? = nil,
        swiftExecutable: String, swiftVersion: String, xcodeVersion: String? = nil,
        xcodeBuildVersion: String? = nil, sdkVersions: [String: String] = [:]
    ) {
        self.id = id
        self.purpose = purpose
        self.developerDirectory = developerDirectory
        self.toolchainsDirectory = toolchainsDirectory
        self.swiftExecutable = swiftExecutable
        self.swiftVersion = swiftVersion
        self.xcodeVersion = xcodeVersion
        self.xcodeBuildVersion = xcodeBuildVersion
        self.sdkVersions = sdkVersions
    }
}

/// A tool's own pinned identity for a benchmark run — never `master` or
/// "whatever tag is newest right now" resolved at run time. MutantKit's own
/// commit is recorded the same way, via `git rev-parse HEAD` against this
/// checkout, so a benchmark result names exactly which build of *both*
/// tools produced it.
public struct BenchmarkToolRevision: Codable, Hashable, Sendable {
    public let repositoryURL: String
    public let commitSHA: String
    public let reportedVersion: String?

    public init(repositoryURL: String, commitSHA: String, reportedVersion: String?) {
        self.repositoryURL = repositoryURL
        self.commitSHA = commitSHA
        self.reportedVersion = reportedVersion
    }
}

public extension BenchmarkToolchainProfile {
    /// `Benchmarks/results/current/<profile-id>` or `Benchmarks/results/
    /// compatibility/<profile-id>` — the two lanes never share a directory,
    /// so a `current`-lane run can never silently overwrite a
    /// `compatibility`-lane result (or a different `current`-lane result
    /// taken under a different toolchain) or vice versa. Pure and
    /// deterministic on purpose — unit-testable without touching disk.
    func resultDirectory(under root: URL) -> URL {
        let lane = purpose == .currentEnvironment ? "current" : "compatibility"
        return root.appendingPathComponent(lane).appendingPathComponent(id)
    }
}

/// Propagates one `BenchmarkToolchainProfile` into every subprocess a
/// benchmark run launches — `DEVELOPER_DIR`/`TOOLCHAINS` are how `xcrun`/
/// `xcodebuild`/`swift` themselves resolve which toolchain to use, so
/// setting them on the *process environment* (never as a command-line flag
/// some but not all of these tools accept) is the one mechanism that
/// reaches `xcodebuild`, `swift package`, `swift test`, `swift build`, and
/// Muter's own subprocess invocations identically, with no per-tool
/// special-casing.
public enum ToolchainEnvironmentBuilder {
    public static func environment(base: [String: String], profile: BenchmarkToolchainProfile) -> [String: String] {
        var result = base

        if let directory = profile.developerDirectory {
            result["DEVELOPER_DIR"] = directory
        }
        if let directory = profile.toolchainsDirectory {
            result["TOOLCHAINS"] = directory
        }

        return result
    }
}

/// What was actually observed about the toolchain at some point in time —
/// compared before/after a run by `ToolchainDriftGuard` so a benchmark
/// result is never silently attributed to a toolchain that changed
/// mid-run (a background Xcode update, a `DEVELOPER_DIR` left set by a
/// concurrent process on the same machine).
public struct ObservedToolchainIdentity: Codable, Equatable, Sendable {
    public let swiftVersion: String
    public let xcodeBuildVersion: String?
    public let swiftExecutablePath: String?
    public let sdkVersions: [String: String]
    public let developerDirectory: String?
    public let architecture: String

    public init(
        swiftVersion: String, xcodeBuildVersion: String?, swiftExecutablePath: String?,
        sdkVersions: [String: String], developerDirectory: String?, architecture: String
    ) {
        self.swiftVersion = swiftVersion
        self.xcodeBuildVersion = xcodeBuildVersion
        self.swiftExecutablePath = swiftExecutablePath
        self.sdkVersions = sdkVersions
        self.developerDirectory = developerDirectory
        self.architecture = architecture
    }
}

public enum BenchmarkFailure: Error, CustomStringConvertible {
    /// The toolchain identity observed at the start and end of a run did
    /// not match — the run's own measurements cannot be trusted to have
    /// been taken under one consistent toolchain, so it must be discarded
    /// rather than silently reported.
    case toolchainDrift(before: ObservedToolchainIdentity, after: ObservedToolchainIdentity)
    /// No local toolchain was found that both tools could complete even
    /// one real mutation run under — recorded with the full candidate
    /// list and each one's own failure reason, never silently skipped.
    case blockedMissingToolchain(candidatesExplored: [ToolchainCandidateResult])

    public var description: String {
        switch self {
        case let .toolchainDrift(before, after):
            "the toolchain changed mid-run: before=\(before), after=\(after)"
        case let .blockedMissingToolchain(candidates):
            "no compatible toolchain found among \(candidates.count) candidate(s) explored"
        }
    }
}

/// One toolchain candidate `ToolchainDiscovery` examined, and what
/// happened when it was actually tried — never just "found" or "not
/// found." A candidate is only ever accepted as compatible after at least
/// one real mutation run completes under it with *both* tools, per
/// `BenchmarkToolchainProfile`'s own selection discipline.
public struct ToolchainCandidateResult: Codable, Sendable {
    public let developerDirectory: String
    public let toolchainsDirectory: String?
    public let swiftVersion: String?
    /// `nil` means the stage was never attempted — e.g. a candidate that
    /// failed to even build a Foundation-touching fixture never reached
    /// Muter or MutantKit at all, and that must never be recorded as
    /// `false` (a real, attempted failure) or coerced to any default.
    public let muterBuildSucceeded: Bool?
    public let muterRunSucceeded: Bool?
    public let mutantKitBuildSucceeded: Bool?
    public let mutantKitRunSucceeded: Bool?
    public let failureReason: String?

    public init(
        developerDirectory: String, toolchainsDirectory: String? = nil, swiftVersion: String?,
        muterBuildSucceeded: Bool?, muterRunSucceeded: Bool?,
        mutantKitBuildSucceeded: Bool?, mutantKitRunSucceeded: Bool?, failureReason: String?
    ) {
        self.developerDirectory = developerDirectory
        self.toolchainsDirectory = toolchainsDirectory
        self.swiftVersion = swiftVersion
        self.muterBuildSucceeded = muterBuildSucceeded
        self.muterRunSucceeded = muterRunSucceeded
        self.mutantKitBuildSucceeded = mutantKitBuildSucceeded
        self.mutantKitRunSucceeded = mutantKitRunSucceeded
        self.failureReason = failureReason
    }

    /// `true` only when both tools are *known* (not merely un-refuted) to
    /// have completed a real run — `nil` (never attempted) is never
    /// treated as a pass.
    public var isCompatible: Bool { muterRunSucceeded == true && mutantKitRunSucceeded == true }
}
