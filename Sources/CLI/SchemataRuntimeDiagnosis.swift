import AppleBuildAdapters
import Foundation
import MutationExecution

/// Whether a schemata build could find and trust its runtime archive, checked before a run.
///
/// Without a usable runtime every schemata chunk build fails; the run still exits 0 and every
/// mutant reports an infrastructure failure, which is how a measurement was once lost. This asks
/// the same locator a real build uses, so the answer cannot differ from what the build will see.
enum SchemataRuntimeDiagnosis {
    private static let platforms: [SchemataRuntimePlatform] = [.macOS, .iOSSimulator]

    /// - Parameter required: when true (`doctor --require-schemata-runtime`), a runtime that
    ///   cannot be used for macOS is a failure rather than a warning. It stays a warning by
    ///   default: isolated execution works without it.
    static func item(
        required: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = MutantKitInstallLocation.executableURL()
    ) -> DiagnosisItem {
        var lines: [String] = []
        var macOSUsable = false
        var usesOverride = false
        for platform in platforms {
            do {
                let located = try SchemataRuntimeLibraryLocator.locate(
                    for: platform, environment: environment, executableURL: executableURL
                )
                if platform == .macOS { macOSUsable = true }
                switch located.provenance {
                case .bundled:
                    usesOverride = false
                    lines.append(
                        "\(platform.rawValue): bundled runtime found at \(located.archivePath.path); manifest, SHA-256 digest and"
                            + " runtime ABI \(SchemataRuntimeLibraryLocator.expectedRuntimeABIVersion) verified"
                    )
                case .override:
                    usesOverride = true
                    lines.append(
                        "\(platform.rawValue): using the developer override \(SchemataRuntimeLibraryLocator.overrideEnvironmentVariable)"
                            + " -> \(located.archivePath.path) (file presence and source staleness only; not digest- or ABI-verified)"
                    )
                }
            } catch {
                lines.append("\(platform.rawValue): not usable: \(error)")
            }
        }
        let status: DiagnosisItem.Status = macOSUsable ? (usesOverride ? .warning : .ok) : (required ? .failure : .warning)
        let remedy: String? = switch (macOSUsable, usesOverride) {
        case (true, false):
            nil
        case (true, true):
            "A developer override is in effect. Use a released mutantkit install for measurements you intend to publish."
        case (false, _):
            "Use a released mutantkit install (it bundles the runtime), or set"
                + " \(SchemataRuntimeLibraryLocator.overrideEnvironmentVariable) to a directory containing"
                + " \(SchemataRuntimeLibraryLocator.libraryFileName) (local builds: `swift build --product MutantKitSchemataRuntime`)."
                + " Without it every schemata build fails and mutants report infrastructureFailure."
        }
        return DiagnosisItem(
            name: "Schemata runtime", status: status, code: .schemataRuntime,
            detail: lines.joined(separator: "\n"), remedy: remedy
        )
    }
}
