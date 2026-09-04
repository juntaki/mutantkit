import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel

/// The environment/config diagnostics `mutantkit doctor` runs, factored out so
/// `mutantkit setup` can run the exact same checks as one step of its own
/// golden-path flow without reimplementing them or shelling out to `doctor`
/// itself (this codebase's orchestration convention is shared-library calls,
/// not one command invoking another's `run()`).
///
/// Moving this out of `DoctorCommand` is code motion only — every check here
/// runs in the same order, builds the same `DiagnosisItem`s, and renders the
/// same way `doctor` always has. `DoctorCommand.run()` itself is now a thin
/// wrapper: print the header, call `ReadinessCheck.run`, render, decide the
/// exit code.
enum ReadinessCheck {
    struct Outcome: Codable {
        let configuration: Configuration
        let diagnosis: BuildDiagnosis
    }

    static func run(root: URL, configPath: String?, skipBuild: Bool) async -> Outcome {
        let (configuration, configStatus) = loadConfiguration(configPath: configPath, root: root)
        return await diagnose(configuration: configuration, configStatus: configStatus, root: root, skipBuild: skipBuild)
    }

    /// Diagnoses an already-resolved `Configuration` directly, instead of
    /// loading one from a path on disk.
    ///
    /// `mutantkit setup`/`setup --dry-run` build the exact `Configuration`
    /// they are about to write (or would write) before this ever runs —
    /// this lets both diagnose that same object, rather than independently
    /// re-reading whatever already happens to exist at `--config`'s path.
    /// The two can disagree: a stale config already on disk, or one at a
    /// different path than `--config` names, would otherwise get diagnosed
    /// instead of the config `setup` actually cares about — silently
    /// answering "is what's already here ready" instead of "would writing
    /// this leave the project ready", which is the only question a preview
    /// exists to answer.
    static func run(root: URL, configuration: Configuration, skipBuild: Bool) async -> Outcome {
        let configStatus = validationFailure(for: configuration, root: root)
        return await diagnose(configuration: configuration, configStatus: configStatus, root: root, skipBuild: skipBuild)
    }

    private static func diagnose(
        configuration: Configuration,
        configStatus: DiagnosisItem?,
        root: URL,
        skipBuild: Bool
    ) async -> Outcome {
        let toolchain = await ToolchainProbe.fingerprint(workingDirectory: root).fingerprint
        var items: [DiagnosisItem] = []
        if let configStatus {
            items.append(configStatus)
        }
        items.append(contentsOf: [
            DiagnosisItem(
                name: "MutantKit",
                status: .ok,
                code: .mutantkitVersion,
                detail: "\(ToolVersion.version) (plan schema \(ToolVersion.planSchemaVersion))"
            ),
            macOSVersionItem(),
            DiagnosisItem(
                name: "Swift",
                status: toolchain.swiftVersion == "unknown" ? .failure : .ok,
                code: .swiftToolchain,
                detail: toolchain.swiftVersion,
                remedy: toolchain.swiftVersion == "unknown"
                    ? "Could not run `swift --version`. Install the Swift toolchain or Xcode command line tools."
                    : nil
            ),
            xcodeItem(toolchain: toolchain)
        ])

        do {
            let resolution = try await AppleAdapterFactory.resolve(configuration: configuration, in: root)
            items.append(DiagnosisItem(
                name: "Project",
                status: .ok,
                code: .projectDetected,
                detail: "\(resolution.detection.kind.rawValue) — \(resolution.detection.reason)"
            ))

            if !resolution.detection.declaredPlatforms.isEmpty {
                items.append(DiagnosisItem(
                    name: "Declared platforms",
                    status: .ok,
                    code: .declaredPlatforms,
                    detail: resolution.detection.declaredPlatforms.joined(separator: ", ")
                ))
            }

            items.append(contentsOf: productionProfileItem(kind: resolution.detection.kind, configuration: configuration))
            items.append(contentsOf: ExecutionCapabilitiesDiagnosis.items(for: resolution, configuration: configuration))

            if !skipBuild {
                items.append(contentsOf: try await resolution.adapter.build.diagnose().items)
            } else {
                items.append(DiagnosisItem(
                    name: "Trial build",
                    status: .warning,
                    code: .trialBuildSkipped,
                    detail: "skipped (--skip-build)",
                    remedy: "Run without --skip-build to confirm the project actually builds for testing."
                ))
            }
        } catch {
            items.append(DiagnosisItem(
                name: "Project",
                status: .failure,
                code: .projectResolutionFailed,
                detail: "\(error)",
                remedy: await remedy(forFailedResolutionIn: root, configuration: configuration)
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

        return Outcome(configuration: configuration, diagnosis: BuildDiagnosis(items: deduplicated(items)))
    }

    static func render(_ diagnosis: BuildDiagnosis) -> String {
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

    // Config is optional here on purpose: doctor has to work *before* there is
    // one, since its whole job is telling you what to put in it. But "no
    // config file" and "a config file that failed to load" are not the same
    // fact, and collapsing them into the same default silently hides a real
    // problem — a typo'd mutantkit.yml would be diagnosed as if it did not
    // exist, instead of being reported as broken.
    private static func loadConfiguration(configPath: String?, root: URL) -> (Configuration, DiagnosisItem?) {
        var configuration = Configuration()
        var configStatus: DiagnosisItem?
        do {
            configuration = try ConfigurationLoader.load(explicitPath: configPath, projectRoot: root)
        } catch let error as ConfigurationError {
            switch error {
            case .notFound:
                break
            case .unreadable, .malformed, .unsupportedVersion:
                configStatus = DiagnosisItem(
                    name: "Configuration",
                    status: .failure,
                    code: .configurationInvalid,
                    detail: error.description,
                    remedy: "Fix mutantkit.yml, or remove it to fall back to defaults."
                )
            }
        } catch {
            configStatus = DiagnosisItem(name: "Configuration", status: .failure, code: .configurationInvalid, detail: "\(error)")
        }

        return (configuration, configStatus ?? validationFailure(for: configuration, root: root))
    }

    /// The first configuration-validation error, rendered as the same
    /// `DiagnosisItem` shape a load failure would produce — shared by both
    /// the disk-loading and in-memory diagnosis entry points so a validation
    /// error reads identically regardless of where the `Configuration` came
    /// from.
    private static func validationFailure(for configuration: Configuration, root: URL) -> DiagnosisItem? {
        for issue in ConfigurationValidator.validate(configuration, projectRoot: root) where issue.severity == .error {
            return DiagnosisItem(
                name: "Configuration",
                status: .failure,
                code: .configurationInvalid,
                detail: issue.description,
                remedy: "Fix the configuration issue above."
            )
        }
        return nil
    }

    /// README.md's own "Install" section: "Requires macOS 14+ on Apple
    /// Silicon, Xcode 16+." — stated, but never actually checked at
    /// runtime before this. Both floors live here, next to each other, so
    /// updating one when the README changes is a one-line reminder to
    /// check the other.
    private static let documentedMacOSFloorMajorVersion = 14
    private static let documentedXcodeFloorMajorVersion = 16

    /// The first run of digits found anywhere in `text` — e.g. `16` from
    /// `"Xcode 16.4"`. `nil` when nothing numeric is present at all, which
    /// this treats as "cannot confirm the floor" rather than "below it":
    /// an unparseable version string is evidence this parsing is wrong,
    /// not evidence of an old Xcode.
    ///
    /// Not `private`: a pure, directly-testable function, so the below-
    /// floor/at-floor/above-floor/unparseable cases each get their own
    /// unit test instead of relying on whatever Xcode happens to be
    /// installed on the machine running the suite.
    static func leadingMajorVersion(in text: String) -> Int? {
        guard let range = text.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }

    /// `ProcessInfo.operatingSystemVersion` needs no subprocess — it is
    /// this process's own kernel-reported host version, always available,
    /// never subject to the `.notPresent`/`.probeFailed` ambiguity a
    /// shelled-out probe (`ToolchainProbe.firstLine`) has to account for.
    /// A `.warning`, not `.failure`, matching every other floor/absence
    /// check in this file: `doctor` informs, it does not block a run that
    /// might still work on an undocumented-but-functional older host.
    private static func macOSVersionItem() -> DiagnosisItem {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let belowFloor = os.majorVersion < documentedMacOSFloorMajorVersion
        return DiagnosisItem(
            name: "macOS",
            status: belowFloor ? .warning : .ok,
            code: .macOSVersionFloor,
            detail: belowFloor ? "\(version) (below the documented floor, macOS \(documentedMacOSFloorMajorVersion)+)" : version,
            remedy: belowFloor
                ? "This project is developed and tested against macOS \(documentedMacOSFloorMajorVersion)+ (README.md)."
                + " Behavior on an older host is unvalidated — upgrade macOS."
                : nil
        )
    }

    /// The presence check this item already made (`toolchain.xcodeVersion
    /// == nil` → `.warning`) is unchanged; this adds the version-floor
    /// check on top of it, for the case where Xcode *is* found but is
    /// older than this project's own documented floor. Kept as one item,
    /// not two: `deduplicated()` below keeps only the *first* item with a
    /// given name, so a second "Xcode" item appended later would be
    /// silently dropped rather than shown — the floor check has to live
    /// inside this same item to actually reach the user.
    ///
    /// Not `private`: driven directly, with a hand-built `ToolchainFingerprint`,
    /// by a unit test that pins the below-floor warning path — this
    /// machine's own real, above-floor Xcode can never exercise that
    /// branch, so the test needs to hand this a fingerprint it built
    /// itself rather than the toolchain probe's real result.
    static func xcodeItem(toolchain: ToolchainFingerprint) -> DiagnosisItem {
        guard let version = toolchain.xcodeVersion else {
            return DiagnosisItem(
                name: "Xcode",
                status: .warning,
                code: .xcodeToolchain,
                detail: "not found",
                remedy: "Needed for Xcode projects, workspaces and non-macOS Swift packages. Install Xcode and run `xcode-select --switch`."
            )
        }
        let belowFloor = leadingMajorVersion(in: version).map { $0 < documentedXcodeFloorMajorVersion } ?? false
        return DiagnosisItem(
            name: "Xcode",
            status: belowFloor ? .warning : .ok,
            code: .xcodeToolchain,
            detail: belowFloor ? "\(version) (below the documented floor, Xcode \(documentedXcodeFloorMajorVersion)+)" : version,
            remedy: belowFloor
                ? "This project is developed and tested against Xcode \(documentedXcodeFloorMajorVersion)+ (README.md)."
                + " An older Xcode may behave differently or not at all — upgrade via the App Store or developer.apple.com."
                : nil
        )
    }

    /// Isolated mode makes a full source copy per concurrent mutant, so running
    /// out of disk mid-run is a realistic failure rather than a theoretical one.
    private static func diskSpaceItem(for root: URL) -> DiagnosisItem {
        guard let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else {
            return DiagnosisItem(name: "Disk space", status: .warning, code: .diskSpace, detail: "could not be determined")
        }

        let gigabytes = Double(available) / 1_000_000_000
        let lowSpace = gigabytes < 5
        return DiagnosisItem(
            name: "Disk space",
            status: lowSpace ? .warning : .ok,
            code: .diskSpace,
            detail: String(format: "%.1f GB available", gigabytes),
            remedy: lowSpace ? "Isolated mode copies the tree per concurrent mutant. Free space or lower `execution.workers`." : nil
        )
    }

    /// Adapters legitimately re-check things this command already checked — they
    /// have to stand alone. Showing the user "Swift" and "Swift toolchain" as two
    /// findings makes the report look confused about what it knows, so
    /// near-duplicates collapse to the first, more severe report of each fact.
    ///
    /// Not `private`: `DoctorCommand.run()` appends its own `Self
    /// .sharedModuleCacheDiagnosis(...)` item to `outcome.diagnosis.items`
    /// *after* this function's own dedup pass already ran (see that call
    /// site's own comment for why the two additions stay independent) —
    /// re-running this same pass over the combined list is what keeps a
    /// same-named item appended there from ever silently surviving
    /// alongside one already produced in here, the exact way a now-deleted
    /// `sharedModuleCacheSupport` diagnostic here once would have collided
    /// with another pass's `sharedModuleCache` item, undetected, had both
    /// existed at once (`DiagnosisNameUniquenessTests` pins this).
    /// When project resolution fails, this used to hand back one generic
    /// instruction regardless of what was actually wrong or knowable. Real,
    /// `xcodebuild`/`simctl`-backed detection (`XcodeConfigDetector`, the
    /// same one `init` uses) often already knows the exact fix — a real
    /// scheme, real test target(s), a real available simulator — and can
    /// say so directly instead of leaving the user to rediscover it by
    /// hand.
    ///
    /// Detects the project's *real* kind independently of whatever
    /// (possibly wrong, possibly absent) configuration just failed to
    /// resolve — `doctor`'s whole purpose is to be trustworthy even when
    /// the config is broken, so this does not trust it either. Every
    /// detection step is best-effort (`try?`): a failure here must never
    /// make `doctor` itself throw or lose the original remedy text
    /// entirely, only fail to enrich it.
    /// A real 4-way local benchmark against a real, large production iOS
    /// app found the untuned defaults `init` used to generate for every
    /// project kind measured as the *slowest* of the four profiles
    /// compared — slower even than the most basic tuned profile, let alone
    /// the production-grade N=2 `simulatorPool` profile the same real
    /// corpus proved (2.17x speedup vs. a tuned `workers: 1` reference
    /// (incrementalBuild + selectCoveringTests, itself already faster than
    /// the fully untuned defaults this warning is about), 100/100 outcome
    /// parity with that reference, 0 integrity violations).
    /// `init`'s own template now ships that profile by default; this warns
    /// the (more common, in practice) case of a config that predates that
    /// change, or one a user wrote by hand without knowing this profile
    /// exists.
    ///
    /// Only for kinds that actually lease a real Simulator —
    /// `simulatorPool` is a no-op for a host-only `swiftPackageMacOS` run.
    /// Never emitted for a kind `doctor` could not resolve at all (the
    /// separate failed-resolution remedy above already covers that case).
    /// A warning, not a failure — this changes wall-clock time, never
    /// correctness, so it must never block `doctor`'s own "Ready" verdict.
    private static func productionProfileItem(kind: ProjectKind, configuration: Configuration) -> [DiagnosisItem] {
        guard kind == .xcodeProject || kind == .xcodeWorkspace || kind == .swiftPackageApple else { return [] }
        guard !configuration.execution.simulatorPool else { return [] }
        return [DiagnosisItem(
            name: "Production profile",
            status: .warning,
            code: .productionProfileRecommended,
            detail: "execution.simulatorPool is not enabled",
            remedy: "A real benchmark against a large iOS app found `simulatorPool: true` with `workers: 2` "
                + "2.17x faster than a tuned workers: 1 reference, with identical outcomes and no integrity "
                + "violations — the measured production-grade profile for this project kind. Add "
                + "`execution.simulatorPool: true`, `execution.workers: 2`, `execution.incrementalBuild: true` "
                + "and `execution.selectCoveringTests: true` to mutantkit.yml. See README.md's "
                + "\"Recommended production profile\" section."
        )]
    }

    private static func remedy(forFailedResolutionIn root: URL, configuration: Configuration) async -> String {
        let fallback = "Set `project.kind`, `project.scheme` and `project.destination` in mutantkit.yml explicitly."
        guard let detection = try? await ProjectDetector.detect(in: root) else { return fallback }

        let xcodeDetection = await XcodeConfigDetector.detect(
            kind: detection.kind, projectFile: detection.projectFile, projectRoot: root
        )

        // Only suggest a field the user's own config left unset or got
        // wrong (or, for `destination`, whatever is already configured is
        // presumably what just failed to resolve) — re-suggesting a
        // scheme/test-target list the user already configured *correctly*
        // would bury the real problem (usually the destination) under an
        // irrelevant, already-satisfied instruction.
        //
        // "Wrong" specifically means: a configured scheme that is not
        // among the real, discovered candidates at all — a typo'd or
        // renamed scheme, the single most likely reason resolution failed
        // when a scheme *was* configured. Found by Codex review before
        // this was committed as done: the first version only checked
        // `== nil`, so a typo'd scheme silently suppressed the one piece
        // of detected information most likely to be the actual fix.
        var lines: [String] = []
        let configuredSchemeIsInvalid = configuration.project.scheme.map { configured in
            !xcodeDetection.schemeCandidates.isEmpty && !xcodeDetection.schemeCandidates.contains(configured)
        } ?? false
        if configuration.project.scheme == nil || configuredSchemeIsInvalid {
            if let scheme = xcodeDetection.scheme {
                lines.append("Detected scheme: \(scheme) — set `project.scheme: \(scheme)`.")
            } else if xcodeDetection.schemeCandidates.count > 1 {
                lines.append("Multiple schemes found (\(xcodeDetection.schemeCandidates.joined(separator: ", "))) — set `project.scheme` to one of these.")
            }
        }
        if configuration.tests.targets.isEmpty, !xcodeDetection.testTargets.isEmpty {
            lines.append("Detected test target(s): \(xcodeDetection.testTargets.joined(separator: ", ")) — add these to `tests.targets`.")
        }
        if let destination = xcodeDetection.destination {
            lines.append("Detected a real available destination: \(destination)\(configuration.project.destination != nil ? " — update `project.destination` to this" : " — set `project.destination` to this").")
        } else if xcodeDetection.destinationDiscoveryFailed {
            lines.append("""
            Could not query the simulator subsystem (a real `simctl` call failed or timed out) — \
            this is not the same as "no simulator installed"; retry once Xcode/CoreSimulator has settled.
            """)
        }

        guard !lines.isEmpty else { return fallback }
        return lines.joined(separator: " ")
    }

    static func deduplicated(_ items: [DiagnosisItem]) -> [DiagnosisItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = item.name.lowercased()
                .replacingOccurrences(of: " toolchain", with: "")
                .replacingOccurrences(of: " kind", with: "")
            return seen.insert(key).inserted
        }
    }
}
