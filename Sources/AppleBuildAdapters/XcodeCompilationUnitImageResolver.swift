import Foundation
import MutationExecution
import MutationModel

/// Every way the Xcode path refuses to map a requested target to a real
/// built image — fail-closed, matching `SwiftPMImageResolutionError`'s
/// discipline: an ambiguous or unproven mapping must never be resolved by
/// guessing.
public enum XcodeImageResolutionError: Error, CustomStringConvertible, Equatable {
    case showBuildSettingsFailed(target: String, diagnosis: String)
    case malformedBuildSettings(target: String, detail: String)
    /// `MACH_O_TYPE` names something this resolver has no built image for
    /// at all (a static library, most commonly) — its code is linked into
    /// whatever depends on it, but there is no artifact of its own to
    /// extract an `LC_UUID` from.
    case targetProducesNoOwnImage(target: String, machOType: String)
    case builtArtifactMissing(target: String, path: String)

    public var description: String {
        switch self {
        case let .showBuildSettingsFailed(target, diagnosis):
            "`xcodebuild -showBuildSettings -target \(target)` failed: \(diagnosis)"
        case let .malformedBuildSettings(target, detail):
            "could not parse build settings for target \(target): \(detail)"
        case let .targetProducesNoOwnImage(target, machOType):
            "target \(target) has MACH_O_TYPE \(machOType), which produces no image of its own to extract an LC_UUID from"
        case let .builtArtifactMissing(target, path):
            "target \(target)'s expected built artifact does not exist at \(path)"
        }
    }
}

/// Maps a requested Xcode target's real identity to the real built image
/// its code ends up in — by resolving that target's own real
/// `xcodebuild -showBuildSettings` output to an exact, on-disk artifact
/// path, never by enumerating `BUILT_PRODUCTS_DIR` and matching a bundle's
/// filename against the target's display name.
///
/// `-target` is deliberately never passed alongside an explicit
/// `-project`/`-workspace` and `-scheme` together — confirmed against a
/// real project (and reproducible with a bare `xcodebuild` invocation) that
/// this exact three-flag combination fails with "You cannot specify both a
/// scheme and targets," a genuine `xcodebuild` limitation, not a
/// configuration mistake. `-derivedDataPath` requires `-scheme` (or
/// `-testProductsPath`/`-xctestrun`) to resolve settings at all, so
/// `-scheme` alone (without `-target`) is used instead, and the per-target
/// entry this resolver needs is picked out of the returned array by exact
/// `target` name match — fail-closed the same way every other lookup in
/// this proof chain is, never `.first`.
public enum XcodeCompilationUnitImageResolver {
    struct BuildSettingsEntry: Decodable {
        let target: String
        let buildSettings: [String: String]
    }

    /// The build-invocation context `resolveArtifactPath` needs beyond the
    /// target it is resolving — bundled so the method itself stays within
    /// SwiftLint's parameter-count threshold, the same discipline
    /// `SchemataMutationRunner.EmbeddingContext` already uses.
    struct BuildSettingsContext: Sendable {
        let projectArguments: [String]
        let scheme: String
        let destination: String
        let derivedDataPath: URL
        let workspace: URL
        let timeoutSeconds: Double
    }

    private static func xcodeprojPath(from projectIdentity: String?) -> String? {
        guard let projectIdentity, projectIdentity.hasSuffix(".xcodeproj"),
              FileManager.default.fileExists(atPath: projectIdentity)
        else { return nil }
        return projectIdentity
    }

    /// `target`'s own settings, taken from the project that declares it with the primary
    /// entry's configuration and SDK, but with `BUILT_PRODUCTS_DIR` from the primary entry: that
    /// is where this scheme build (with its derived-data path) actually wrote the product.
    private static func targetSettings(
        target: String, projectPath: String, like primary: [String: String], context: BuildSettingsContext
    ) async throws -> [String: String] {
        guard let productsDirectory = primary["BUILT_PRODUCTS_DIR"] else {
            throw XcodeImageResolutionError.malformedBuildSettings(
                target: target, detail: "the scheme's primary entry has no BUILT_PRODUCTS_DIR"
            )
        }
        var arguments = ["-project", projectPath, "-target", target, "-showBuildSettings", "-json"]
        if let configuration = primary["CONFIGURATION"] { arguments += ["-configuration", configuration] }
        if let sdk = primary["SDK_NAME"] { arguments += ["-sdk", sdk] }
        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcodebuild, arguments: arguments,
                workingDirectory: context.workspace, timeoutSeconds: context.timeoutSeconds
            )
        } catch {
            throw XcodeImageResolutionError.showBuildSettingsFailed(target: target, diagnosis: "\(error)")
        }
        guard result.succeeded else {
            throw XcodeImageResolutionError.showBuildSettingsFailed(
                target: target, diagnosis: String(decoding: result.standardError, as: UTF8.self)
            )
        }
        let entries: [BuildSettingsEntry]
        do {
            entries = try JSONDecoder().decode([BuildSettingsEntry].self, from: result.standardOutput)
        } catch {
            throw XcodeImageResolutionError.malformedBuildSettings(target: target, detail: "\(error)")
        }
        let matches = entries.filter { $0.target == target }
        guard matches.count == 1, var settings = matches.first?.buildSettings else {
            throw XcodeImageResolutionError.malformedBuildSettings(
                target: target, detail: "expected exactly one buildSettings entry named \(target) in \(projectPath), found \(matches.count)"
            )
        }
        settings["BUILT_PRODUCTS_DIR"] = productsDirectory
        return settings
    }

    /// The scheme-wide build context (products directory, configuration, SDK) when every entry the scheme
    /// query returned agrees on it -- the entries then only differ in which target they describe, and a
    /// dependency target missing from the list can be placed in that same products directory. Disagreement
    /// (or an empty list) proves nothing and yields nil.
    private static func sharedBuildContext(of entries: [BuildSettingsEntry]) -> [String: String]? {
        guard let first = entries.first?.buildSettings else { return nil }
        let keys = ["BUILT_PRODUCTS_DIR", "CONFIGURATION", "SDK_NAME"]
        for entry in entries.dropFirst() where keys.contains(where: { entry.buildSettings[$0] != first[$0] }) { return nil }
        return first
    }

    private static func showBuildSettings(action: String?, context: BuildSettingsContext) async throws -> ProcessResult {
        let arguments = context.projectArguments + (action.map { [$0] } ?? []) + [
            "-showBuildSettings", "-scheme", context.scheme, "-destination", context.destination,
            "-derivedDataPath", context.derivedDataPath.path, "-json"
        ]
        return try await ProcessSupervisor.run(
            executable: ToolPaths.xcodebuild, arguments: arguments,
            workingDirectory: context.workspace, timeoutSeconds: context.timeoutSeconds
        )
    }

    static func resolveArtifactPath(
        target: String, projectIdentity: String? = nil, context: BuildSettingsContext
    ) async throws -> (path: URL, bundleName: String) {
        // The chunk is built with `build-for-testing`, so that action is asked first: a scheme's test action
        // can use another configuration than its build action (wikipedia-ios builds Debug but tests with
        // `Test`, and the plain query points at a `Debug-iphonesimulator` that was never written). A
        // test-only scheme (RxSwift's `AllTests-macOS`) has an empty Build action, so the plain query fails
        // there ("Supported platforms for the buildables in the current scheme is empty"); it is asked next
        // only if the build-for-testing query fails.
        let result: ProcessResult
        let showBuildSettingsStart = GateTimingRecorder.shared.now()
        do {
            var attempt = try await showBuildSettings(action: "build-for-testing", context: context)
            if !attempt.succeeded {
                let retry = try await showBuildSettings(action: nil, context: context)
                if retry.succeeded { attempt = retry }
            }
            result = attempt
        } catch {
            await GateTimingRecorder.shared.record(
                "receipt.showBuildSettings.failed", chunkID: target, start: showBuildSettingsStart
            )
            throw XcodeImageResolutionError.showBuildSettingsFailed(target: target, diagnosis: "\(error)")
        }
        await GateTimingRecorder.shared.record("receipt.showBuildSettings", chunkID: target, start: showBuildSettingsStart)
        guard result.succeeded else {
            throw XcodeImageResolutionError.showBuildSettingsFailed(
                target: target, diagnosis: String(decoding: result.standardError, as: UTF8.self)
            )
        }

        let entries: [BuildSettingsEntry]
        do {
            entries = try JSONDecoder().decode([BuildSettingsEntry].self, from: result.standardOutput)
        } catch {
            throw XcodeImageResolutionError.malformedBuildSettings(target: target, detail: "\(error)")
        }
        let matches = entries.filter { $0.target == target }
        var resolved: [String: String]
        if matches.count == 1, let only = matches.first {
            resolved = only.buildSettings
        } else if matches.isEmpty, let primary = Self.sharedBuildContext(of: entries),
                  let projectPath = Self.xcodeprojPath(from: projectIdentity) {
            // A scheme query lists only the scheme's primary target when its Build action is empty
            // (a test-only scheme such as RxSwift's `AllTests-macOS`): the requested target is a
            // dependency the scheme builds, not an entry. Its own settings are read from the
            // project that declares it, for the primary entry's configuration and SDK, and it is
            // placed in the products directory the scheme build actually used.
            resolved = try await targetSettings(target: target, projectPath: projectPath, like: primary, context: context)
        } else {
            throw XcodeImageResolutionError.malformedBuildSettings(
                target: target, detail: "expected exactly one buildSettings entry named \(target), found \(matches.count)"
            )
        }
        let settings = resolved

        // `staticlib`/`mh_object` targets produce no image of their own —
        // their compiled code is only ever observable inside whatever
        // links against them, which this resolver cannot assume without
        // real evidence of which built image that turned out to be.
        let machOType = settings["MACH_O_TYPE"] ?? ""
        guard machOType != "staticlib", machOType != "mh_object" else {
            throw XcodeImageResolutionError.targetProducesNoOwnImage(target: target, machOType: machOType)
        }

        guard
            let builtProductsDir = settings["BUILT_PRODUCTS_DIR"],
            let executablePath = settings["EXECUTABLE_PATH"],
            let wrapperName = settings["WRAPPER_NAME"] ?? settings["PRODUCT_NAME"]
        else {
            throw XcodeImageResolutionError.malformedBuildSettings(
                target: target, detail: "missing one of BUILT_PRODUCTS_DIR/EXECUTABLE_PATH/WRAPPER_NAME"
            )
        }

        let binaryPath = URL(fileURLWithPath: builtProductsDir).appendingPathComponent(executablePath)
        guard FileManager.default.fileExists(atPath: binaryPath.path) else {
            throw XcodeImageResolutionError.builtArtifactMissing(target: target, path: binaryPath.path)
        }

        // Xcode's "debug executable is a dylib" optimization
        // (`ENABLE_DEBUG_DYLIB`, on by default for Debug/Simulator app
        // targets) turns the on-disk main executable into a thin stub that
        // immediately loads a sibling `<executable>.debug.dylib` — every
        // compiled Swift/ObjC symbol, including whatever calls the schemata
        // runtime's `mutantkit_register_unit_v3`, actually executes from
        // that dylib, not the stub. `dladdr` on the runtime's own caller
        // therefore always resolves to the dylib's loaded image at test
        // time, so the receipt must record *that* file's `LC_UUID`, never
        // the stub's — otherwise this resolver would hand the verifier an
        // image identity the runtime can never actually report, no matter
        // how correct the build was (confirmed against a real app target:
        // the stub and its debug dylib carry two entirely different, real
        // `LC_UUID`s). Detected by real on-disk presence, not by trusting
        // `ENABLE_DEBUG_DYLIB`'s reported value — the naming convention
        // Xcode's own build system uses for this file is authoritative
        // over a build setting a caller could fail to thread through
        // correctly.
        let debugDylibPath = binaryPath.deletingLastPathComponent()
            .appendingPathComponent(binaryPath.lastPathComponent + ".debug.dylib")
        let resolvedBinaryPath = FileManager.default.fileExists(atPath: debugDylibPath.path) ? debugDylibPath : binaryPath

        let bundleName = URL(fileURLWithPath: wrapperName).deletingPathExtension().lastPathComponent
        return (resolvedBinaryPath, bundleName)
    }
}
