import AppleBuildAdapters
import Foundation
import MutationModel

/// The auto-detection `mutantkit init` performs before writing a template,
/// factored out so `mutantkit setup` can run the identical detection and
/// decide what to do with the result — write it, preview it, or report what
/// is still unresolved — without duplicating `init`'s own detection-to-
/// template logic.
///
/// Split deliberately into an I/O-performing `detect(root:)` and a pure
/// `build(...)`: `build` takes only the primitive facts detection already
/// produced, so its decisions (what to narrate, whether a scheme or test
/// target is still ambiguous, what template results) can be exercised
/// directly in a unit test without touching the filesystem, `xcodebuild`, or
/// `simctl`.
enum ProjectDetectionPlan {
    /// The primitive facts `detect(root:)` gathers, bundled so `build(_:)`
    /// takes one parameter instead of eight — the raw output of
    /// `ProjectDetector.detect`/`XcodeConfigDetector.detect`, unpacked.
    struct Input {
        let kind: ProjectKind?
        let reason: String?
        let swiftPMTestTargets: [String]
        let scheme: String?
        let schemeCandidates: [String]
        let xcodeTestTargets: [String]
        let destination: String?
        let destinationDiscoveryFailed: Bool
    }

    struct Result {
        let template: String
        /// Narration lines, in the order `init` has always printed them.
        let summaryLines: [String]
        /// Mirrors `init`'s original `anyTestTargets` check — false only when
        /// nothing at all resolved `tests.targets`, the one case that still
        /// needs a human before `plan`/`run` are scoped to anything.
        let hasTestTargets: Bool
        /// True when more than one Xcode scheme exists and none could be
        /// chosen automatically — `init`/`setup` must not guess which one to
        /// build.
        let schemeAmbiguous: Bool
        let destinationDiscoveryFailed: Bool
    }

    static func detect(root: URL) async -> Result {
        // Detection can legitimately fail — an empty directory, a project kind
        // we do not recognise. That is not a reason to refuse to write a
        // config; it is a reason to write one the user has to finish, and to
        // say so.
        let detection = try? await ProjectDetector.detect(in: root)
        let swiftPMTestTargets = await detectedSwiftPMTestTargets(kind: detection?.kind, projectRoot: root)

        // Phase C13: real Xcode/workspace scheme + destination detection —
        // `xcodeDetection` is `nil`-scheme/empty-testTargets/nil-destination
        // for every other kind, so this call is a no-op cost there.
        let xcodeDetection = await XcodeConfigDetector.detect(
            kind: detection?.kind ?? .auto, projectFile: detection?.projectFile, projectRoot: root
        )

        return build(Input(
            kind: detection?.kind,
            reason: detection?.reason,
            swiftPMTestTargets: swiftPMTestTargets,
            scheme: xcodeDetection.scheme,
            schemeCandidates: xcodeDetection.schemeCandidates,
            xcodeTestTargets: xcodeDetection.testTargets,
            destination: xcodeDetection.destination,
            destinationDiscoveryFailed: xcodeDetection.destinationDiscoveryFailed
        ))
    }

    static func build(_ input: Input) -> Result {
        let kind = input.kind
        let reason = input.reason
        let swiftPMTestTargets = input.swiftPMTestTargets
        let scheme = input.scheme
        let schemeCandidates = input.schemeCandidates
        let xcodeTestTargets = input.xcodeTestTargets
        let destination = input.destination
        let destinationDiscoveryFailed = input.destinationDiscoveryFailed

        var lines: [String] = []

        if let kind, let reason {
            lines.append("Detected: \(kind.rawValue) — \(reason)")
        } else {
            lines.append("Could not detect the project kind. Writing a template with `kind: auto`.")
            lines.append("Run `mutantkit doctor` to see what is missing.")
        }

        if !swiftPMTestTargets.isEmpty {
            lines.append("Detected test target(s): \(swiftPMTestTargets.joined(separator: ", "))")
        }

        // `nil`-scheme with zero candidates just means "not an Xcode
        // project/workspace, or discovery found nothing" — only more than one
        // candidate with no chosen scheme is a real ambiguity worth reporting.
        let schemeAmbiguous = scheme == nil && schemeCandidates.count > 1
        if let scheme {
            lines.append("Detected scheme: \(scheme)")
        } else if schemeAmbiguous {
            lines.append("Multiple schemes found (\(schemeCandidates.joined(separator: ", "))) — set `project.scheme` yourself.")
        }
        if !xcodeTestTargets.isEmpty {
            lines.append("Detected test target(s): \(xcodeTestTargets.joined(separator: ", "))")
        }

        // A discovery *failure* (a real `simctl` call that could not launch,
        // timed out, or returned unparseable output) is not the same fact as
        // "no simulator is installed" — the placeholder fallback below still
        // applies either way, but only a genuine failure warrants telling the
        // user discovery itself did not run to completion.
        if destinationDiscoveryFailed {
            lines.append("""
            warning: could not query the simulator subsystem (a real `simctl` call failed or timed out) — \
            falling back to a placeholder destination. Run `mutantkit doctor`, or retry once Xcode/CoreSimulator has settled.
            """)
        }

        let resolvedDestination = destination ?? kind.flatMap(defaultDestination(for:))
        if let resolvedDestination, destination != nil {
            lines.append("Detected destination: \(resolvedDestination)")
        }

        let testTargets = swiftPMTestTargets.isEmpty ? xcodeTestTargets : swiftPMTestTargets
        let template = ConfigurationLoader.template(
            for: kind ?? .auto,
            scheme: scheme,
            destination: resolvedDestination,
            testTargets: testTargets
        )

        return Result(
            template: template,
            summaryLines: lines,
            hasTestTargets: !testTargets.isEmpty,
            schemeAmbiguous: schemeAmbiguous,
            destinationDiscoveryFailed: destinationDiscoveryFailed
        )
    }

    /// A default destination is only offered for kinds that require one, and
    /// only as a last resort: `XcodeConfigDetector.detect`'s own real,
    /// currently-available-simulator detection (Phase C13) is tried first;
    /// this hardcoded name is reached only when that detection could not
    /// find any simulator at all (no Xcode Platforms installed, `simctl`
    /// unavailable) — a placeholder the user has to know to fix, same as
    /// before C13, but now the exception rather than the common case.
    private static func defaultDestination(for kind: ProjectKind) -> String? {
        switch kind {
        case .swiftPackageApple, .xcodeProject, .xcodeWorkspace:
            "platform=iOS Simulator,name=iPhone 16"
        case .swiftPackageMacOS, .auto:
            nil
        }
    }

    /// Phase C11 (competitive-parity program): SwiftPM's own manifest
    /// already says which of its targets are test targets
    /// (`SwiftPMDependencyGraph.isTestTarget`, backed by `swift package
    /// describe`'s own `"type": "test"` classification) — this used to be
    /// thrown away, leaving `tests.targets: []` in every generated
    /// `mutantkit.yml` regardless of project kind, with only a comment
    /// telling the user to fill it in by hand.
    ///
    /// Xcode project/workspace kinds are handled separately, by
    /// `XcodeConfigDetector` (Phase C13) — this function itself still only
    /// ever returns non-empty for SwiftPM kinds; `build(...)` merges the two
    /// results together.
    ///
    /// `try?`, matching this command's own established "detection can
    /// legitimately fail; write a template the user finishes by hand rather
    /// than refusing" philosophy — a malformed manifest, no `swift` on
    /// `PATH`, or a timeout all degrade to the pre-existing empty-list
    /// behavior, never to a thrown error that would block `init`/`setup`
    /// entirely.
    private static func detectedSwiftPMTestTargets(kind: ProjectKind?, projectRoot: URL) async -> [String] {
        guard kind == .swiftPackageMacOS || kind == .swiftPackageApple else { return [] }
        guard let graph = try? await SwiftPMTargetResolver.resolveDependencyGraph(projectRoot: projectRoot) else { return [] }
        return graph.targets.keys.filter { graph.isTestTarget($0) }.sorted()
    }
}
