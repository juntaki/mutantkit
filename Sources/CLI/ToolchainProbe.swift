import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel

/// Reads the toolchain's identity from the toolchain itself.
///
/// The planner and the reporters are deliberately subprocess-free, so gathering
/// this is the CLI's job — it is the only layer allowed to ask the outside world
/// questions.
enum ToolchainProbe {
    /// `resolvedDestination`: the run's own already-resolved destination
    /// (`nil` for callers with no destination yet, e.g. `mutantkit plan`,
    /// which legitimately has nothing to report for either
    /// `buildSDKIdentity`/`destinationRuntimeIdentity` — see those fields'
    /// own doc comments). Passing it through here, rather than probing
    /// generically, is deliberate: `xcodebuild`'s own destination
    /// resolution is itself ambiguous without a concretely resolved device
    /// (`ResolvedDestination`'s own doc comment), so anything this function
    /// guessed on its own could disagree with what the run actually
    /// built/tested against.
    static func fingerprint(
        workingDirectory: URL, resolvedDestination: ResolvedDestination? = nil
    ) async -> ToolchainFingerprint {
        async let swift = firstLine(of: "/usr/bin/swift", arguments: ["--version"], in: workingDirectory)
        async let xcode = firstLine(of: "/usr/bin/xcodebuild", arguments: ["-version"], in: workingDirectory)
        async let sdkIdentity = buildSDKIdentity(resolvedDestination: resolvedDestination, workingDirectory: workingDirectory)

        return await ToolchainFingerprint(
            toolVersion: ToolVersion.version,
            toolCommitSHA: ToolVersion.commitSHA,
            // An unreadable toolchain is recorded as unknown rather than guessed.
            // A wrong fingerprint is worse than an absent one: it would let a
            // plan look reproducible on a machine where it is not.
            swiftVersion: swift ?? "unknown",
            swiftSyntaxVersion: ToolVersion.swiftSyntaxVersion,
            xcodeVersion: xcode,
            buildSDKIdentity: sdkIdentity,
            // Deliberately independent of `buildSDKIdentity` above, not
            // derived from it: a build's SDK and a test run's simulator
            // runtime are two genuinely separate axes (the SDK a project
            // compiles against is whatever Xcode's toolchain resolves for
            // the platform; the runtime a resolved *device* boots can be an
            // explicitly older one the destination string names) — see
            // `ToolchainFingerprint.destinationRuntimeIdentity`'s own doc
            // comment.
            destinationRuntimeIdentity: resolvedDestination?.device.map { "simulator:\($0.runtimeIdentifier)" }
        )
    }

    /// See `ToolchainFingerprint.buildSDKIdentity`'s own doc comment for the
    /// exact shape. Platform-aware, not hardcoded to one SDK: derives the
    /// canonical `xcrun --sdk <name>` platform from the destination's own
    /// `platform=` field (`DestinationResolver.field`, the same parser
    /// `SchemataRuntimePlatform`/the resolver itself already use), covering
    /// every Apple platform this catalog's destinations can name — not just
    /// the two (`macosx`/`iphonesimulator`) `SchemataRuntimePlatform` itself
    /// deliberately fails closed on for its own, narrower schemata-archive-
    /// linking purpose.
    private static func buildSDKIdentity(resolvedDestination: ResolvedDestination?, workingDirectory: URL) async -> String? {
        guard let requested = resolvedDestination?.requested,
              let platformValue = DestinationResolver.field(named: "platform", inDestination: requested)
              ?? DestinationResolver.field(named: "generic/platform", inDestination: requested),
              let sdkName = xcrunSDKName(forPlatformValue: platformValue)
        else { return nil }
        // `platform=macOS,variant=Mac Catalyst` builds for `-macabi`, not
        // plain macOS — a real, different SDK/ABI combination this catalog
        // does not otherwise model, on the same fail-closed footing
        // `SchemataRuntimePlatform.resolve`'s own doc comment already
        // documents for the identical destination shape. Never guessed as
        // plain `macosx`.
        if sdkName == "macosx",
           let variant = DestinationResolver.field(named: "variant", inDestination: requested),
           variant.localizedCaseInsensitiveContains("Catalyst") {
            return nil
        }

        async let version = firstLine(of: "/usr/bin/xcrun", arguments: ["--sdk", sdkName, "--show-sdk-version"], in: workingDirectory)
        async let build = firstLine(of: "/usr/bin/xcrun", arguments: ["--sdk", sdkName, "--show-sdk-build-version"], in: workingDirectory)
        guard let version = await version else { return nil }
        let buildSuffix = await build.map { "(\($0))" } ?? ""
        return "sdk:\(sdkName):\(version)\(buildSuffix)"
    }

    /// The exact platform-value spellings `xcodebuild -destination` accepts
    /// (confirmed against this project's own destination fixtures in
    /// `SchemataRuntimePlatformTests`/`DestinationResolverTests`), mapped to
    /// `xcrun`'s own canonical SDK names. Case-insensitive: `xcodebuild`
    /// itself treats `platform=iOS Simulator` and `platform=ios simulator`
    /// identically.
    private static func xcrunSDKName(forPlatformValue platformValue: String) -> String? {
        let normalized = platformValue.lowercased()
        switch normalized {
        case "macos": return "macosx"
        case "ios": return "iphoneos"
        case "ios simulator": return "iphonesimulator"
        case "tvos": return "appletvos"
        case "tvos simulator": return "appletvsimulator"
        case "watchos": return "watchos"
        case "watchos simulator": return "watchsimulator"
        case "visionos": return "xros"
        case "visionos simulator": return "xrsimulator"
        default: return nil
        }
    }

    private static func firstLine(
        of executable: String,
        arguments: [String],
        in workingDirectory: URL
    ) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        do {
            let result = try await ProcessSupervisor.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                // A version probe that has not answered in 30s is broken, and
                // waiting longer will not make it answer.
                timeoutSeconds: 30
            )
            guard result.succeeded else { return nil }
            return String(decoding: result.standardOutput, as: UTF8.self)
                .split(separator: "\n")
                .first
                .map { $0.trimmingCharacters(in: .whitespaces) }
        } catch {
            return nil
        }
    }
}
