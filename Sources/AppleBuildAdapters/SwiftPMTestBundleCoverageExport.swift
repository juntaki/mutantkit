import Foundation
import MutationExecution

/// Exports coverage against every test bundle, not just the one SwiftPM picks.
///
/// SwiftPM writes `codecov/<package>.json` by exporting the merged profile against a single test
/// bundle. On Xcode 27 each test target is its own bundle and links its own code, so a package with
/// several test targets whose bundles link different modules loses the coverage of every module
/// that is not in the chosen bundle: lines its tests do execute come out unexecuted. A map built
/// from that file would name no covering test for them, and a mutant there could be scored without
/// any test that reaches it.
///
/// The export written here uses the same profile with every bundle as an object. It goes next to
/// SwiftPM's file, and `SourceCoverageReader` merges every JSON file in the directory.
enum SwiftPMTestBundleCoverageExport {
    static let outputFileName = "mutantkit-all-test-bundles.json"
    private static let profileFileName = "default.profdata"
    private static let timeoutSeconds: Double = 300

    /// The executable inside every `*.xctest` bundle directly under `productsDirectory`, sorted by path.
    static func testBundleExecutables(in productsDirectory: URL, fileManager: FileManager = .default) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(at: productsDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.pathExtension == "xctest" }
            .compactMap { bundle -> URL? in
                let macOSDirectory = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
                return (try? fileManager.contentsOfDirectory(at: macOSDirectory, includingPropertiesForKeys: nil))?
                    .first { $0.lastPathComponent == bundle.deletingPathExtension().lastPathComponent }
            }
            .sorted { $0.path < $1.path }
    }

    /// `xcrun llvm-cov export` arguments with the first bundle as the positional binary and every other as `-object`.
    static func exportArguments(profileData: URL, executables: [URL]) -> [String] {
        guard let first = executables.first else { return [] }
        var arguments = ["llvm-cov", "export", "-format=text", "-instr-profile=\(profileData.path)", first.path]
        for executable in executables.dropFirst() {
            arguments += ["-object", executable.path]
        }
        return arguments
    }

    /// Replaces the all-bundles export in `codecovDirectory`. Does nothing for fewer than two bundles,
    /// where SwiftPM's own file already covers the only bundle. A previous export is removed first, so a
    /// failed export can never leave an older run's coverage to be merged in.
    static func refresh(productsDirectory: URL, codecovDirectory: URL, fileManager: FileManager = .default) async {
        let output = codecovDirectory.appendingPathComponent(outputFileName)
        try? fileManager.removeItem(at: output)

        let executables = testBundleExecutables(in: productsDirectory, fileManager: fileManager)
        let profile = codecovDirectory.appendingPathComponent(profileFileName)
        guard executables.count > 1, fileManager.fileExists(atPath: profile.path) else { return }

        guard let result = try? await ProcessSupervisor.run(
            executable: ToolPaths.xcrun,
            arguments: exportArguments(profileData: profile, executables: executables),
            workingDirectory: productsDirectory,
            timeoutSeconds: timeoutSeconds
        ), result.exitCode == 0, !result.standardOutput.isEmpty else { return }
        try? result.standardOutput.write(to: output)
    }
}
