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

        let template = ConfigurationLoader.template(
            for: detection?.kind ?? .auto,
            scheme: nil,
            destination: detection.map(defaultDestination(for:)) ?? nil,
            testTargets: []
        )

        try Data(template.utf8).write(to: destination, options: .atomic)
        print("\nWrote \(destination.path)")
        print("Next: fill in `tests.targets`, then run `mutantkit doctor` and `mutantkit plan`.")
    }

    /// A default destination is only offered for kinds that require one. Putting
    /// a simulator destination in a macOS package's config would be noise the
    /// user has to know to delete.
    private func defaultDestination(for detection: ProjectDetection) -> String? {
        switch detection.kind {
        case .swiftPackageApple, .xcodeProject, .xcodeWorkspace:
            "platform=iOS Simulator,name=iPhone 16"
        case .swiftPackageMacOS, .auto:
            nil
        }
    }
}
