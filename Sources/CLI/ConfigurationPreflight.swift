import ArgumentParser
import Foundation
import MutationModel

/// The configuration gate every command that acts on a resolved
/// `Configuration` must pass before doing anything else — printed so
/// warnings are visible even when nothing is wrong enough to stop the
/// command, and fail-closed on the first error.
enum ConfigurationPreflight {
    /// - Parameter projectRoot: the root the command actually operates on
    ///   (`CommonOptions.resolvedProjectRoot`, which honours `--project-root`).
    ///   It is the tree `WorkspaceManager` clones into every worker's sandbox,
    ///   so it is what `ConfigurationValidator`'s symlink-escape check for
    ///   `project.derivedDataPath` must be evaluated against. There is no
    ///   current-directory fallback.
    static func run(_ configuration: Configuration, projectRoot: URL) throws {
        let issues = ConfigurationValidator.validate(configuration, projectRoot: projectRoot)
        // v0.5 Stable Contracts: diagnostics go to stderr, not stdout — this
        // gate is the first thing almost every command runs, on both the
        // warning-only (still succeeds) and error (throws below) paths, so a
        // caller parsing stdout (e.g. `--json`) must never see this prose
        // either way.
        for issue in issues { FileHandle.standardError.write(Data("\(issue.description)\n".utf8)) }
        guard !issues.contains(where: { $0.severity == .error }) else {
            throw ExitCode(MutantKitExit.operationalError)
        }
    }
}
