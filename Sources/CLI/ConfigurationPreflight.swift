import ArgumentParser
import Foundation
import MutationModel

/// The configuration gate every command that acts on a resolved
/// `Configuration` must pass before doing anything else — printed so
/// warnings are visible even when nothing is wrong enough to stop the
/// command, and fail-closed on the first error.
enum ConfigurationPreflight {
    static func run(_ configuration: Configuration) throws {
        // The current directory, not `configuration.project.path`: it is the
        // tree `WorkspaceManager` actually clones into every worker's
        // sandbox (see `RunCommand`'s `WorkspaceManager(projectRoot:...)`),
        // symlinks and all, so it is what `ConfigurationValidator`'s
        // symlink-escape check for `project.derivedDataPath` needs to be
        // representative. This does not see a `--project-root` override —
        // that flag is parsed by each command (`CommonOptions
        // .resolvedProjectRoot`) and never reaches this shared preflight —
        // so the symlink check is best-effort for that case. Widening it
        // would mean threading the resolved root through every call site of
        // `ConfigurationPreflight.run`, which is out of scope here.
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let issues = ConfigurationValidator.validate(configuration, projectRoot: projectRoot)
        for issue in issues { print(issue.description) }
        guard !issues.contains(where: { $0.severity == .error }) else {
            throw ExitCode(MutantKitExit.operationalError)
        }
    }
}
