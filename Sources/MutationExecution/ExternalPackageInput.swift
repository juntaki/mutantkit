/// One local package outside the project, as an input to the run: where the
/// sandbox places it and what the sandbox copy of it contains.
public struct ExternalPackageInput: Sendable, Codable, Hashable {
    /// Its path below the layout root, e.g. "SwiftMapper"
    /// (`SandboxLayout.ExternalRoot.relativePath`).
    public let relativeIdentity: String
    /// A digest over every entry the sandbox copy of the package carries.
    public let contentDigest: String

    public init(relativeIdentity: String, contentDigest: String) {
        self.relativeIdentity = relativeIdentity
        self.contentDigest = contentDigest
    }
}
