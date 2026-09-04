import Foundation
import MutationExecution
import MutationModel

/// Kept in its own file, split out of `SwiftPackageMacOSAdapter.swift`
/// (already at this project's `file_length` threshold), purely for size —
/// no behavior here depends on anything not already visible through that
/// file's own `import`s.
public extension SwiftPackageMacOSAdapter {
    /// `PackageManifestConfirmationRetesting.resolveDependenciesForConfirmationRetest`
    /// — see its doc comment for the full "why". `swift package resolve`,
    /// deliberately not `swift build`/`swift test`: the dedicated, idempotent
    /// resolution command, nothing more. `packageRoot` as the working
    /// directory needs no extra `--package-path`, the same shape every other
    /// unscoped command in `SwiftPackageMacOSAdapter.swift` already uses.
    func resolveDependenciesForConfirmationRetest(packageRoot: URL, timeoutSeconds: Double) async throws {
        let arguments = ["swift", "package", "resolve"]
        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcrun,
                arguments: arguments,
                workingDirectory: packageRoot,
                timeoutSeconds: timeoutSeconds,
                terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
            )
        } catch {
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: "Could not launch the Swift toolchain to resolve package dependencies: \(error)",
                command: CommandRecording.record(
                    executable: ToolPaths.xcrun, arguments: arguments, workingDirectory: packageRoot, result: nil
                ),
                output: ""
            )
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcrun, arguments: arguments, workingDirectory: packageRoot, result: result
        )
        guard result.succeeded else {
            throw BuildClassifier.failure(from: result, command: command)
        }
    }
}
