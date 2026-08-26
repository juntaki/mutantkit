import Foundation
import MutationExecution
import MutationModel

/// Chooses the adapter for a project.
///
/// The whole point of this type is that the choice is made once, from evidence,
/// and is explainable afterwards. Getting it wrong is not a loud failure: a
/// package for iOS pushed through `swift test` produces a wall of errors about
/// missing modules that look like the user's fault, and an unexplained choice
/// gives them nothing to argue with.
public enum AppleAdapterFactory {
    /// The adapter, plus how the project was identified.
    public struct Resolution: Sendable {
        public let adapter: any ProjectAdapter
        public let detection: ProjectDetection

        public init(adapter: any ProjectAdapter, detection: ProjectDetection) {
            self.adapter = adapter
            self.detection = detection
        }
    }

    /// Resolves an adapter, detecting the project kind when configuration says `.auto`.
    ///
    /// `directory` is the real project root — detection reads what is on disk, so
    /// it cannot run against a sandbox copy that only holds sources.
    ///
    /// For any kind that builds through `xcodebuild`, this also resolves the
    /// destination to a concrete device exactly once here — see
    /// `DestinationResolver` — so every caller of `resolve` (`mutantkit run`,
    /// `reproduce`, `doctor`) gets the same one-time-resolved destination for
    /// free, rather than each needing its own copy of this step.
    public static func resolve(
        configuration: Configuration,
        in directory: URL
    ) async throws -> Resolution {
        let detection = try await detect(configuration: configuration, in: directory)
        let resolvedDestination = try await resolveDestinationIfNeeded(
            for: detection.kind, configuration: configuration, in: directory
        )
        return Resolution(
            adapter: adapter(
                for: detection, configuration: configuration, projectRoot: directory,
                resolvedDestination: resolvedDestination
            ),
            detection: detection
        )
    }

    /// Resolves an adapter using a destination already resolved by an
    /// earlier run — see `RunManifest` — instead of resolving one fresh.
    ///
    /// `mutantkit reproduce --replay` is the caller: it wants the exact device
    /// the original run recorded, not whatever `DestinationResolver` would
    /// answer *now*, which can differ if the machine's simulator inventory
    /// changed since. `resolve(configuration:in:)`'s own resolution is
    /// skipped entirely, not merely overridden after the fact — this
    /// guarantees no `simctl` call happens that could throw or return a
    /// different answer.
    public static func resolve(
        configuration: Configuration,
        in directory: URL,
        replaying resolvedDestination: ResolvedDestination
    ) async throws -> Resolution {
        let detection = try await detect(configuration: configuration, in: directory)
        return Resolution(
            adapter: adapter(
                for: detection, configuration: configuration, projectRoot: directory,
                resolvedDestination: resolvedDestination
            ),
            detection: detection
        )
    }

    /// Builds the adapter for an already-known kind.
    ///
    /// - Parameter projectRoot: the real project root. The adapter needs it to
    ///   re-resolve the project file against each sandbox; without it, builds
    ///   would read the user's unmutated sources.
    public static func adapter(
        for detection: ProjectDetection,
        configuration: Configuration,
        projectRoot: URL,
        resolvedDestination: ResolvedDestination? = nil,
        workerDevicesByWorkspace: [String: SimulatorDevice]? = nil
    ) -> any ProjectAdapter {
        switch detection.kind {
        case .swiftPackageMacOS:
            SwiftPackageMacOSProjectAdapter(configuration: configuration)

        case .swiftPackageApple, .xcodeProject, .xcodeWorkspace:
            XcodeBuildProjectAdapter(
                configuration: configuration,
                kind: detection.kind,
                projectFile: detection.projectFile,
                projectRoot: projectRoot,
                resolvedDestination: resolvedDestination,
                workerDevicesByWorkspace: workerDevicesByWorkspace
            )

        case .auto:
            // Unreachable via `resolve`, which resolves `.auto` before it gets here.
            // The host adapter is the safe fallback: it fails loudly and cheaply
            // rather than launching a simulator against a guess.
            SwiftPackageMacOSProjectAdapter(configuration: configuration)
        }
    }

    /// The destination an `xcodebuild`-based kind will build and test
    /// against, resolved once — `nil` for a kind that never launches a
    /// simulator at all.
    ///
    /// Mirrors `XcodeBuildAdapter.destination()`'s own default so the
    /// destination this resolves is the same one an adapter constructed
    /// without a `resolvedDestination` would have derived on its own —
    /// resolution changes *when* the answer is computed and how many times,
    /// not what the answer is.
    private static func resolveDestinationIfNeeded(
        for kind: ProjectKind,
        configuration: Configuration,
        in directory: URL
    ) async throws -> ResolvedDestination? {
        switch kind {
        case .swiftPackageMacOS, .auto:
            return nil
        case .swiftPackageApple, .xcodeProject, .xcodeWorkspace:
            let requested = configuration.project.destination
                ?? (kind == .swiftPackageApple ? "platform=iOS Simulator,name=iPhone 16" : "platform=macOS")
            let pool = SimulatorPool(workingDirectory: directory)
            return try await DestinationResolver.resolve(requested, using: pool)
        }
    }

    /// Honours an explicit `project.kind`, and detects only when asked to.
    ///
    /// A configured kind is never second-guessed. Detection exists to spare users
    /// the decision, not to overrule one they have already made — someone who
    /// writes `kind: swiftPackageApple` may be describing a layout this tool has
    /// not seen, and overriding them there is unfixable from their side.
    private static func detect(
        configuration: Configuration,
        in directory: URL
    ) async throws -> ProjectDetection {
        guard configuration.project.kind == .auto else {
            return ProjectDetection(
                kind: configuration.project.kind,
                reason: "mutantkit.yml sets project.kind to \(configuration.project.kind.rawValue).",
                projectFile: locateProjectFile(for: configuration.project.kind, in: directory)
            )
        }
        return try await ProjectDetector.detect(in: directory)
    }

    /// Finds the file a configured kind implies, so an explicit kind still gets
    /// the `-workspace`/`-project` argument it needs.
    private static func locateProjectFile(for kind: ProjectKind, in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        switch kind {
        case .xcodeWorkspace:
            return contents.first { $0.pathExtension == "xcworkspace" }
        case .xcodeProject:
            return contents.first { $0.pathExtension == "xcodeproj" }
        case .swiftPackageApple, .swiftPackageMacOS:
            let manifest = directory.appendingPathComponent("Package.swift")
            return FileManager.default.fileExists(atPath: manifest.path) ? manifest : nil
        case .auto:
            return nil
        }
    }
}
