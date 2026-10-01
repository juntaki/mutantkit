import Foundation
import MutationExecution

/// Finds the local packages a SwiftPM project's build loads, by asking
/// SwiftPM.
///
/// `swift package dump-package` lists a manifest's direct dependencies only,
/// so the resolver evaluates each local package's manifest in turn. It never
/// resolves remote dependencies: those are fetched by the sandboxed build,
/// as they always were.
///
/// Every doubt fails closed. Output this version does not understand is
/// `manifestUnreadable`, never "no local packages": a missed package would
/// either break the sandboxed build or, worse, leave an input out of the
/// run's fingerprint.
public struct SwiftPMLocalDependencyResolver: LocalPackageDependencyResolving {
    let timeoutSeconds: Double
    let manifestDumps: SwiftPMManifestDumps
    let processRunner: ProcessRunner

    /// - Parameter manifestDumps: shared with `ProjectDetector.detect` so
    ///   the project's manifest is evaluated once per run.
    public init(timeoutSeconds: Double = 60, manifestDumps: SwiftPMManifestDumps = SwiftPMManifestDumps()) {
        self.init(timeoutSeconds: timeoutSeconds, manifestDumps: manifestDumps, processRunner: defaultProcessRunner)
    }

    /// - Parameter processRunner: the `ProcessRunner` seam, so a test can
    ///   script what `dump-package` prints.
    init(timeoutSeconds: Double, manifestDumps: SwiftPMManifestDumps, processRunner: @escaping ProcessRunner) {
        self.timeoutSeconds = timeoutSeconds
        self.manifestDumps = manifestDumps
        self.processRunner = processRunner
    }

    public func localPackageClosure(of packageRoot: URL) async throws -> [LocalPackageRoot] {
        // Evaluating at the canonical path means an alias above the project
        // (`/var` for `/private/var`, a symlinked checkout directory) is not
        // mistaken for a symlinked dependency below it.
        let root = CanonicalPath.resolve(packageRoot.path) ?? CanonicalPath.lexical(packageRoot.path)
        var visited: Set<String> = [root]
        var pending = [root]
        var found: [LocalPackageRoot] = []

        while let manifestDirectory = pending.popLast() {
            let output = try await manifestDumps.output(
                in: URL(fileURLWithPath: manifestDirectory, isDirectory: true),
                timeoutSeconds: timeoutSeconds,
                processRunner: processRunner
            )
            let reportedPaths = try Self.localDependencyPaths(in: output, directory: manifestDirectory)
            for reportedPath in reportedPaths {
                let package = try Self.package(at: reportedPath, declaredBy: manifestDirectory, projectRoot: root)
                guard visited.insert(package.canonicalPath).inserted else { continue }
                found.append(package)
                pending.append(package.canonicalPath)
            }
        }
        return found.sorted { $0.canonicalPath < $1.canonicalPath }
    }

    /// Checks one reported dependency against the disk.
    private static func package(at reportedPath: String, declaredBy: String, projectRoot: String) throws -> LocalPackageRoot {
        let lexical = CanonicalPath.lexical(reportedPath)
        let manifest = URL(fileURLWithPath: lexical).appendingPathComponent("Package.swift").path
        guard FileManager.default.fileExists(atPath: manifest),
              let canonical = CanonicalPath.resolve(lexical)
        else {
            throw LocalPackageResolutionError.missingLocalPackage(reportedPath: reportedPath, declaredBy: declaredBy)
        }
        // SwiftPM reports the lexical path, and a sandbox copy recreates a
        // symlink verbatim, so the copy's link would lead back to the
        // original tree (or nowhere). Refused until such paths are
        // materialized instead.
        guard canonical == lexical else {
            throw LocalPackageResolutionError.symlinkedLocalPackage(
                reportedPath: reportedPath, canonicalPath: canonical, declaredBy: declaredBy
            )
        }
        // A strict ancestor of the project: the sandbox places the project and
        // its packages side by side, and cannot place a package around it.
        // The project itself: a cycle back to it, which no build can satisfy.
        // Distinct from `visited`, which only tolerates cycles among packages
        // that are not the project.
        guard canonical != projectRoot else {
            throw LocalPackageResolutionError.localPackageCyclesToProject(
                reportedPath: reportedPath, projectRoot: projectRoot, declaredBy: declaredBy
            )
        }
        let containsProject = canonical == "/" ? projectRoot != "/" : projectRoot.hasPrefix(canonical + "/")
        guard !containsProject else {
            throw LocalPackageResolutionError.localPackageContainsProject(
                reportedPath: reportedPath, projectRoot: projectRoot, declaredBy: declaredBy
            )
        }
        return LocalPackageRoot(reportedPath: reportedPath, canonicalPath: canonical, declaredBy: declaredBy)
    }

    /// The `fileSystem` dependency paths in one `dump-package` output.
    ///
    /// Only `dependencies` is read. Each entry must be an object with exactly
    /// one key: `sourceControl` and `registry` are skipped, and `fileSystem`
    /// must be an array of exactly one element, which has an absolute string
    /// `path`. Anything else, including a missing `dependencies` key or an
    /// unknown dependency kind, is unreadable.
    static func localDependencyPaths(in output: Data, directory: String) throws -> [String] {
        func unreadable(_ detail: String) -> ProjectDetectionError {
            .manifestUnreadable(
                directory: directory,
                detail: "dump-package emitted JSON this version does not understand: \(detail)"
            )
        }

        let json = try? JSONSerialization.jsonObject(with: output)
        guard let manifest = json as? [String: Any] else {
            throw unreadable("the output is not a JSON object")
        }
        guard let dependencies = manifest["dependencies"] as? [Any] else {
            throw unreadable("there is no `dependencies` array")
        }

        return try dependencies.compactMap { entry -> String? in
            guard let entry = entry as? [String: Any], entry.count == 1, let (kind, value) = entry.first else {
                throw unreadable("a dependency is not an object with exactly one kind")
            }
            switch kind {
            case "sourceControl", "registry":
                return nil
            case "fileSystem":
                guard let details = value as? [Any], details.count == 1 else {
                    throw unreadable("a fileSystem dependency is not a one-element array")
                }
                guard let first = details[0] as? [String: Any],
                      let path = first["path"] as? String,
                      path.hasPrefix("/")
                else {
                    throw unreadable("a fileSystem dependency has no absolute `path`")
                }
                return path
            default:
                throw unreadable("unknown dependency kind `\(kind)`")
            }
        }
    }
}
