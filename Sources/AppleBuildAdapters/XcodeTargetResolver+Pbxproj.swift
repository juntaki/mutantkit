import Foundation

/// Shared, already-decoded state for reading one `project.pbxproj`.
private struct PbxprojContext {
    let objects: [String: Any]
    let filePaths: [String: String]
    let synchronizedGroupPaths: [String: String]
    let projectDirectory: URL
    let targetNameByProductReference: [String: String]

    func object(_ id: String) -> [String: Any]? {
        objects[id] as? [String: Any]
    }

    /// The exception sets of `group` that name `targetID`.
    func exceptions(ofGroup group: [String: Any], targetID: String) -> [[String: Any]] {
        (group["exceptions"] as? [String] ?? []).compactMap { exceptionID in
            guard let exception = object(exceptionID), exception["target"] as? String == targetID else { return nil }
            return exception
        }
    }

    /// Project-relative `.swift` paths a native target's `PBXSourcesBuildPhase` compiles.
    func buildPhaseSources(buildPhaseIDs: [String]) -> [String] {
        var sources: [String] = []
        for phaseID in buildPhaseIDs {
            guard let phase = object(phaseID), phase["isa"] as? String == "PBXSourcesBuildPhase" else { continue }
            let buildFileIDs = phase["files"] as? [String] ?? []
            for buildFileID in buildFileIDs {
                guard let buildFile = object(buildFileID),
                      let fileRefID = buildFile["fileRef"] as? String,
                      let path = filePaths[fileRefID],
                      path.hasSuffix(".swift")
                else { continue }
                sources.append(path)
            }
        }
        return sources
    }

    /// Xcode 16 folder references: every Swift file under the group's directory belongs to the
    /// target, except what an exception set lists for this very target.
    func synchronizedGroupSources(target: [String: Any], targetID: String) -> [String] {
        var sources: [String] = []
        for groupID in target["fileSystemSynchronizedGroups"] as? [String] ?? [] {
            guard let groupPath = synchronizedGroupPaths[groupID], let group = object(groupID) else { continue }
            var excluded: Set<String> = []
            for exception in exceptions(ofGroup: group, targetID: targetID) {
                excluded.formUnion(exception["membershipExceptions"] as? [String] ?? [])
            }
            sources.append(contentsOf: XcodeTargetResolver.swiftFiles(
                under: groupPath, projectDirectory: projectDirectory, excluding: excluded
            ))
        }
        return sources
    }

    /// A target that is not a member of a synchronized group but has an exception set on it owns
    /// exactly the files that set names (this is how an extension picks single files out of a folder
    /// the app target adopts wholesale).
    func exceptionGrantedSources(target: [String: Any], targetID: String) -> [String] {
        var sources: [String] = []
        let ownGroups = Set(target["fileSystemSynchronizedGroups"] as? [String] ?? [])
        for (groupID, groupPath) in synchronizedGroupPaths where !ownGroups.contains(groupID) {
            guard let group = object(groupID) else { continue }
            for exception in exceptions(ofGroup: group, targetID: targetID) {
                for relative in exception["membershipExceptions"] as? [String] ?? [] where relative.hasSuffix(".swift") {
                    let path = groupPath + "/" + relative
                    if FileManager.default.fileExists(atPath: projectDirectory.appendingPathComponent(path).path) {
                        sources.append(path)
                    }
                }
            }
        }
        return sources
    }

    /// Names of the targets listed in the target's own `dependencies` (`PBXTargetDependency`).
    func explicitDependencies(target: [String: Any]) -> [String] {
        var dependencies: [String] = []
        for dependencyID in target["dependencies"] as? [String] ?? [] {
            guard let dependency = object(dependencyID),
                  let dependencyTargetID = dependency["target"] as? String,
                  let dependencyTarget = object(dependencyTargetID),
                  let dependencyName = dependencyTarget["name"] as? String
            else { continue }
            dependencies.append(dependencyName)
        }
        return dependencies
    }

    /// Implicit dependencies: a scheme with `buildImplicitDependencies` builds whatever product this
    /// target links (a framework target the test bundle links without declaring a dependency on it).
    func implicitDependencies(buildPhaseIDs: [String], name: String) -> [String] {
        var dependencies: [String] = []
        for phaseID in buildPhaseIDs {
            guard let phase = object(phaseID), phase["isa"] as? String == "PBXFrameworksBuildPhase" else { continue }
            for buildFileID in phase["files"] as? [String] ?? [] {
                guard let buildFile = object(buildFileID),
                      let fileRefID = buildFile["fileRef"] as? String,
                      let linkedTarget = targetNameByProductReference[fileRefID], linkedTarget != name
                else { continue }
                dependencies.append(linkedTarget)
            }
        }
        return dependencies
    }

    func membership(targetID: String) -> XcodeTargetResolver.TargetMembership? {
        guard let target = object(targetID), target["isa"] as? String == "PBXNativeTarget" else { return nil }
        let name = target["name"] as? String ?? targetID
        let buildPhaseIDs = target["buildPhases"] as? [String] ?? []
        let sources = buildPhaseSources(buildPhaseIDs: buildPhaseIDs)
            + synchronizedGroupSources(target: target, targetID: targetID)
            + exceptionGrantedSources(target: target, targetID: targetID)
        let dependencies = explicitDependencies(target: target)
            + implicitDependencies(buildPhaseIDs: buildPhaseIDs, name: name)
        return XcodeTargetResolver.TargetMembership(name: name, sources: sources, dependencies: dependencies)
    }
}

extension XcodeTargetResolver {
    // MARK: - project.pbxproj parsing

    /// Parses `project.pbxproj` (old-style ASCII/"OpenStep" property list —
    /// `PropertyListSerialization` reads this format directly, no manual
    /// tokenizing needed) into one `TargetMembership` per `PBXNativeTarget`
    /// the project declares.
    static func parseTargetMemberships(pbxprojData: Data, pbxprojPath: String) throws -> [TargetMembership] {
        let root = try decodePbxprojRoot(pbxprojData: pbxprojData, pbxprojPath: pbxprojPath)
        let located = try locateProject(root: root, pbxprojPath: pbxprojPath)
        let objects = located.objects
        let project = located.project

        // Every `PBXFileReference` reachable from `mainGroup`, resolved to
        // a project-root-relative path — computed once, up front, then
        // looked up per `PBXBuildFile`, rather than re-walking the
        // group tree for every target.
        var filePaths: [String: String] = [:]
        var synchronizedGroupPaths: [String: String] = [:]
        walkGroup(
            id: located.mainGroupID, parentPath: [], objects: objects, filePaths: &filePaths,
            synchronizedGroupPaths: &synchronizedGroupPaths
        )
        let projectDirectory = URL(fileURLWithPath: pbxprojPath).deletingLastPathComponent().deletingLastPathComponent()

        let targetIDs = project["targets"] as? [String] ?? []
        let context = PbxprojContext(
            objects: objects, filePaths: filePaths, synchronizedGroupPaths: synchronizedGroupPaths,
            projectDirectory: projectDirectory,
            targetNameByProductReference: productReferenceMap(objects: objects, targetIDs: targetIDs)
        )
        return targetIDs.compactMap { context.membership(targetID: $0) }
    }

    private static func decodePbxprojRoot(pbxprojData: Data, pbxprojPath: String) throws -> [String: Any] {
        do {
            var format = PropertyListSerialization.PropertyListFormat.openStep
            guard let decoded = try PropertyListSerialization.propertyList(
                from: pbxprojData, options: [], format: &format
            ) as? [String: Any] else {
                throw ResolutionError.malformedPbxproj(path: pbxprojPath, detail: "root is not a dictionary")
            }
            return decoded
        } catch let error as ResolutionError {
            throw error
        } catch {
            throw ResolutionError.malformedPbxproj(path: pbxprojPath, detail: "\(error)")
        }
    }

    private struct LocatedProject {
        let objects: [String: Any]
        let project: [String: Any]
        let mainGroupID: String
    }

    private static func locateProject(root: [String: Any], pbxprojPath: String) throws -> LocatedProject {
        guard let objects = root["objects"] as? [String: Any] else {
            throw ResolutionError.malformedPbxproj(path: pbxprojPath, detail: "no \"objects\" dictionary")
        }
        guard let rootObjectID = root["rootObject"] as? String, let project = objects[rootObjectID] as? [String: Any] else {
            throw ResolutionError.malformedPbxproj(path: pbxprojPath, detail: "no resolvable \"rootObject\" (PBXProject)")
        }
        guard let mainGroupID = project["mainGroup"] as? String else {
            throw ResolutionError.malformedPbxproj(path: pbxprojPath, detail: "PBXProject has no \"mainGroup\"")
        }
        return LocatedProject(objects: objects, project: project, mainGroupID: mainGroupID)
    }

    private static func productReferenceMap(objects: [String: Any], targetIDs: [String]) -> [String: String] {
        var targetNameByProductReference: [String: String] = [:]
        for targetID in targetIDs {
            guard let target = objects[targetID] as? [String: Any], target["isa"] as? String == "PBXNativeTarget",
                  let productReference = target["productReference"] as? String, let name = target["name"] as? String
            else { continue }
            targetNameByProductReference[productReference] = name
        }
        return targetNameByProductReference
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
    /// Project-relative paths of the `.swift` files below `groupPath`, minus `excluded` (paths relative
    /// to the group). Hidden entries and nested bundles/packages are not traversed into.
    static func swiftFiles(under groupPath: String, projectDirectory: URL, excluding excluded: Set<String>) -> [String] {
        let root = projectDirectory.appendingPathComponent(groupPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let rootComponents = root.resolvingSymlinksInPath().pathComponents
        var found: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
            guard !excluded.contains(relative) else { continue }
            found.append(groupPath + "/" + relative)
        }
        return found.sorted()
    }

    private static func walkGroup(
        id: String, parentPath: [String], objects: [String: Any], filePaths: inout [String: String],
        synchronizedGroupPaths: inout [String: String]
    ) {
        guard let object = objects[id] as? [String: Any], let isa = object["isa"] as? String else { return }
        let sourceTree = object["sourceTree"] as? String ?? "<group>"
        let path = object["path"] as? String
        guard let resolved = resolvedPath(sourceTree: sourceTree, path: path, parentPath: parentPath) else { return }

        switch isa {
        case "PBXGroup":
            for childID in object["children"] as? [String] ?? [] {
                walkGroup(
                    id: childID, parentPath: resolved, objects: objects, filePaths: &filePaths,
                    synchronizedGroupPaths: &synchronizedGroupPaths
                )
            }
        case "PBXFileSystemSynchronizedRootGroup":
            synchronizedGroupPaths[id] = resolved.joined(separator: "/")
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
}
