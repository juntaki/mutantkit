import AppleBuildAdapters
import ArgumentParser
import Foundation
import MutationExecution
import MutationModel

/// Diagnoses the environment before the user commits to a configuration.
///
/// This runs first for a reason. Almost every painful failure in this category
/// of tool is an environment mismatch discovered an hour into a run — the wrong
/// build system for the package, a scheme that is not shared, an `.xctestrun`
/// that is not where it was assumed to be. `doctor` asks those questions in
/// seconds, before a config file exists to be blamed.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check that this environment can run mutation testing."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Skip the trial build. Faster, but proves much less.")
    var skipBuild = false

    func run() async throws {
        let root = common.resolvedProjectRoot
        print("Diagnosing \(root.path)\n")

        let (configuration, configStatus) = loadConfiguration(root: root)

        let toolchain = await ToolchainProbe.fingerprint(workingDirectory: root)
        var items: [DiagnosisItem] = []
        if let configStatus {
            items.append(configStatus)
        }
        items.append(contentsOf: [
            DiagnosisItem(
                name: "MutantKit",
                status: .ok,
                detail: "\(ToolVersion.version) (plan schema \(ToolVersion.planSchemaVersion))"
            ),
            DiagnosisItem(
                name: "Swift",
                status: toolchain.swiftVersion == "unknown" ? .failure : .ok,
                detail: toolchain.swiftVersion,
                remedy: toolchain.swiftVersion == "unknown"
                    ? "Could not run `swift --version`. Install the Swift toolchain or Xcode command line tools."
                    : nil
            ),
            DiagnosisItem(
                name: "Xcode",
                status: toolchain.xcodeVersion == nil ? .warning : .ok,
                detail: toolchain.xcodeVersion ?? "not found",
                remedy: toolchain.xcodeVersion == nil
                    ? "Needed for Xcode projects, workspaces and non-macOS Swift packages. Install Xcode and run `xcode-select --switch`."
                    : nil
            )
        ])

        do {
            let resolution = try await AppleAdapterFactory.resolve(configuration: configuration, in: root)
            items.append(DiagnosisItem(
                name: "Project",
                status: .ok,
                detail: "\(resolution.detection.kind.rawValue) — \(resolution.detection.reason)"
            ))

            if !resolution.detection.declaredPlatforms.isEmpty {
                items.append(DiagnosisItem(
                    name: "Declared platforms",
                    status: .ok,
                    detail: resolution.detection.declaredPlatforms.joined(separator: ", ")
                ))
            }

            if !skipBuild {
                items.append(contentsOf: try await resolution.adapter.build.diagnose().items)
            } else {
                items.append(DiagnosisItem(
                    name: "Trial build",
                    status: .warning,
                    detail: "skipped (--skip-build)",
                    remedy: "Run without --skip-build to confirm the project actually builds for testing."
                ))
            }
        } catch {
            items.append(DiagnosisItem(
                name: "Project",
                status: .failure,
                detail: "\(error)",
                remedy: "Set `project.kind`, `project.scheme` and `project.destination` in mutantkit.yml explicitly."
            ))
        }

        items.append(diskSpaceItem(for: root))

        let lockRoot = root.appendingPathComponent(".mutantkit/run-locks")
        let snapshot = ResourceSnapshot.capture(lockRoot: lockRoot)
        let bootedSimulatorCount = await HostResourcePreflight.bootedSimulatorCount()
        items.append(contentsOf: HostResourcePreflight.diagnose(
            snapshot: snapshot,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            bootedSimulatorCount: bootedSimulatorCount,
            availableMemoryBytes: HostResourcePreflight.availableMemoryBytes()
        ))

        let diagnosis = BuildDiagnosis(items: deduplicated(items))
        print(render(diagnosis))

        guard diagnosis.canProceed else {
            print("\nNot ready. Fix the failures above, then run `mutantkit doctor` again.")
            throw ExitCode(MutantKitExit.operationalError)
        }
        print("\nReady. Next: `mutantkit init` to write a config, then `mutantkit plan`.")
    }

    // Config is optional here on purpose: doctor has to work *before* there is
    // one, since its whole job is telling you what to put in it. But "no
    // config file" and "a config file that failed to load" are not the same
    // fact, and collapsing them into the same default silently hides a real
    // problem — a typo'd mutantkit.yml would be diagnosed as if it did not
    // exist, instead of being reported as broken.
    private func loadConfiguration(root: URL) -> (Configuration, DiagnosisItem?) {
        var configuration = Configuration()
        var configStatus: DiagnosisItem?
        do {
            configuration = try ConfigurationLoader.load(explicitPath: common.configPath, projectRoot: root)
        } catch let error as ConfigurationError {
            switch error {
            case .notFound:
                break
            case .unreadable, .malformed, .unsupportedVersion:
                configStatus = DiagnosisItem(
                    name: "Configuration",
                    status: .failure,
                    detail: error.description,
                    remedy: "Fix mutantkit.yml, or remove it to fall back to defaults."
                )
            }
        } catch {
            configStatus = DiagnosisItem(name: "Configuration", status: .failure, detail: "\(error)")
        }

        for issue in ConfigurationValidator.validate(configuration, projectRoot: root) where issue.severity == .error {
            configStatus = configStatus ?? DiagnosisItem(
                name: "Configuration",
                status: .failure,
                detail: issue.description,
                remedy: "Fix the configuration issue above."
            )
        }
        return (configuration, configStatus)
    }

    /// Isolated mode makes a full source copy per concurrent mutant, so running
    /// out of disk mid-run is a realistic failure rather than a theoretical one.
    private func diskSpaceItem(for root: URL) -> DiagnosisItem {
        guard let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else {
            return DiagnosisItem(name: "Disk space", status: .warning, detail: "could not be determined")
        }

        let gigabytes = Double(available) / 1_000_000_000
        let lowSpace = gigabytes < 5
        return DiagnosisItem(
            name: "Disk space",
            status: lowSpace ? .warning : .ok,
            detail: String(format: "%.1f GB available", gigabytes),
            remedy: lowSpace ? "Isolated mode copies the tree per concurrent mutant. Free space or lower `execution.workers`." : nil
        )
    }

    /// Adapters legitimately re-check things this command already checked — they
    /// have to stand alone. Showing the user "Swift" and "Swift toolchain" as two
    /// findings makes the report look confused about what it knows, so
    /// near-duplicates collapse to the first, more severe report of each fact.
    private func deduplicated(_ items: [DiagnosisItem]) -> [DiagnosisItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = item.name.lowercased()
                .replacingOccurrences(of: " toolchain", with: "")
                .replacingOccurrences(of: " kind", with: "")
            return seen.insert(key).inserted
        }
    }

    private func render(_ diagnosis: BuildDiagnosis) -> String {
        diagnosis.items.map { item in
            let mark = switch item.status {
            case .ok: "✓"
            case .warning: "!"
            case .failure: "✗"
            }
            var line = "\(mark) \(item.name.padding(toLength: max(22, item.name.count), withPad: " ", startingAt: 0)) \(item.detail)"
            if let remedy = item.remedy {
                line += "\n  └─ \(remedy)"
            }
            return line
        }.joined(separator: "\n")
    }
}
