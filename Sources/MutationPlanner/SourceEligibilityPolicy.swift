import MutationModel

/// The single answer to "may this repository-relative path be a mutation
/// source?", shared by the filesystem walk and by prospective membership
/// checks so the two can never disagree.
///
/// Two layers, in this order:
///
/// 1. **Mandatory policy** — fixed, not configurable: build products and
///    vendored directories, documentation catalogs, package manifests and
///    non-Swift files. Applies to every ancestor directory of a path, so a file
///    under `.build/` is never eligible however it is reached.
/// 2. **User filter** — `sources.include` / `sources.exclude` (an exclude on a
///    directory covers everything beneath it, see `Glob.matchesAny`).
public struct SourceEligibilityPolicy: Sendable {
    /// Why a path is not eligible. `admitted` is the only eligible verdict.
    public enum Verdict: Equatable, Sendable {
        case admitted
        case prunedBuildOrVendorDirectory(String)
        case prunedDocumentationCatalog(String)
        case packageManifest
        case notSwiftSource
        case excludedByUser
        case notIncludedByUser

        public var isAdmitted: Bool { self == .admitted }
    }

    /// Directories never descended into, whatever the config says.
    ///
    /// These hold build products and vendored code. Mutating them is meaningless
    /// at best; walking them is minutes of I/O on a large checkout.
    public static let prunedDirectoryNames: Set<String> = [
        ".build", ".git", "DerivedData", "Pods", "Carthage"
    ]

    /// Directory-name suffixes never descended into, whatever the config says.
    ///
    /// A `.docc` catalog's tutorial and code-sample `.swift` files are never
    /// part of a compilation. This is a fixed rule rather than a default in
    /// `sources.exclude` because every default there is part of the resolved
    /// configuration and therefore of `configurationHash`.
    public static let prunedDirectorySuffixes: [String] = [".docc"]

    private let settings: SourceSettings

    public init(settings: SourceSettings) {
        self.settings = settings
    }

    /// Whether the walk may descend into the directory at `relativePath`.
    /// Pruning is safe because every verdict below is also applied to each
    /// file via its ancestors — nothing beneath a pruned directory could have
    /// been admitted anyway.
    public func directoryVerdict(relativePath: String) -> Verdict {
        if let mandatory = Self.mandatoryDirectoryVerdict(name: Self.lastComponent(of: relativePath)) {
            return mandatory
        }
        if Glob.matchesAny(patterns: settings.exclude, path: relativePath) { return .excludedByUser }
        // Nothing beneath a directory that no include pattern can reach is
        // eligible, so it is neither walked nor able to fail the walk.
        guard settings.include.contains(where: { Glob.canMatchBeneath(pattern: $0, directory: relativePath) }) else {
            return .notIncludedByUser
        }
        return .admitted
    }

    /// Whether the file at `relativePath` is an eligible mutation source.
    public func fileVerdict(relativePath: String) -> Verdict {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.last else { return .notSwiftSource }

        for ancestor in components.dropLast() {
            if let mandatory = Self.mandatoryDirectoryVerdict(name: ancestor) { return mandatory }
        }
        guard name.hasSuffix(".swift") else { return .notSwiftSource }
        guard !Self.isPackageManifestName(name) else { return .packageManifest }
        guard Glob.matchesAny(patterns: settings.include, path: relativePath) else { return .notIncludedByUser }
        guard !Glob.matchesAny(patterns: settings.exclude, path: relativePath) else { return .excludedByUser }
        return .admitted
    }

    private static func mandatoryDirectoryVerdict(name: String) -> Verdict? {
        if prunedDirectoryNames.contains(name) { return .prunedBuildOrVendorDirectory(name) }
        if prunedDirectorySuffixes.contains(where: { name.hasSuffix($0) }) {
            return .prunedDocumentationCatalog(name)
        }
        return nil
    }

    private static func lastComponent(of relativePath: String) -> String {
        relativePath.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? relativePath
    }

    /// Whether `name` (a bare file name, not a path) is a SwiftPM package
    /// manifest — `Package.swift` itself, or one of its version-specific
    /// variants (`Package@swift-<major>[.<minor>[.<patch>]].swift`, SwiftPM's
    /// own documented "version-specific manifest selection" naming).
    ///
    /// Checked unconditionally, regardless of `sources.include`/`exclude`:
    /// `PackageManifestConfirmationRetesting`
    /// (`Sources/MutationExecution/Adapters.swift`) depends on `projectRoot`'s
    /// `Package.swift` being invariant across every mutant of one run, so a
    /// user who broadens `sources.include` to the project root must never be
    /// able to turn the manifest into a mutation candidate.
    static func isPackageManifestName(_ name: String) -> Bool {
        if name == "Package.swift" { return true }
        let prefix = "Package@swift-"
        let suffix = ".swift"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else {
            return false
        }
        let versionPart = name.dropFirst(prefix.count).dropLast(suffix.count)
        let components = versionPart.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 3 else { return false }
        return components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
