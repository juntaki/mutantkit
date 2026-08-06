import Foundation
import MutationExecution
import MutationModel

/// Reads the toolchain's identity from the toolchain itself.
///
/// The planner and the reporters are deliberately subprocess-free, so gathering
/// this is the CLI's job — it is the only layer allowed to ask the outside world
/// questions.
enum ToolchainProbe {
    static func fingerprint(workingDirectory: URL) async -> ToolchainFingerprint {
        async let swift = firstLine(of: "/usr/bin/swift", arguments: ["--version"], in: workingDirectory)
        async let xcode = firstLine(of: "/usr/bin/xcodebuild", arguments: ["-version"], in: workingDirectory)

        return await ToolchainFingerprint(
            toolVersion: ToolVersion.version,
            toolCommitSHA: ToolVersion.commitSHA,
            // An unreadable toolchain is recorded as unknown rather than guessed.
            // A wrong fingerprint is worse than an absent one: it would let a
            // plan look reproducible on a machine where it is not.
            swiftVersion: swift ?? "unknown",
            swiftSyntaxVersion: ToolVersion.swiftSyntaxVersion,
            xcodeVersion: xcode
        )
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
