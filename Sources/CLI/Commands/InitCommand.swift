import AppleBuildAdapters
import ArgumentParser
import Foundation
import MutationModel

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Write a mutantkit.yml for this project."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Overwrite an existing mutantkit.yml.")
    var force = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        let destination = root.appendingPathComponent(ConfigurationLoader.fileName)

        if FileManager.default.fileExists(atPath: destination.path), !force {
            print("\(destination.path) already exists. Pass --force to overwrite it.")
            throw ExitCode(MutantKitExit.operationalError)
        }

        // Detection can legitimately fail — an empty directory, a project kind we
        // do not recognise. That is not a reason to refuse to write a config;
        // it is a reason to write one the user has to finish, and to say so.
        let detection = try? await ProjectDetector.detect(in: root)

        if let detection {
            print("Detected: \(detection.kind.rawValue) — \(detection.reason)")
        } else {
            print("Could not detect the project kind. Writing a template with `kind: auto`.")
            print("Run `mutantkit doctor` to see what is missing.")
        }

        let testTargets = await Self.detectedTestTargets(kind: detection?.kind, projectRoot: root)
        if !testTargets.isEmpty {
            print("Detected test target(s): \(testTargets.joined(separator: ", "))")
        }

        // Phase C13: real Xcode/workspace scheme + destination detection —
        // `xcodeDetection` is `nil`-scheme/empty-testTargets/nil-destination
        // for every other kind, so this call is a no-op cost there.
        let xcodeDetection = await XcodeConfigDetector.detect(
            kind: detection?.kind ?? .auto, projectFile: detection?.projectFile, projectRoot: root
        )
        if let scheme = xcodeDetection.scheme {
            print("Detected scheme: \(scheme)")
        } else if xcodeDetection.schemeCandidates.count > 1 {
            print("Multiple schemes found (\(xcodeDetection.schemeCandidates.joined(separator: ", "))) — set `project.scheme` yourself.")
        }
        let xcodeTestTargets = xcodeDetection.testTargets
        if !xcodeTestTargets.isEmpty {
            print("Detected test target(s): \(xcodeTestTargets.joined(separator: ", "))")
        }

        // A discovery *failure* (a real `simctl` call that could not launch,
        // timed out, or returned unparseable output) is not the same fact
        // as "no simulator is installed" — the placeholder fallback below
        // still applies either way, but only a genuine failure warrants
        // telling the user discovery itself did not run to completion.
        if xcodeDetection.destinationDiscoveryFailed {
            print("""
            warning: could not query the simulator subsystem (a real `simctl` call failed or timed out) — \
            falling back to a placeholder destination. Run `mutantkit doctor`, or retry once Xcode/CoreSimulator has settled.
            """)
        }

        let resolvedDestination = xcodeDetection.destination ?? detection.map(defaultDestination(for:)) ?? nil
        if let resolvedDestination, xcodeDetection.destination != nil {
            print("Detected destination: \(resolvedDestination)")
        }

        let template = ConfigurationLoader.template(
            for: detection?.kind ?? .auto,
            scheme: xcodeDetection.scheme,
            destination: resolvedDestination,
            testTargets: testTargets.isEmpty ? xcodeTestTargets : testTargets
        )

        try Data(template.utf8).write(to: destination, options: .atomic)
        print("\nWrote \(destination.path)")
        let anyTestTargets = !testTargets.isEmpty || !xcodeTestTargets.isEmpty
        print(anyTestTargets
            ? "Next: run `mutantkit doctor` and `mutantkit plan` — `tests.targets` is already filled in, review it before running."
            : "Next: fill in `tests.targets`, then run `mutantkit doctor` and `mutantkit plan`.")
    }

    /// A default destination is only offered for kinds that require one, and
    /// only as a last resort: `XcodeConfigDetector.detect`'s own real,
    /// currently-available-simulator detection (Phase C13) is tried first;
    /// this hardcoded name is reached only when that detection could not
    /// find any simulator at all (no Xcode Platforms installed, `simctl`
    /// unavailable) — a placeholder the user has to know to fix, same as
    /// before C13, but now the exception rather than the common case.
    private func defaultDestination(for detection: ProjectDetection) -> String? {
        switch detection.kind {
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
    /// telling the user to fill it in by hand. A real, avoidable friction
    /// point in the exact first-60-seconds path the README's own quick
    /// start walks through.
    ///
    /// Xcode project/workspace kinds are handled separately, by
    /// `XcodeConfigDetector` (Phase C13) — this function itself still only
    /// ever returns non-empty for SwiftPM kinds; `run()` merges the two
    /// results together.
    ///
    /// `try?`, matching this command's own established "detection can
    /// legitimately fail; write a template the user finishes by hand
    /// rather than refusing" philosophy — a malformed manifest, no `swift`
    /// on `PATH`, or a timeout all degrade to the pre-existing empty-list
    /// behavior, never to a thrown error that would block `init` entirely.
    private static func detectedTestTargets(kind: ProjectKind?, projectRoot: URL) async -> [String] {
        guard kind == .swiftPackageMacOS || kind == .swiftPackageApple else { return [] }
        guard let graph = try? await SwiftPMTargetResolver.resolveDependencyGraph(projectRoot: projectRoot) else { return [] }
        return graph.targets.keys.filter { graph.isTestTarget($0) }.sorted()
    }
}
