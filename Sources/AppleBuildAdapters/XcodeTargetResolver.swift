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
/// `.xcodeproj` only, deliberately: `.xcworkspace` (which can span more
/// than one `.xcodeproj`, each with its own `project.pbxproj`) is out of
/// scope for this pass and still falls back to isolated mode, same as
/// today.
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
    }

    /// One project-root-relative source file → every `SchemataTargetInfo`
    /// it belongs to, mirroring `SwiftPMTargetResolver.resolveTargetInfo`'s
    /// own shape exactly so `SchemataChunkPlanner.plan` and
    /// `SchemataRunOrchestration.classify` can treat both backends
    /// identically.
    public static func resolveTargetInfo(projectRoot: URL, timeoutSeconds: Double = 120) async throws -> [String: [SchemataTargetInfo]] {
        let xcodeprojURL = try locateXcodeproj(in: projectRoot)
        let pbxprojURL = xcodeprojURL.appendingPathComponent("project.pbxproj")
        let data: Data
        do {
            data = try Data(contentsOf: pbxprojURL)
        } catch {
            throw ResolutionError.pbxprojUnreadable(path: pbxprojURL.path, underlying: "\(error)")
        }

        let memberships = try Self.parseTargetMemberships(pbxprojData: data, pbxprojPath: pbxprojURL.path)
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
            for source in membership.sources {
                targetInfo[source, default: []].append(info)
            }
        }
        return targetInfo
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

    // MARK: - project.pbxproj parsing

    /// Parses `project.pbxproj` (old-style ASCII/"OpenStep" property list —
    /// `PropertyListSerialization` reads this format directly, no manual
    /// tokenizing needed) into one `TargetMembership` per `PBXNativeTarget`
    /// the project declares.
    static func parseTargetMemberships(pbxprojData: Data, pbxprojPath: String) throws -> [TargetMembership] {
        let root: [String: Any]
        do {
            var format = PropertyListSerialization.PropertyListFormat.openStep
            guard let decoded = try PropertyListSerialization.propertyList(
                from: pbxprojData, options: [], format: &format
            ) as? [String: Any] else {
                throw ResolutionError.malformedPbxproj(path: pbxprojPath, detail: "root is not a dictionary")
            }
            root = decoded
        } catch let error as ResolutionError {
            throw error
        } catch {
            throw ResolutionError.malformedPbxproj(path: pbxprojPath, detail: "\(error)")
        }

        guard let objects = root["objects"] as? [String: Any] else {
            throw ResolutionError.malformedPbxproj(path: pbxprojPath, detail: "no \"objects\" dictionary")
        }
        guard let rootObjectID = root["rootObject"] as? String, let project = objects[rootObjectID] as? [String: Any] else {
            throw ResolutionError.malformedPbxproj(path: pbxprojPath, detail: "no resolvable \"rootObject\" (PBXProject)")
        }
        guard let mainGroupID = project["mainGroup"] as? String else {
            throw ResolutionError.malformedPbxproj(path: pbxprojPath, detail: "PBXProject has no \"mainGroup\"")
        }

        // Every `PBXFileReference` reachable from `mainGroup`, resolved to
        // a project-root-relative path — computed once, up front, then
        // looked up per `PBXBuildFile` below, rather than re-walking the
        // group tree for every target.
        var filePaths: [String: String] = [:]
        walkGroup(id: mainGroupID, parentPath: [], objects: objects, filePaths: &filePaths)

        let targetIDs = project["targets"] as? [String] ?? []
        var memberships: [TargetMembership] = []
        for targetID in targetIDs {
            guard let target = objects[targetID] as? [String: Any], target["isa"] as? String == "PBXNativeTarget" else { continue }
            let name = target["name"] as? String ?? targetID
            let buildPhaseIDs = target["buildPhases"] as? [String] ?? []
            var sources: [String] = []
            for phaseID in buildPhaseIDs {
                guard let phase = objects[phaseID] as? [String: Any], phase["isa"] as? String == "PBXSourcesBuildPhase" else { continue }
                let buildFileIDs = phase["files"] as? [String] ?? []
                for buildFileID in buildFileIDs {
                    guard let buildFile = objects[buildFileID] as? [String: Any],
                          let fileRefID = buildFile["fileRef"] as? String,
                          let path = filePaths[fileRefID],
                          path.hasSuffix(".swift")
                    else { continue }
                    sources.append(path)
                }
            }
            memberships.append(TargetMembership(name: name, sources: sources))
        }
        return memberships
    }

    /// Recursively resolves every `PBXGroup`/`PBXFileReference` reachable
    /// from `id`, accounting for `sourceTree`:
    ///  - `"<group>"` (the common case): `path` is relative to the
    ///    *resolved* parent group's path — accumulate.
    ///  - `"SOURCE_ROOT"` (and no `sourceTree`, which Xcode treats the same
    ///    as `"<group>"` when a `path` is present without one): `path` is
    ///    relative to the project root directly, ignoring how deep in the
    ///    group hierarchy the reference sits.
    ///  - anything else (`"absolute"`, `"BUILT_PRODUCTS_DIR"`,
    ///    `"DEVELOPER_DIR"`, `"SDKROOT"`, and similar build-setting-rooted
    ///    trees): not a path this resolver can express as project-root-
    ///    relative — skipped, along with everything nested under it (never
    ///    guessed at, since a wrong path silently attributes a mutation to
    ///    the wrong target).
    ///
    /// Only `PBXGroup` is recursed into and only `PBXFileReference` is
    /// recorded — `PBXVariantGroup` (localized file variants) and
    /// `PBXFileSystemSynchronizedRootGroup` (Xcode 16's implicit,
    /// filesystem-enumerated groups, not used by either this repo's own
    /// fixture or the real, large production iOS project this resolver
    /// was built against)
    /// are the "exotic file reference types" the task scope explicitly
    /// defers.
    private static func walkGroup(id: String, parentPath: [String], objects: [String: Any], filePaths: inout [String: String]) {
        guard let object = objects[id] as? [String: Any], let isa = object["isa"] as? String else { return }
        let sourceTree = object["sourceTree"] as? String ?? "<group>"
        let path = object["path"] as? String
        guard let resolved = resolvedPath(sourceTree: sourceTree, path: path, parentPath: parentPath) else { return }

        switch isa {
        case "PBXGroup":
            for childID in object["children"] as? [String] ?? [] {
                walkGroup(id: childID, parentPath: resolved, objects: objects, filePaths: &filePaths)
            }
        case "PBXFileReference":
            filePaths[id] = resolved.joined(separator: "/")
        default:
            break
        }
    }

    private static func resolvedPath(sourceTree: String, path: String?, parentPath: [String]) -> [String]? {
        switch sourceTree {
        case "<group>":
            path.map { parentPath + [$0] } ?? parentPath
        case "SOURCE_ROOT":
            path.map { [$0] } ?? []
        default:
            nil
        }
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
