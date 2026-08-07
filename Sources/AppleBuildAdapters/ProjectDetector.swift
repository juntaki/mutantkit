import Foundation
import MutationExecution
import MutationModel

/// What detection concluded, and the evidence it concluded it from.
///
/// The reasoning is carried rather than discarded because picking the wrong
/// builder is silent: `swift test` on an iOS-only package does not announce that
/// it cannot see UIKit, it simply fails to compile in a way that looks like the
/// user's fault. When that happens the user needs to see *why* this tool chose
/// the builder it chose.
public struct ProjectDetection: Sendable {
    public let kind: ProjectKind
    /// One sentence naming the deciding evidence.
    public let reason: String
    /// The `.xcodeproj`/`.xcworkspace`/`Package.swift` the decision was made from.
    public let projectFile: URL?
    /// Platforms declared in `Package.swift`, lowercased as SwiftPM spells them.
    /// Empty for Xcode projects, where the manifest is not the authority.
    public let declaredPlatforms: [String]

    public init(kind: ProjectKind, reason: String, projectFile: URL?, declaredPlatforms: [String] = []) {
        self.kind = kind
        self.reason = reason
        self.projectFile = projectFile
        self.declaredPlatforms = declaredPlatforms
    }
}

public enum ProjectDetectionError: Error, CustomStringConvertible {
    case nothingRecognized(directory: String)
    case manifestUnreadable(directory: String, detail: String)

    public var description: String {
        switch self {
        case let .nothingRecognized(directory):
            """
            No Swift project found in \(directory). Expected an .xcworkspace, an \
            .xcodeproj, or a Package.swift.
            """
        case let .manifestUnreadable(directory, detail):
            "Could not read the package manifest in \(directory): \(detail)"
        }
    }
}

/// Decides how a directory must be built.
///
/// The order is workspace, then project, then package: a repository that has all
/// three is an app whose package is a dependency, and building the package alone
/// would test something the user did not ask about.
public enum ProjectDetector {
    /// Platforms that a host `swift test` cannot run. A package declaring only
    /// these has no macOS slice to test, so it must go through `xcodebuild`.
    private static let nonHostApplePlatforms: Set<String> = [
        "ios", "tvos", "watchos", "visionos", "maccatalyst"
    ]

    /// Platforms that `swift test` can run on this host.
    private static let hostPlatforms: Set<String> = ["macos", "driverkit", "linux"]

    public static func detect(
        in directory: URL,
        timeoutSeconds: Double = 60
    ) async throws -> ProjectDetection {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        // A workspace subsumes the projects inside it, so it wins outright.
        if let workspace = contents.first(where: { $0.pathExtension == "xcworkspace" }) {
            return ProjectDetection(
                kind: .xcodeWorkspace,
                reason: "Found \(workspace.lastPathComponent), which takes precedence over any project or package beside it.",
                projectFile: workspace
            )
        }

        if let project = contents.first(where: { $0.pathExtension == "xcodeproj" }) {
            return ProjectDetection(
                kind: .xcodeProject,
                reason: "Found \(project.lastPathComponent) and no workspace.",
                projectFile: project
            )
        }

        let manifest = directory.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw ProjectDetectionError.nothingRecognized(directory: directory.path)
        }

        return try await detectPackage(manifest: manifest, in: directory, timeoutSeconds: timeoutSeconds)
    }

    /// Classifies a Swift package by the platforms its manifest declares.
    private static func detectPackage(
        manifest: URL,
        in directory: URL,
        timeoutSeconds: Double
    ) async throws -> ProjectDetection {
        let platforms = try await declaredPlatforms(in: directory, timeoutSeconds: timeoutSeconds)

        // No `platforms:` means SwiftPM's defaults, which include macOS.
        guard !platforms.isEmpty else {
            return ProjectDetection(
                kind: .swiftPackageMacOS,
                reason: "Package.swift declares no platforms, so it builds for the host and `swift test` can run it.",
                projectFile: manifest,
                declaredPlatforms: platforms
            )
        }

        if platforms.contains(where: hostPlatforms.contains) {
            return ProjectDetection(
                kind: .swiftPackageMacOS,
                reason: "Package.swift declares \(platforms.joined(separator: ", ")), which includes a host platform, so `swift test` can run it.",
                projectFile: manifest,
                declaredPlatforms: platforms
            )
        }

        if platforms.contains(where: nonHostApplePlatforms.contains) {
            return ProjectDetection(
                kind: .swiftPackageApple,
                reason: "Package.swift declares only \(platforms.joined(separator: ", ")), none of which run on the host, so it must be built with xcodebuild against a simulator.",
                projectFile: manifest,
                declaredPlatforms: platforms
            )
        }

        // Unrecognized platforms: assume the host rather than invent a destination.
        return ProjectDetection(
            kind: .swiftPackageMacOS,
            reason: "Package.swift declares \(platforms.joined(separator: ", ")); no Apple simulator platform was recognized, so the host toolchain is used.",
            projectFile: manifest,
            declaredPlatforms: platforms
        )
    }

    /// Reads `platforms:` from the manifest via SwiftPM itself.
    ///
    /// The manifest is Swift, not data: `platforms` can be a computed array, an
    /// `if #available`, or a constant defined elsewhere in the file. Only SwiftPM
    /// can say what it evaluates to, so we ask it instead of pattern-matching text
    /// that only looks like a literal.
    static func declaredPlatforms(in directory: URL, timeoutSeconds: Double) async throws -> [String] {
        let result = try await ProcessSupervisor.run(
            executable: ToolPaths.xcrun,
            arguments: ["swift", "package", "dump-package"],
            workingDirectory: directory,
            timeoutSeconds: timeoutSeconds
        )

        guard result.succeeded else {
            throw ProjectDetectionError.manifestUnreadable(
                directory: directory.path,
                detail: OutputRedactor.redact(String(decoding: result.standardError, as: UTF8.self))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        do {
            let manifest = try JSONDecoder().decode(DumpedManifest.self, from: result.standardOutput)
            return manifest.platforms?.map { $0.platformName.lowercased() } ?? []
        } catch {
            throw ProjectDetectionError.manifestUnreadable(
                directory: directory.path,
                detail: "dump-package emitted JSON this version does not understand: \(error)"
            )
        }
    }

    /// The slice of `swift package dump-package` output this tool depends on.
    /// Everything else in that JSON is deliberately not modelled, so unrelated
    /// SwiftPM changes cannot break detection.
    private struct DumpedManifest: Decodable {
        struct Platform: Decodable {
            /// SwiftPM spells these lowercase: `macos`, `ios`, `tvos`, `watchos`, `visionos`.
            let platformName: String
        }

        let platforms: [Platform]?
    }
}
