import Foundation
import MutationModel
import Yams

/// Everything importing can refuse to do.
public enum MuterImportError: Error, CustomStringConvertible {
    case noConfigurationFound(directory: String)
    case unreadableFile(path: String, detail: String)
    case undecodable(path: String, detail: String)

    public var description: String {
        switch self {
        case let .noConfigurationFound(directory):
            """
            No \(MuterConfigImporter.configFileName) or \
            \(MuterConfigImporter.legacyConfigFileName) in \(directory).
            """
        case let .unreadableFile(path, detail):
            "Could not read \(path): \(detail)"
        case let .undecodable(path, detail):
            "\(path) is not a Muter configuration: \(detail)"
        }
    }
}

/// A configuration translated from Muter, and the record of what that cost.
public struct MuterImport: Sendable {
    public let configuration: Configuration
    public let report: ImportReport

    public init(configuration: Configuration, report: ImportReport) {
        self.configuration = configuration
        self.report = report
    }
}

/// Reads a `muter.conf.yml` and produces our `Configuration`.
///
/// Muter's config describes *a test command*: an executable and the arguments to
/// pass it. Ours describes *a project*: what kind it is, which scheme, which
/// destination. The import is therefore an inference, not a translation — most
/// of what follows is reading intent out of an argument list, and every
/// inference it makes is written down in the `ImportReport` rather than assumed
/// correct.
public struct MuterConfigImporter: Sendable {
    public static let configFileName = "muter.conf.yml"
    public static let legacyConfigFileName = "muter.conf.json"

    public init() {}

    /// Finds Muter's config in a directory, preferring the current format.
    public static func locateConfiguration(in directory: URL) -> URL? {
        for name in [configFileName, legacyConfigFileName] {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func importConfiguration(from url: URL) throws -> MuterImport {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MuterImportError.unreadableFile(path: url.path, detail: error.localizedDescription)
        }
        return try importConfiguration(from: data, sourceName: url.lastPathComponent)
    }

    /// Testable entry point taking bytes directly.
    public func importConfiguration(from data: Data, sourceName: String) throws -> MuterImport {
        let muter = try decode(data, sourceName: sourceName)
        var entries: [ImportReport.Entry] = []

        let project = translateProject(muter, into: &entries)
        let sources = translateSources(muter, into: &entries)
        let timeouts = translateTimeouts(muter, into: &entries)
        recordUnmappable(muter, into: &entries)

        let configuration = Configuration(
            project: project,
            sources: sources,
            timeouts: timeouts
        )

        return MuterImport(
            configuration: configuration,
            report: ImportReport(sourceName: sourceName, entries: entries)
        )
    }

    // MARK: - Decoding

    /// Muter accepts YAML and, for legacy configs, JSON. It decides by trying
    /// YAML first and falling back; we match that so a file Muter reads is a
    /// file we read.
    private func decode(_ data: Data, sourceName: String) throws -> MuterConfigurationFile {
        do {
            return try YAMLDecoder().decode(MuterConfigurationFile.self, from: data)
        } catch let yamlError {
            do {
                return try JSONDecoder().decode(MuterConfigurationFile.self, from: data)
            } catch {
                throw MuterImportError.undecodable(
                    path: sourceName,
                    detail: "\(yamlError)"
                )
            }
        }
    }

    // MARK: - Project

    private func translateProject(
        _ muter: MuterConfigurationFile,
        into entries: inout [ImportReport.Entry]
    ) -> ProjectSettings {
        let executable = muter.executable.split(separator: "/").last.map(String.init) ?? muter.executable
        var project = ProjectSettings()

        switch executable {
        case "xcodebuild":
            project.scheme = muter.value(after: "-scheme")
            project.destination = muter.value(after: "-destination")
            project.derivedDataPath = muter.value(after: "-derivedDataPath")

            if let workspace = muter.value(after: "-workspace") {
                project.kind = .xcodeWorkspace
                project.path = workspace
                entries.append(ImportReport.Entry(
                    field: "executable + arguments",
                    disposition: .translated,
                    muterValue: "xcodebuild -workspace \(workspace)",
                    mutantkitValue: "project.kind: xcodeWorkspace, project.path: \(workspace)",
                    detail: "Inferred from the -workspace argument."
                ))
            } else if let xcodeproj = muter.value(after: "-project") {
                project.kind = .xcodeProject
                project.path = xcodeproj
                entries.append(ImportReport.Entry(
                    field: "executable + arguments",
                    disposition: .translated,
                    muterValue: "xcodebuild -project \(xcodeproj)",
                    mutantkitValue: "project.kind: xcodeProject, project.path: \(xcodeproj)",
                    detail: "Inferred from the -project argument."
                ))
            } else {
                entries.append(ImportReport.Entry(
                    field: "executable + arguments",
                    disposition: .needsReview,
                    muterValue: "xcodebuild (no -workspace or -project)",
                    mutantkitValue: "project.kind: auto",
                    detail: """
                    The test command runs xcodebuild but names neither a workspace nor a project, \
                    so the project kind could not be inferred. Set project.kind and project.path \
                    by hand, or leave `auto` to let detection try.
                    """
                ))
            }

            recordExtractedArgument("-scheme", project.scheme, "project.scheme", into: &entries)
            recordExtractedArgument("-destination", project.destination, "project.destination", into: &entries)
            recordExtractedArgument(
                "-derivedDataPath", project.derivedDataPath, "project.derivedDataPath", into: &entries
            )

        case "swift":
            project.kind = .swiftPackageMacOS
            entries.append(ImportReport.Entry(
                field: "executable + arguments",
                disposition: .needsReview,
                muterValue: "swift \(muter.arguments.joined(separator: " "))",
                mutantkitValue: "project.kind: swiftPackageMacOS",
                detail: """
                `swift test` only ever runs on the host, so the import assumes a macOS package. \
                If this package actually targets iOS, watchOS or tvOS, change project.kind to \
                swiftPackageApple and set a scheme and destination — running an Apple-platform \
                package through `swift test` is why Muter could not see UIKit code.
                """
            ))

        default:
            entries.append(ImportReport.Entry(
                field: "executable",
                disposition: .needsReview,
                muterValue: muter.executable,
                mutantkitValue: "project.kind: auto",
                detail: """
                '\(executable)' is neither xcodebuild nor swift, so no project kind could be \
                inferred. Set project.kind, project.path, project.scheme and project.destination \
                by hand.
                """
            ))
        }

        recordLeftoverArguments(muter, executable: executable, into: &entries)
        return project
    }

    private func recordExtractedArgument(
        _ argument: String,
        _ value: String?,
        _ destination: String,
        into entries: inout [ImportReport.Entry]
    ) {
        guard let value else { return }
        entries.append(ImportReport.Entry(
            field: "arguments \(argument)",
            disposition: .translated,
            muterValue: "\(argument) \(value)",
            mutantkitValue: "\(destination): \(value)",
            detail: "Extracted from the test command."
        ))
    }

    /// Arguments we understood are lifted into typed settings; the rest are
    /// reported, never guessed at.
    ///
    /// Our executor builds its own invocation from `ProjectSettings` rather than
    /// replaying Muter's command line, so anything left here genuinely does not
    /// reach the build — silently keeping it would be worse than saying so.
    private func recordLeftoverArguments(
        _ muter: MuterConfigurationFile,
        executable: String,
        into entries: inout [ImportReport.Entry]
    ) {
        let consumedFlags = ["-workspace", "-project", "-scheme", "-destination", "-derivedDataPath"]
        var leftovers: [String] = []
        var index = 0

        while index < muter.arguments.count {
            let argument = muter.arguments[index]
            if consumedFlags.contains(argument) {
                index += 2
                continue
            }
            // The subcommand itself carries no information we don't already have
            // from the project kind.
            if ["test", "build"].contains(argument) {
                index += 1
                continue
            }
            leftovers.append(argument)
            index += 1
        }

        guard !leftovers.isEmpty else { return }
        entries.append(ImportReport.Entry(
            field: "arguments (remaining)",
            disposition: .needsReview,
            muterValue: leftovers.joined(separator: " "),
            mutantkitValue: nil,
            detail: """
            These arguments were not translated. The test invocation is built from \
            project settings rather than replayed from Muter's command line, so they have no \
            effect. If any of them matter, put them in tests.extraArguments.
            """
        ))
    }

    // MARK: - Sources

    private func translateSources(
        _ muter: MuterConfigurationFile,
        into entries: inout [ImportReport.Entry]
    ) -> SourceSettings {
        guard !muter.exclude.isEmpty else {
            entries.append(ImportReport.Entry(
                field: "exclude",
                disposition: .translated,
                muterValue: "(none)",
                mutantkitValue: "sources.exclude: \(SourceSettings.defaultExcludes.count) default patterns",
                detail: "Nothing to carry over, so the default excludes apply."
            ))
            return SourceSettings()
        }

        entries.append(ImportReport.Entry(
            field: "exclude",
            disposition: .partiallyTranslated,
            muterValue: muter.exclude.joined(separator: ", "),
            mutantkitValue: "sources.exclude: \(muter.exclude.joined(separator: ", "))",
            detail: """
            Carried over verbatim so the imported run mutates the same files Muter did. \
            This replaces our defaults rather than adding to them, so generated code and mocks \
            (\(SourceSettings.defaultExcludes.joined(separator: ", "))) are NOT excluded unless \
            you add them back. Build directories are skipped regardless of this list.
            """
        ))

        return SourceSettings(exclude: muter.exclude)
    }

    // MARK: - Timeouts

    private func translateTimeouts(
        _ muter: MuterConfigurationFile,
        into entries: inout [ImportReport.Entry]
    ) -> TimeoutSettings {
        guard let timeout = muter.mutationTestTimeout else { return TimeoutSettings() }

        entries.append(ImportReport.Entry(
            field: "mutationTestTimeout",
            disposition: .partiallyTranslated,
            muterValue: "\(timeout)s",
            mutantkitValue: "timeouts.mutant: strategy fixed, maximum \(timeout)s",
            detail: """
            Muter's timeout is one fixed limit applied to the whole test suite, so it imports as \
            the `fixed` strategy with that maximum. Our default is `adaptive`: a limit derived \
            from the measured baseline duration, which catches a hung mutant in seconds instead \
            of waiting out a limit sized for the slowest legitimate run. Switching to adaptive \
            is recommended once you have seen a baseline.
            """
        ))

        return TimeoutSettings(
            mutant: MutantTimeoutSettings(strategy: .fixed, maximumSeconds: timeout)
        )
    }

    // MARK: - What we cannot carry

    private func recordUnmappable(
        _ muter: MuterConfigurationFile,
        into entries: inout [ImportReport.Entry]
    ) {
        if let threshold = muter.coverageThreshold, threshold > 0 {
            entries.append(ImportReport.Entry(
                field: "coverageThreshold",
                disposition: .dropped,
                muterValue: "\(threshold)",
                mutantkitValue: nil,
                detail: """
                No equivalent. Muter fails a run when line coverage falls below this number; \
                this tool reports a mutation score and does not gate on line coverage at all. \
                Keep the check in CI if you need it.
                """
            ))
        }

        if !muter.excludeCalls.isEmpty {
            entries.append(ImportReport.Entry(
                field: "excludeCalls",
                disposition: .dropped,
                muterValue: muter.excludeCalls.joined(separator: ", "),
                mutantkitValue: nil,
                detail: """
                No equivalent. This list tells Muter's Remove Side Effects operator which calls \
                to leave alone. There is no such operator here and no per-call exclusion \
                mechanism, so the list has nothing to apply to. Nothing is lost today: no \
                operator in this release removes calls.
                """
            ))
        }
    }
}

// MARK: - Muter's file format

/// Muter's `muter.conf.yml` schema, as this tool reads it.
///
/// A local mirror rather than a dependency on Muter's own type: this must keep
/// decoding files written by the Muter versions people have, even as Muter's
/// source moves on.
struct MuterConfigurationFile: Decodable {
    let executable: String
    let arguments: [String]
    let exclude: [String]
    let excludeCalls: [String]
    let coverageThreshold: Double?
    let mutationTestTimeout: Double?

    enum CodingKeys: String, CodingKey {
        case executable
        case arguments
        case exclude
        case excludeCalls
        case coverageThreshold
        case mutationTestTimeout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Muter requires both; we require only `executable`, because a config
        // missing `arguments` still tells us what kind of project this is, and a
        // report saying so beats an error saying nothing.
        executable = try container.decode(String.self, forKey: .executable)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? []
        excludeCalls = try container.decodeIfPresent([String].self, forKey: .excludeCalls) ?? []
        coverageThreshold = try container.decodeIfPresent(Double.self, forKey: .coverageThreshold)

        // Muter accepts both a Double and an Int here, and so must we.
        if let seconds = try? container.decodeIfPresent(Double.self, forKey: .mutationTestTimeout) {
            mutationTestTimeout = seconds
        } else if let seconds = try? container.decodeIfPresent(Int.self, forKey: .mutationTestTimeout) {
            mutationTestTimeout = Double(seconds)
        } else {
            mutationTestTimeout = nil
        }
    }

    /// The argument following `flag`, e.g. the scheme name after `-scheme`.
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
