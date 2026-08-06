import Foundation

/// One benchmark corpus entry — a real, publicly reachable repository pinned
/// to one commit, never a branch or tag alone (a branch moves; a benchmark
/// result must be reproducible against the exact tree it was measured
/// against).
public struct BenchmarkProject: Codable, Sendable, Equatable {
    public enum ProjectKind: String, Codable, Sendable {
        case swiftPackage
        case xcodeProject
        case xcodeWorkspace
    }

    public let id: String
    public let repositoryURL: String
    public let commitSHA: String
    public let projectKind: ProjectKind
    public let scheme: String?
    public let destination: String?
    public let configuration: String?
    public let expectedSwiftFileCount: Int?
    public let tags: [String]

    public init(
        id: String,
        repositoryURL: String,
        commitSHA: String,
        projectKind: ProjectKind,
        scheme: String? = nil,
        destination: String? = nil,
        configuration: String? = nil,
        expectedSwiftFileCount: Int? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.repositoryURL = repositoryURL
        self.commitSHA = commitSHA
        self.projectKind = projectKind
        self.scheme = scheme
        self.destination = destination
        self.configuration = configuration
        self.expectedSwiftFileCount = expectedSwiftFileCount
        self.tags = tags
    }
}

/// A toolchain requirement recorded against one benchmark tool — not
/// inferred at run time, but a real fact read from that tool's own
/// repository (e.g. `Package.swift`'s `swift-tools-version` declaration).
/// Exists so a `blockedMissingToolchain` verdict is backed by a recorded
/// reason rather than only prose in a report.
public struct BenchmarkToolchainRequirement: Codable, Sendable, Equatable {
    public let toolName: String
    public let swiftToolsVersion: String
    public let minimumPlatform: String?
    public let source: String

    public init(toolName: String, swiftToolsVersion: String, minimumPlatform: String?, source: String) {
        self.toolName = toolName
        self.swiftToolsVersion = swiftToolsVersion
        self.minimumPlatform = minimumPlatform
        self.source = source
    }
}

/// The full corpus manifest — `Benchmarks/manifest.json` decodes to this.
public struct BenchmarkManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let projects: [BenchmarkProject]
    public let toolchainRequirements: [BenchmarkToolchainRequirement]

    public init(schemaVersion: Int, projects: [BenchmarkProject], toolchainRequirements: [BenchmarkToolchainRequirement] = []) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.toolchainRequirements = toolchainRequirements
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, toolchainRequirements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        projects = try container.decode([BenchmarkProject].self, forKey: .projects)
        toolchainRequirements = try container.decodeIfPresent([BenchmarkToolchainRequirement].self, forKey: .toolchainRequirements) ?? []
    }
}

public enum BenchmarkManifestError: Error, Equatable, CustomStringConvertible {
    /// Two projects in the same manifest share an `id` — every downstream
    /// result path (`results/raw/<id>-*.json`) is keyed on it, so a
    /// collision would silently overwrite one project's results with
    /// another's.
    case duplicateProjectID(String)
    /// `commitSHA` is not a full, well-formed 40-character hex SHA-1 — a
    /// short prefix or a branch/tag name accidentally left in `manifest.json`
    /// is exactly the "not actually pinned" mistake this check exists to
    /// catch before a clone ever starts.
    case malformedCommitSHA(projectID: String, value: String)
    case emptyRepositoryURL(projectID: String)

    public var description: String {
        switch self {
        case let .duplicateProjectID(id):
            "two projects in the manifest share the id \"\(id)\""
        case let .malformedCommitSHA(projectID, value):
            "project \"\(projectID)\" has a commitSHA that is not a full 40-character hex SHA: \"\(value)\""
        case let .emptyRepositoryURL(projectID):
            "project \"\(projectID)\" has an empty repositoryURL"
        }
    }
}

public extension BenchmarkManifest {
    /// Decodes and validates in one step — a manifest that merely parses as
    /// JSON but violates the pinning/uniqueness invariants above must never
    /// be treated as usable by any caller of this type.
    static func decode(from data: Data) throws -> BenchmarkManifest {
        let manifest = try JSONDecoder().decode(BenchmarkManifest.self, from: data)
        try validate(manifest)
        return manifest
    }

    static func load(from url: URL) throws -> BenchmarkManifest {
        try decode(from: Data(contentsOf: url))
    }

    internal static func validate(_ manifest: BenchmarkManifest) throws {
        var seenIDs: Set<String> = []
        for project in manifest.projects {
            guard seenIDs.insert(project.id).inserted else {
                throw BenchmarkManifestError.duplicateProjectID(project.id)
            }
            guard !project.repositoryURL.isEmpty else {
                throw BenchmarkManifestError.emptyRepositoryURL(projectID: project.id)
            }
            guard isFullHexSHA(project.commitSHA) else {
                throw BenchmarkManifestError.malformedCommitSHA(projectID: project.id, value: project.commitSHA)
            }
        }
    }

    /// A full 40-character SHA-1, lowercase hex only — a short prefix or a
    /// branch/tag name accidentally left in `manifest.json` must never pass.
    private static func isFullHexSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
