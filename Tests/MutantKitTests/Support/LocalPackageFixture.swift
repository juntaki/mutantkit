import Foundation
import MutationExecution

/// Throwaway Swift package trees for the tests that pin how a sandbox must
/// treat local `.package(path:)` dependencies living outside the project
/// root.
///
/// Built at run time rather than checked in because several shapes need an
/// absolute path, or an absolute symlink target, that only exists once the
/// temporary directory does. The acceptance fixture
/// (`Fixtures/LocalPathDependencies`) is the checked-in counterpart for the
/// end-to-end runs.
///
/// Manifests declare package dependencies only, never target dependencies:
/// every assertion here goes through `swift package dump-package`, which
/// evaluates the manifest without resolving or building anything, so a
/// dependency needs no product wiring to be reported.
enum LocalPackageFixture {
    /// A fresh directory that stands in for the common parent of a project
    /// and its sibling packages.
    static func makeLayoutRoot(label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MutantKit-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `makeLayoutRoot`, spelled as `realpath` reports it, for tests whose
    /// absolute dependency paths must not pass through an alias such as
    /// `/var` -> `/private/var`.
    static func makeCanonicalLayoutRoot(label: String) throws -> URL {
        let root = try makeLayoutRoot(label: label)
        guard let canonical = CanonicalPath.resolve(root.path) else { return root }
        return URL(fileURLWithPath: canonical, isDirectory: true)
    }

    /// Writes a minimal package at `directory`: one library target with one
    /// source file, plus `.package(path:)` entries spelled exactly as given.
    static func writePackage(named name: String, at directory: URL, pathDependencies: [String] = []) throws {
        let sources = directory.appendingPathComponent("Sources/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let dependencies = pathDependencies
            .map { ".package(path: \(String(reflecting: $0)))" }
            .joined(separator: ", ")
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(
            name: "\(name)",
            products: [.library(name: "\(name)", targets: ["\(name)"])],
            dependencies: [\(dependencies)],
            targets: [.target(name: "\(name)")]
        )
        """
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data("public let marker\(name) = 1\n".utf8)
            .write(to: sources.appendingPathComponent("\(name).swift"))
    }

    /// The three-package shape the acceptance fixture also uses:
    /// `Core -> ../SwiftMapper -> ../Logging`. Returns the project root
    /// (`Core`).
    @discardableResult
    static func writeSiblingChain(in layoutRoot: URL) throws -> URL {
        let core = layoutRoot.appendingPathComponent("Core", isDirectory: true)
        try writePackage(named: "Core", at: core, pathDependencies: ["../SwiftMapper"])
        try writePackage(
            named: "SwiftMapper", at: layoutRoot.appendingPathComponent("SwiftMapper"), pathDependencies: ["../Logging"]
        )
        try writePackage(named: "Logging", at: layoutRoot.appendingPathComponent("Logging"))
        return core
    }

    /// The scratch root a real `mutantkit run` uses for `projectRoot`.
    static func scratchRoot(for projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".mutantkit/sandboxes", isDirectory: true)
    }

    /// One package SwiftPM would load, as seen from wherever the walk
    /// started.
    struct Dependency: CustomStringConvertible {
        /// Exactly what `dump-package` printed: absolute, lexical, symlinks
        /// not resolved.
        let reportedPath: String
        let exists: Bool
        /// Symlink-resolved, and only meaningful when `exists`.
        let canonicalPath: String

        var description: String {
            exists ? "\(reportedPath) -> \(canonicalPath)" : "\(reportedPath) (missing)"
        }
    }

    /// Every local package reachable from the manifest in `directory`,
    /// found by evaluating each manifest with the real toolchain and walking
    /// `fileSystem` dependencies transitively. A dependency that does not
    /// exist is recorded and not descended into.
    ///
    /// This is the test's own oracle, deliberately independent of the
    /// product's resolver: it asks SwiftPM what the sandboxed manifests
    /// reference, so it cannot agree with a wrong resolver by construction.
    static func localDependencyClosure(from directory: URL) async throws -> [Dependency] {
        var visited = Set<String>()
        var pending = [directory]
        var found: [Dependency] = []

        while let next = pending.popLast() {
            for reported in try await directLocalDependencies(of: next) {
                let url = URL(fileURLWithPath: reported)
                let exists = FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                found.append(Dependency(reportedPath: reported, exists: exists, canonicalPath: canonical))
                if exists, visited.insert(canonical).inserted {
                    pending.append(url)
                }
            }
        }
        return found
    }

    /// `true` when every local package in `closure` exists and resolves,
    /// after symlinks, to a location strictly inside `container`.
    static func isContained(_ closure: [Dependency], in container: URL) -> Bool {
        let root = container.resolvingSymlinksInPath().standardizedFileURL.path
        return closure.allSatisfy { $0.exists && $0.canonicalPath.hasPrefix(root + "/") }
    }

    /// The direct `fileSystem` dependency paths of one manifest.
    static func directLocalDependencies(of directory: URL) async throws -> [String] {
        let result = try await ProcessSupervisor.run(
            executable: "/usr/bin/xcrun",
            arguments: ["swift", "package", "dump-package"],
            workingDirectory: directory,
            timeoutSeconds: 120
        )
        guard result.succeeded, result.outputComplete else {
            throw FixtureError.dumpPackageFailed(
                directory: directory.path,
                standardError: String(decoding: result.standardError, as: UTF8.self)
            )
        }
        guard let manifest = try JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any],
              let dependencies = manifest["dependencies"] as? [[String: Any]]
        else {
            throw FixtureError.unexpectedManifestShape(directory: directory.path)
        }
        return dependencies.flatMap { dependency -> [String] in
            guard let fileSystem = dependency["fileSystem"] as? [[String: Any]] else { return [] }
            return fileSystem.compactMap { $0["path"] as? String }
        }
    }

    enum FixtureError: Error, CustomStringConvertible {
        case dumpPackageFailed(directory: String, standardError: String)
        case unexpectedManifestShape(directory: String)

        var description: String {
            switch self {
            case let .dumpPackageFailed(directory, standardError):
                "swift package dump-package failed in \(directory): \(standardError)"
            case let .unexpectedManifestShape(directory):
                "swift package dump-package in \(directory) printed JSON without a dependencies array"
            }
        }
    }
}
