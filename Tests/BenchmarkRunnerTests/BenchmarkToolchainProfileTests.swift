@testable import BenchmarkRunner
import Foundation
import Testing

@Suite("BenchmarkToolchainProfile")
struct BenchmarkToolchainProfileTests {
    @Test("A toolchain profile decodes from real-shaped JSON")
    func profileDecodes() throws {
        let json = Data(#"""
        {
          "id": "xcode-15", "purpose": "crossToolCompatibility",
          "developerDirectory": "/Applications/Xcode_15.app/Contents/Developer", "toolchainsDirectory": null,
          "swiftExecutable": "swift", "swiftVersion": "Apple Swift version 5.9", "xcodeVersion": "15.0",
          "xcodeBuildVersion": "15A240d", "sdkVersions": {"macosx": "14.0"}
        }
        """#.utf8)
        let profile = try JSONDecoder().decode(BenchmarkToolchainProfile.self, from: json)
        #expect(profile.id == "xcode-15")
        #expect(profile.purpose == .crossToolCompatibility)
        #expect(profile.developerDirectory == "/Applications/Xcode_15.app/Contents/Developer")
    }

    @Test("A toolchain profile round-trips through Codable")
    func profileRoundTrips() throws {
        let profile = BenchmarkToolchainProfile(
            id: "current", purpose: .currentEnvironment, swiftExecutable: "/usr/bin/swift", swiftVersion: "Swift 6.3"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(BenchmarkToolchainProfile.self, from: data)
        #expect(decoded == profile)
    }

    // MARK: - Environment propagation

    @Test("DEVELOPER_DIR is set on the built environment when the profile names one")
    func developerDirectoryPropagates() {
        let profile = BenchmarkToolchainProfile(
            id: "p", purpose: .crossToolCompatibility, developerDirectory: "/Applications/Xcode_15.app/Contents/Developer",
            swiftExecutable: "swift", swiftVersion: "5.9"
        )
        let environment = ToolchainEnvironmentBuilder.environment(base: [:], profile: profile)
        #expect(environment["DEVELOPER_DIR"] == "/Applications/Xcode_15.app/Contents/Developer")
    }

    @Test("TOOLCHAINS is set on the built environment when the profile names one")
    func toolchainsPropagates() {
        let profile = BenchmarkToolchainProfile(
            id: "p", purpose: .crossToolCompatibility, toolchainsDirectory: "org.swift.5920240102a",
            swiftExecutable: "swift", swiftVersion: "5.9"
        )
        let environment = ToolchainEnvironmentBuilder.environment(base: [:], profile: profile)
        #expect(environment["TOOLCHAINS"] == "org.swift.5920240102a")
    }

    @Test("Base environment is preserved alongside the injected toolchain keys")
    func baseEnvironmentIsPreserved() {
        let profile = BenchmarkToolchainProfile(
            id: "p", purpose: .currentEnvironment, developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            swiftExecutable: "swift", swiftVersion: "6.3"
        )
        let environment = ToolchainEnvironmentBuilder.environment(base: ["PATH": "/usr/bin", "HOME": "/Users/x"], profile: profile)
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HOME"] == "/Users/x")
        #expect(environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
    }

    @Test("A profile with neither developerDirectory nor toolchainsDirectory injects neither key")
    func noOverrideMeansNoInjectedKeys() {
        let profile = BenchmarkToolchainProfile(id: "p", purpose: .currentEnvironment, swiftExecutable: "swift", swiftVersion: "6.3")
        let environment = ToolchainEnvironmentBuilder.environment(base: ["PATH": "/usr/bin"], profile: profile)
        #expect(environment["DEVELOPER_DIR"] == nil)
        #expect(environment["TOOLCHAINS"] == nil)
        #expect(environment.count == 1)
    }

    // MARK: - Toolchain identity / drift

    @Test("Toolchain identity is collected with a real, non-empty Swift version")
    func identityCollectionReadsRealSwiftVersion() {
        let identity = ToolchainDriftGuard.observe(environment: ProcessInfo.processInfo.environment)
        #expect(!identity.swiftVersion.isEmpty)
        #expect(identity.swiftVersion != "unknown")
    }

    @Test("Identical before/after identities pass the drift guard")
    func noDriftPasses() throws {
        let identity = ToolchainDriftGuard.observe(environment: ProcessInfo.processInfo.environment)
        try ToolchainDriftGuard.requireNoDrift(before: identity, after: identity)
    }

    @Test("A changed identity is rejected as drift")
    func driftIsRejected() {
        let before = ObservedToolchainIdentity(
            swiftVersion: "Swift 6.3", xcodeBuildVersion: "17F113", swiftExecutablePath: "/usr/bin/swift",
            sdkVersions: [:], developerDirectory: nil, architecture: "arm64"
        )
        let after = ObservedToolchainIdentity(
            swiftVersion: "Swift 5.9", xcodeBuildVersion: "17F113", swiftExecutablePath: "/usr/bin/swift",
            sdkVersions: [:], developerDirectory: nil, architecture: "arm64"
        )
        #expect(throws: BenchmarkFailure.self) {
            try ToolchainDriftGuard.requireNoDrift(before: before, after: after)
        }
    }

    // MARK: - Discovery

    @Test("Toolchain discovery finds at least the currently active Xcode")
    func discoveryFindsAtLeastOneCandidate() {
        let candidates = ToolchainDiscovery.discoverCandidates()
        #expect(!candidates.isEmpty, "this machine has at least one /Applications/Xcode*.app")
    }

    // MARK: - Lane (result path) isolation

    @Test("A currentEnvironment profile resolves under results/current/<id>")
    func currentLaneResolvesUnderCurrentDirectory() {
        let profile = BenchmarkToolchainProfile(
            id: "macos-26-arm64", purpose: .currentEnvironment, swiftExecutable: "swift", swiftVersion: "6.3"
        )
        let directory = profile.resultDirectory(under: URL(fileURLWithPath: "/Benchmarks/results"))
        #expect(directory.path == "/Benchmarks/results/current/macos-26-arm64")
    }

    @Test("A crossToolCompatibility profile resolves under results/compatibility/<id>, never under current/")
    func compatibilityLaneResolvesUnderCompatibilityDirectory() {
        let profile = BenchmarkToolchainProfile(
            id: "xcode-15", purpose: .crossToolCompatibility, swiftExecutable: "swift", swiftVersion: "5.9"
        )
        let directory = profile.resultDirectory(under: URL(fileURLWithPath: "/Benchmarks/results"))
        #expect(directory.path == "/Benchmarks/results/compatibility/xcode-15")
        #expect(!directory.path.contains("/current/"))
    }

    @Test("The same project under two different profiles resolves to two distinct result directories")
    func sameProjectUnderTwoProfilesNeverCollide() {
        let current = BenchmarkToolchainProfile(
            id: "macos-26-arm64", purpose: .currentEnvironment, swiftExecutable: "swift", swiftVersion: "6.3"
        )
        let compatibility = BenchmarkToolchainProfile(
            id: "xcode-15", purpose: .crossToolCompatibility, swiftExecutable: "swift", swiftVersion: "5.9"
        )
        let root = URL(fileURLWithPath: "/Benchmarks/results")
        #expect(current.resultDirectory(under: root) != compatibility.resultDirectory(under: root))
    }

    @Test("Two distinct currentEnvironment profile ids never collide with each other either")
    func distinctCurrentProfilesDoNotCollide() {
        let macOS26 = BenchmarkToolchainProfile(
            id: "macos-26-arm64", purpose: .currentEnvironment, swiftExecutable: "swift", swiftVersion: "6.3"
        )
        let macOS15 = BenchmarkToolchainProfile(
            id: "macos-15-arm64", purpose: .currentEnvironment, swiftExecutable: "swift", swiftVersion: "5.9"
        )
        let root = URL(fileURLWithPath: "/Benchmarks/results")
        #expect(macOS26.resultDirectory(under: root) != macOS15.resultDirectory(under: root))
    }

    // MARK: - Tool revision pinning

    @Test("A tool revision decodes and never resolves 'master' at runtime — the commitSHA is the sole identity")
    func toolRevisionDecodes() throws {
        let json = Data(#"""
        {"repositoryURL": "https://github.com/muter-mutation-testing/muter.git", "commitSHA": "abc123", "reportedVersion": "16"}
        """#.utf8)
        let revision = try JSONDecoder().decode(BenchmarkToolRevision.self, from: json)
        #expect(revision.commitSHA == "abc123")
        #expect(revision.reportedVersion == "16")
    }

    // MARK: - Toolchain candidate: never-attempted is not a pass

    @Test("A candidate where neither tool was ever reached (nil, not false) is not compatible")
    func neverAttemptedCandidateIsNotCompatible() {
        let candidate = ToolchainCandidateResult(
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            toolchainsDirectory: "org.swift.592202312111a", swiftVersion: "5.9.2",
            muterBuildSucceeded: nil, muterRunSucceeded: nil,
            mutantKitBuildSucceeded: nil, mutantKitRunSucceeded: nil,
            failureReason: "compilerSDKIncompatible: Foundation.swiftinterface unparseable under this compiler"
        )
        #expect(!candidate.isCompatible)
        #expect(candidate.muterRunSucceeded == nil, "never attempted must stay nil, never coerced to false")
    }

    @Test("A candidate decodes with nil tool-attempt fields, distinct from an attempted false")
    func candidateDecodesWithNilAttemptFields() throws {
        let json = Data(#"""
        {
          "developerDirectory": "/Applications/Xcode.app/Contents/Developer",
          "toolchainsDirectory": "org.swift.592202312111a", "swiftVersion": "5.9.2",
          "muterBuildSucceeded": null, "muterRunSucceeded": null,
          "mutantKitBuildSucceeded": null, "mutantKitRunSucceeded": null,
          "failureReason": "compilerSDKIncompatible"
        }
        """#.utf8)
        let candidate = try JSONDecoder().decode(ToolchainCandidateResult.self, from: json)
        #expect(candidate.muterBuildSucceeded == nil)
        #expect(candidate.toolchainsDirectory == "org.swift.592202312111a")
    }
}
