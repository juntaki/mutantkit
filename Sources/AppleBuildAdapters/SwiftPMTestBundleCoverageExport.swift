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

    /// Every `*.xctest` bundle directly under `productsDirectory`: the executables found, sorted by
    /// path, and the bundles whose executable could not be found. An export that leaves a bundle out
    /// names no covering test for the lines only that bundle links, so the two are kept apart rather
    /// than the unreadable ones being dropped. `nil` when the directory itself cannot be listed.
    struct BundleInventory: Equatable {
        var executables: [URL]
        var unreadableBundles: [URL]
    }

    static func testBundleInventory(in productsDirectory: URL, fileManager: FileManager = .default) -> BundleInventory? {
        guard let entries = try? fileManager.contentsOfDirectory(at: productsDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }
        var inventory = BundleInventory(executables: [], unreadableBundles: [])
        for bundle in entries.filter({ $0.pathExtension == "xctest" }).sorted(by: { $0.path < $1.path }) {
            let macOSDirectory = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
            let name = bundle.deletingPathExtension().lastPathComponent
            if let executable = (try? fileManager.contentsOfDirectory(at: macOSDirectory, includingPropertiesForKeys: nil))?
                .first(where: { $0.lastPathComponent == name }) {
                inventory.executables.append(executable)
            } else {
                inventory.unreadableBundles.append(bundle)
            }
        }
        return inventory
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

    /// What `refresh` established about the all-bundles export.
    enum Outcome: Equatable {
        /// Fewer than two bundles: SwiftPM's own file covers the only bundle.
        case notNeeded
        /// A fresh export of every bundle was written next to SwiftPM's file.
        case exported
        /// The export could not be produced completely. SwiftPM's file alone covers only the bundle it
        /// chose, so the coverage directory must not be read as evidence of what the suite executes.
        case incomplete(reason: String)
    }

    /// Runs the `llvm-cov export` and returns its result, or `nil` when it could not be run.
    typealias ExportRunner = @Sendable (_ arguments: [String], _ workingDirectory: URL) async -> ProcessResult?

    static let defaultExportRunner: ExportRunner = { arguments, workingDirectory in
        try? await ProcessSupervisor.run(
            executable: ToolPaths.xcrun,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Replaces the all-bundles export in `codecovDirectory`. A previous export is removed first, and a
    /// removal that fails is `.incomplete`: an older run's coverage must never be merged in. Every
    /// bundle must be found and exported, successfully and with complete output, and the result
    /// written; any shortfall is `.incomplete` with its reason, never a best-effort partial file.
    static func refresh(
        productsDirectory: URL, codecovDirectory: URL, fileManager: FileManager = .default,
        run: ExportRunner = defaultExportRunner
    ) async -> Outcome {
        let output = codecovDirectory.appendingPathComponent(outputFileName)
        if fileManager.fileExists(atPath: output.path) {
            do { try fileManager.removeItem(at: output) } catch {
                return .incomplete(reason: "the previous all-bundles export could not be removed: \(error)")
            }
        }

        guard let inventory = testBundleInventory(in: productsDirectory, fileManager: fileManager) else {
            return .incomplete(reason: "the products directory could not be listed")
        }
        guard inventory.unreadableBundles.isEmpty else {
            let names = inventory.unreadableBundles.map(\.lastPathComponent).joined(separator: ", ")
            return .incomplete(reason: "test bundle executable not found for: \(names)")
        }
        guard inventory.executables.count > 1 else { return .notNeeded }

        let profile = codecovDirectory.appendingPathComponent(profileFileName)
        guard fileManager.fileExists(atPath: profile.path) else {
            return .incomplete(reason: "\(profileFileName) is missing for a \(inventory.executables.count)-bundle export")
        }

        guard let result = await run(
            exportArguments(profileData: profile, executables: inventory.executables), productsDirectory
        ) else { return .incomplete(reason: "llvm-cov export could not be run") }
        guard result.succeededWithCompleteOutput, !result.standardOutput.isEmpty else {
            return .incomplete(reason: "llvm-cov export failed or its output was incomplete")
        }
        do { try result.standardOutput.write(to: output) } catch {
            return .incomplete(reason: "the all-bundles export could not be written: \(error)")
        }
        return .exported
    }
}
