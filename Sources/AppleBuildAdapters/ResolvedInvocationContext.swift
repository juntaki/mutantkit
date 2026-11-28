import Foundation
import MutationExecution
import MutationModel

/// What one invocation is about, resolved once.
///
/// Consumers that need the project root, the package location, the
/// container (workspace / project / manifest), the scheme or the destination
/// read it from here instead of re-deriving it from `Configuration` and the
/// file system. Independent re-derivation is how classification, planning and
/// build came to describe different projects. Existing consumers migrate to
/// this type one program step at a time; until migrated, a consumer still
/// derives its own copy.
///
/// Produced only by `AppleAdapterFactory.resolve`; fields are never mutated.
public struct ResolvedInvocationContext: Sendable {
    /// The real project root (`--project-root`), as given by the CLI layer.
    public let projectRoot: URL
    /// `project.path` as configured; `nil` when unset.
    public let projectPath: String?
    /// How the project was identified, including the container file.
    public let detection: ProjectDetection
    /// The configured scheme; `nil` means none was configured.
    public let scheme: String?
    /// The concrete destination, for kinds that build through `xcodebuild`.
    public let resolvedDestination: ResolvedDestination?

    public init(
        projectRoot: URL, projectPath: String?, detection: ProjectDetection,
        scheme: String?, resolvedDestination: ResolvedDestination?
    ) {
        self.projectRoot = projectRoot
        self.projectPath = projectPath
        self.detection = detection
        self.scheme = scheme
        self.resolvedDestination = resolvedDestination
    }

    public var kind: ProjectKind { detection.kind }

    /// The destination as a contendable resource: the key for the run lock
    /// and for any preflight that must agree with it.
    public var destinationIdentity: DestinationIdentity { DestinationIdentity(resolvedDestination) }

    /// The directory the package under test lives in (`projectRoot` itself
    /// unless `project.path` names a subdirectory).
    public var packageDirectory: URL {
        ProjectPathResolution.packageDirectory(in: projectRoot, projectPath: projectPath)
    }
}
