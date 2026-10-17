import Foundation
import MutationExecution
import MutationModel
import MutationPlanner

/// Resolves which `.xcodeproj` native target/module/product each source
/// file belongs to — the Xcode counterpart to `SwiftPMTargetResolver`,
/// filling the gap that otherwise made schemata classification silently
/// degrade to 100% isolated mode for every pure Xcode project (no
/// `Package.swift` for `swift package describe` to read).
///
/// A project directory holds one `.xcodeproj` (`resolveTargetInfo(projectRoot:)`);
/// a workspace can span several, each with its own `project.pbxproj`
/// (`resolveWorkspaceTargetInfo(projectRoot:)`, the multi-image build receipt): the member projects are read from
/// `contents.xcworkspacedata`, each resolved exactly as a lone project is, and source paths
/// are re-rooted at the workspace directory. A target keeps its own project's identity, so
/// same-named targets in different member projects stay distinct.
///
/// Two data sources, combined:
///  1. `project.pbxproj` itself — parsed as an old-style ("OpenStep"/ASCII)
///     property list, which is the format real Xcode projects (including
///     this repo's own `Fixtures/XcodeAppWithUITests` and a real,
///     `objectVersion = 77` Xcode 16 project) are written in, not XML or
///     binary — for source-file-to-target membership: which
///     `PBXNativeTarget`s exist, and which files each one's
///     `PBXSourcesBuildPhase` compiles.
///  2. `xcodebuild -showBuildSettings -json -project <path> -target
///     <name>` per target, for `PRODUCT_MODULE_NAME`/`PRODUCT_NAME` — the
///     module/product half `SchemataTargetInfo` needs, which nothing in
///     `project.pbxproj` itself states directly (they can be overridden by
///     build settings, an xcconfig, or left at Xcode's own defaults).
public enum XcodeTargetResolver {
    public enum ResolutionError: Error, CustomStringConvertible {
        case projectNotFound(directory: String)
        case pbxprojUnreadable(path: String, underlying: String)
        case malformedPbxproj(path: String, detail: String)
        case showBuildSettingsFailed(target: String, diagnosis: String)
        case malformedBuildSettings(target: String, detail: String)
        case workspaceNotFound(directory: String)
        case workspaceUnreadable(path: String, underlying: String)
        case workspaceHasNoProjects(path: String)
        /// The run's scheme is unnamed or its definition cannot be read, so which targets it
        /// builds cannot be proven.
        case schemeNotProvable(scheme: String?, detail: String)

        public var description: String {
            switch self {
            case let .projectNotFound(directory):
                "no .xcodeproj found in \(directory)"
            case let .pbxprojUnreadable(path, underlying):
                "could not read \(path): \(underlying)"
            case let .malformedPbxproj(path, detail):
                "\(path) is not a property list this parser understands: \(detail)"
            case let .showBuildSettingsFailed(target, diagnosis):
                "`xcodebuild -showBuildSettings` failed for target \(target): \(diagnosis)"
            case let .malformedBuildSettings(target, detail):
                "`xcodebuild -showBuildSettings -json` output for target \(target) was not the shape expected: \(detail)"
            case let .workspaceNotFound(directory):
                "no .xcworkspace found in \(directory)"
            case let .workspaceUnreadable(path, underlying):
                "could not read the workspace at \(path): \(underlying)"
            case let .workspaceHasNoProjects(path):
                "the workspace at \(path) references no .xcodeproj"
            case let .schemeNotProvable(scheme, detail):
                "the targets built by scheme \(scheme.map { "'\($0)'" } ?? "(none configured)") cannot be proven: \(detail)"
            }
        }
    }

    /// One native target's source membership, parsed from `project.pbxproj`
    /// alone — project-root-relative paths, before `xcodebuild` has been
    /// asked for module/product names. Exposed (rather than kept private)
    /// so the pbxproj-parsing half can be unit tested without spawning a
    /// process.
    struct TargetMembership: Equatable {
        let name: String
        /// Project-root-relative source paths this target's
        /// `PBXSourcesBuildPhase` compiles. `.swift` only — the common
        /// case this v1 handles; a `PBXBuildFile` whose `fileRef` is not a
        /// plain `PBXFileReference` to a `.swift` file (a `PBXVariantGroup`
        /// for localized files, a non-Swift source, an unresolvable
        /// `sourceTree`) is silently skipped rather than guessed at.
        let sources: [String]
        /// Names of the native targets this one depends on (`PBXTargetDependency`), which Xcode
        /// builds first whenever this target is built.
        var dependencies: [String] = []
    }

    /// One project-root-relative source file → every `SchemataTargetInfo`
    /// it belongs to, mirroring `SwiftPMTargetResolver.resolveTargetInfo`'s
    /// own shape exactly so `SchemataChunkPlanner.plan` and
    /// `SchemataRunOrchestration.classify` can treat both backends
    /// identically.
    ///
    public static func resolveTargetInfo(projectRoot: URL, timeoutSeconds: Double = 120) async throws -> [String: [SchemataTargetInfo]] {
        let xcodeprojURL = try locateXcodeproj(in: projectRoot)
        return try await resolveMembership(
            xcodeprojURL: xcodeprojURL, relativeTo: projectRoot, scheme: nil, extraSchemeDirectories: [], timeoutSeconds: timeoutSeconds
        ).targetInfo
    }

    /// What a run's scheme can reach: the memberships of the targets it builds, and the sources
    /// that belong only to targets it does not.
    public struct SchemeScopedResolution: Sendable {
        public let targetInfo: [String: [SchemataTargetInfo]]
        /// Sources compiled only by targets the scheme never builds: no test run can reach them,
        /// so they get a per-mutation isolated fallback rather than a chunk of their own.
        public let filesOutsideScheme: Set<String>
    }

    /// `resolveTargetInfo` restricted to the targets `scheme` builds (its Build/Test action
    /// entries plus their dependency closure). A source shared with a target the scheme never
    /// builds would otherwise be embedded for that target too, and that chunk could never be
    /// exercised. Fail-closed: a missing scheme name or definition throws `schemeNotProvable`
    /// instead of falling back to every target.
    public static func resolveSchemeScopedTargetInfo(
        projectRoot: URL, scheme: String?, timeoutSeconds: Double = 120
    ) async throws -> SchemeScopedResolution {
        let xcodeprojURL = try locateXcodeproj(in: projectRoot)
        return try await resolveMembership(
            xcodeprojURL: xcodeprojURL, relativeTo: projectRoot, scheme: .required(scheme),
            extraSchemeDirectories: [], timeoutSeconds: timeoutSeconds
        )
    }

    /// Every member `.xcodeproj` of the workspace in `projectRoot`, resolved and merged. A member
    /// that cannot be resolved (unreadable pbxproj, `xcodebuild` failing for one of its targets)
    /// is skipped with a printed warning rather than failing the whole run: its files then have
    /// no target and fall back to isolated execution, which is safe; nothing is ever attributed
    /// to a guessed target.
    public static func resolveWorkspaceTargetInfo(
        projectRoot: URL, timeoutSeconds: Double = 120
    ) async throws -> [String: [SchemataTargetInfo]] {
        try await resolveWorkspace(projectRoot: projectRoot, scheme: nil, timeoutSeconds: timeoutSeconds).targetInfo
    }

    /// Workspace counterpart of `resolveSchemeScopedTargetInfo`; the scheme may live in the
    /// workspace's own `xcshareddata` or in any member project.
    public static func resolveSchemeScopedWorkspaceTargetInfo(
        projectRoot: URL, scheme: String?, timeoutSeconds: Double = 120
    ) async throws -> SchemeScopedResolution {
        try await resolveWorkspace(projectRoot: projectRoot, scheme: .required(scheme), timeoutSeconds: timeoutSeconds)
    }

    enum SchemeScope {
        case required(String?)
    }

    private static func resolveWorkspace(
        projectRoot: URL, scheme: SchemeScope?, timeoutSeconds: Double
    ) async throws -> SchemeScopedResolution {
        let workspaceURL = try locateXcworkspace(in: projectRoot)
        let dataURL = workspaceURL.appendingPathComponent("contents.xcworkspacedata")
        let data: Data
        do {
            data = try Data(contentsOf: dataURL)
        } catch {
            throw ResolutionError.workspaceUnreadable(path: dataURL.path, underlying: "\(error)")
        }
        let members = try Self.parseWorkspaceMemberProjects(
            workspaceData: data, workspaceContainer: workspaceURL.deletingLastPathComponent(), workspacePath: dataURL.path
        )
        guard !members.isEmpty else { throw ResolutionError.workspaceHasNoProjects(path: workspaceURL.path) }

        var merged: [String: [SchemataTargetInfo]] = [:]
        var outside: Set<String> = []
        var proven = scheme == nil
        var lastSchemeError: Error?
        for member in members {
            do {
                let resolution = try await resolveMembership(
                    xcodeprojURL: member, relativeTo: projectRoot, scheme: scheme,
                    extraSchemeDirectories: [workspaceURL], timeoutSeconds: timeoutSeconds
                )
                proven = true
                for (source, targets) in resolution.targetInfo { merged[source, default: []].append(contentsOf: targets) }
                outside.formUnion(resolution.filesOutsideScheme)
            } catch let error as ResolutionError {
                if case .schemeNotProvable = error { lastSchemeError = error }
                print("! Schemata target resolution skipped \(member.lastPathComponent) in the workspace (\(error)); its files will run in isolated mode.")
            }
        }
        // Every member failing to prove the scheme means nothing can be attributed to what it builds.
        if !proven, let lastSchemeError { throw lastSchemeError }
        return SchemeScopedResolution(targetInfo: merged, filesOutsideScheme: outside.subtracting(merged.keys))
    }

    /// Resolves one `.xcodeproj`. Source paths are re-rooted from the project's own directory to
    /// `projectRoot` (a no-op when the project sits directly in it).
    static func resolveMembership(
        xcodeprojURL: URL, relativeTo projectRoot: URL, scheme: SchemeScope?, extraSchemeDirectories: [URL], timeoutSeconds: Double
    ) async throws -> SchemeScopedResolution {
        let pbxprojURL = xcodeprojURL.appendingPathComponent("project.pbxproj")
        let data: Data
        do {
            data = try Data(contentsOf: pbxprojURL)
        } catch {
            throw ResolutionError.pbxprojUnreadable(path: pbxprojURL.path, underlying: "\(error)")
        }

        var memberships = try Self.parseTargetMemberships(pbxprojData: data, pbxprojPath: pbxprojURL.path)
        var unbuiltSources: Set<String> = []
        if case let .required(schemeName) = scheme {
            let built = try schemeBuiltTargets(
                scheme: schemeName, schemeContainers: [xcodeprojURL] + extraSchemeDirectories, memberships: memberships
            )
            for membership in memberships where !built.contains(membership.name) {
                unbuiltSources.formUnion(membership.sources.map {
                    Self.rerooted($0, projectDirectory: xcodeprojURL.deletingLastPathComponent(), root: projectRoot)
                })
            }
            memberships = memberships.filter { built.contains($0.name) }
        }
        let projectIdentity = xcodeprojURL.resolvingSymlinksInPath().standardizedFileURL.path

        var targetInfo: [String: [SchemataTargetInfo]] = [:]
        for membership in memberships {
            let showBuildSettingsStart = GateTimingRecorder.shared.now()
            let settings = try await showBuildSettings(
                xcodeprojURL: xcodeprojURL, target: membership.name, timeoutSeconds: timeoutSeconds
            )
            await GateTimingRecorder.shared.record(
                "targetResolver.showBuildSettings", chunkID: membership.name, start: showBuildSettingsStart
            )
            let info = SchemataTargetInfo(
                projectIdentity: projectIdentity, target: membership.name,
                module: settings.moduleName, product: settings.productName
            )
            let projectDirectory = xcodeprojURL.deletingLastPathComponent()
            for source in membership.sources {
                targetInfo[Self.rerooted(source, projectDirectory: projectDirectory, root: projectRoot), default: []]
                    .append(info)
            }
        }
        return SchemeScopedResolution(targetInfo: targetInfo, filesOutsideScheme: unbuiltSources.subtracting(targetInfo.keys))
    }

    /// The targets `scheme` builds: those its actions name plus everything they depend on.
    /// Throws `schemeNotProvable` when the scheme is unnamed, has no readable definition in any
    /// of `schemeContainers` (`.xcodeproj`/`.xcworkspace` bundles), or does not parse -- never
    /// "all targets". An empty set is a valid answer (the scheme lives elsewhere in a workspace
    /// and names nothing of this project).
    static func schemeBuiltTargets(
        scheme: String?, schemeContainers: [URL], memberships: [TargetMembership]
    ) throws -> Set<String> {
        guard let scheme, !scheme.isEmpty else {
            throw ResolutionError.schemeNotProvable(scheme: scheme, detail: "project.scheme is not set")
        }
        let fileName = "\(scheme).xcscheme"
        var candidates: [URL] = []
        for container in schemeContainers {
            candidates.append(container.appendingPathComponent("xcshareddata/xcschemes/\(fileName)"))
            let users = (try? FileManager.default.contentsOfDirectory(
                at: container.appendingPathComponent("xcuserdata"), includingPropertiesForKeys: nil
            )) ?? []
            candidates.append(contentsOf: users.map { $0.appendingPathComponent("xcschemes/\(fileName)") })
        }
        guard let data = candidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first else {
            throw ResolutionError.schemeNotProvable(scheme: scheme, detail: "no \(fileName) in a shared or user scheme directory")
        }
        let collector = SchemeBlueprintCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else {
            throw ResolutionError.schemeNotProvable(scheme: scheme, detail: "\(fileName) is not valid XML")
        }
        let known = Set(memberships.map(\.name))
        var pending = collector.names.filter(known.contains)
        let dependencies = Dictionary(memberships.map { ($0.name, $0.dependencies) }, uniquingKeysWith: { $0 + $1 })
        var built: Set<String> = []
        while let next = pending.popLast() {
            guard built.insert(next).inserted else { continue }
            pending.append(contentsOf: dependencies[next] ?? [])
        }
        return built
    }

    /// Collects the `BlueprintName` of every buildable the scheme's actions reference.
    private final class SchemeBlueprintCollector: NSObject, XMLParserDelegate {
        private(set) var names: [String] = []
        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            if elementName == "BuildableReference", let name = attributeDict["BlueprintName"] { names.append(name) }
        }
    }

    /// `path` (relative to `projectDirectory`) expressed relative to `root`.
    static func rerooted(_ path: String, projectDirectory: URL, root: URL) -> String {
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let directoryComponents = projectDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard directoryComponents.starts(with: rootComponents), directoryComponents.count > rootComponents.count else { return path }
        return (directoryComponents.dropFirst(rootComponents.count) + [path]).joined(separator: "/")
    }

    private static func locateXcworkspace(in projectRoot: URL) throws -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: nil)) ?? []
        guard let found = contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first(where: { $0.pathExtension == "xcworkspace" })
        else { throw ResolutionError.workspaceNotFound(directory: projectRoot.path) }
        return found
    }

    /// The first (only, for the single-project-directory shape this
    /// resolver supports) `.xcodeproj` directly inside `projectRoot` —
    /// mirrors `AppleAdapterFactory.locateProjectFile`'s own non-recursive
    /// directory scan, so detection and classification agree on which
    /// project file a run means.
    private static func locateXcodeproj(in projectRoot: URL) throws -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: projectRoot, includingPropertiesForKeys: nil
        )) ?? []
        guard let found = contents.first(where: { $0.pathExtension == "xcodeproj" }) else {
            throw ResolutionError.projectNotFound(directory: projectRoot.path)
        }
        return found
    }

    // MARK: - xcodebuild -showBuildSettings

    struct ResolvedSettings {
        let moduleName: String
        let productName: String
    }

    /// Per-target `PRODUCT_MODULE_NAME`/`PRODUCT_NAME`, via `-target`
    /// rather than `-scheme`: a scheme can build more than one target
    /// (an app plus its test targets), and `-showBuildSettings` against a
    /// scheme reports settings for the scheme's primary target only. No
    /// `-destination` is passed — module/product naming does not depend on
    /// which simulator would run it, and resolving one is the slow part of
    /// an `xcodebuild` invocation this classification-only step has no
    /// need to pay for.
    private static func showBuildSettings(
        xcodeprojURL: URL, target: String, timeoutSeconds: Double
    ) async throws -> ResolvedSettings {
        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcodebuild,
                arguments: ["-showBuildSettings", "-json", "-project", xcodeprojURL.path, "-target", target],
                workingDirectory: xcodeprojURL.deletingLastPathComponent(),
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            throw ResolutionError.showBuildSettingsFailed(target: target, diagnosis: "\(error)")
        }
        guard result.succeeded else {
            throw ResolutionError.showBuildSettingsFailed(
                target: target, diagnosis: String(decoding: result.standardError, as: UTF8.self)
            )
        }
        return try Self.parseBuildSettings(result.standardOutput, target: target)
    }

    static func parseBuildSettings(_ data: Data, target: String) throws -> ResolvedSettings {
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ResolutionError.malformedBuildSettings(target: target, detail: "\(error)")
        }
        guard let array = decoded as? [[String: Any]], let first = array.first,
              let buildSettings = first["buildSettings"] as? [String: Any]
        else {
            throw ResolutionError.malformedBuildSettings(target: target, detail: "no [{\"buildSettings\": {...}}] entry")
        }
        guard let moduleName = buildSettings["PRODUCT_MODULE_NAME"] as? String else {
            throw ResolutionError.malformedBuildSettings(target: target, detail: "no PRODUCT_MODULE_NAME")
        }
        let productName = buildSettings["PRODUCT_NAME"] as? String ?? moduleName
        return ResolvedSettings(moduleName: moduleName, productName: productName)
    }
}
