import Foundation
import Testing

/// A deterministic regression test for `Scripts/ci-route.sh` — the script
/// that decides which of CI's ~20 acceptance jobs a given push/PR actually
/// runs. This project's own standing principle treats code that decides
/// which correctness tests to skip as trust-critical, not as an
/// optimization exempt from testing (see that script's own header comment
/// for the full "false skip" framing), so this suite exists for the same
/// reason `CIAcceptanceMatrixClassificationTests` does for the acceptance
/// matrix itself.
///
/// Invokes the real, checked-in script as a subprocess with synthetic
/// changed-file lists and PR-label sets — no new YAML/bash parsing, and no
/// re-implementation of the classification logic to compare against; this
/// exercises the exact artifact CI actually runs.
@Suite("CI route classification (Scripts/ci-route.sh)")
struct CIRouteClassificationTests {
    struct RouteResult: Decodable, Equatable {
        let runFull: Bool
        let runSchemataTargeted: Bool
        let selectedFixtures: [String]
        let reason: String

        enum CodingKeys: String, CodingKey {
            case runFull = "run_full"
            case runSchemataTargeted = "run_schemata_targeted"
            case selectedFixtures = "selected_fixtures"
            case reason
        }
    }

    private static var scriptURL: URL {
        Acceptance.packageRoot.appendingPathComponent("Scripts/ci-route.sh")
    }

    /// Shells out to the real script — the same mechanism
    /// `SchemataIOSSimulatorRuntimeArtifactAcceptanceTests` and friends
    /// already use to invoke `Scripts/build-schemata-runtime.sh` and the
    /// `mutantkit` binary itself (see `Acceptance.binary()`), applied here
    /// to a routing script instead of the product under test.
    private func route(
        event: String,
        labels: [String] = [],
        changedFiles: [String] = []
    ) throws -> RouteResult {
        try #require(
            FileManager.default.isExecutableFile(atPath: Self.scriptURL.path),
            "Scripts/ci-route.sh is missing or not executable at \(Self.scriptURL.path)"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let labelsData = try JSONEncoder().encode(labels)
        let labelsJSON = String(decoding: labelsData, as: UTF8.self)
        process.arguments = [Self.scriptURL.path, event, labelsJSON]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let inputData = Data(changedFiles.joined(separator: "\n").utf8)
        stdin.fileHandleForWriting.write(inputData)
        try stdin.fileHandleForWriting.close()

        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        try #require(
            process.terminationStatus == 0,
            """
            Scripts/ci-route.sh exited \(process.terminationStatus) for event='\(event)' \
            labels=\(labels) changedFiles=\(changedFiles): \(String(decoding: errData, as: UTF8.self))
            """
        )

        return try JSONDecoder().decode(RouteResult.self, from: outData)
    }

    // MARK: - Event / label / dispatch signals -> always full, regardless of paths

    @Test("push always runs the full matrix")
    func pushAlwaysRunsFull() throws {
        let result = try route(event: "push", changedFiles: ["Sources/CLI/Commands/InspectCommand.swift"])
        #expect(result.runFull)
    }

    @Test("workflow_dispatch always runs the full matrix")
    func workflowDispatchAlwaysRunsFull() throws {
        let result = try route(event: "workflow_dispatch")
        #expect(result.runFull)
    }

    @Test("an unrecognized event fails toward the full matrix")
    func unrecognizedEventRunsFull() throws {
        let result = try route(event: "some_future_event_type")
        #expect(result.runFull)
    }

    @Test("ci:full label forces the full matrix regardless of changed paths")
    func ciFullLabelForcesFull() throws {
        let result = try route(
            event: "pull_request",
            labels: ["ci:full"],
            changedFiles: ["Sources/CLI/Commands/InspectCommand.swift"]
        )
        #expect(result.runFull)
    }

    @Test("ci:merge-ready label forces the full matrix regardless of changed paths")
    func ciMergeReadyLabelForcesFull() throws {
        let result = try route(
            event: "pull_request",
            labels: ["some-other-label", "ci:merge-ready"],
            changedFiles: ["Sources/CLI/Commands/InspectCommand.swift"]
        )
        #expect(result.runFull)
    }

    @Test("an empty changed-file list fails toward the full matrix, not a silent skip")
    func emptyChangedFilesRunsFull() throws {
        let result = try route(event: "pull_request", changedFiles: [])
        #expect(result.runFull)
    }

    // MARK: - Trust-critical -> always full, no shortcut

    @Test("RunCommand.swift is trust-critical and runs the full matrix")
    func runCommandIsTrustCritical() throws {
        let result = try route(event: "pull_request", changedFiles: ["Sources/CLI/Commands/RunCommand.swift"])
        #expect(result.runFull)
    }

    @Test("GateCommand.swift is trust-critical and runs the full matrix")
    func gateCommandIsTrustCritical() throws {
        let result = try route(event: "pull_request", changedFiles: ["Sources/CLI/Commands/GateCommand.swift"])
        #expect(result.runFull)
    }

    @Test("a Sources/MutationExecution/ path is trust-critical and runs the full matrix")
    func mutationExecutionIsTrustCritical() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/MutationExecution/ProcessSupervisor.swift"]
        )
        #expect(result.runFull)
    }

    // MARK: - Targeted groups

    @Test("an unrelated CLI command file selects only cli-commands")
    func unrelatedCLIFileSelectsCliCommands() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/CLI/Commands/InspectCommand.swift"]
        )
        #expect(!result.runFull)
        #expect(Set(result.selectedFixtures) == ["cli-commands"])
    }

    @Test("a SetupCommand-shaped path selects the onboarding fixture set")
    func setupCommandSelectsOnboardingSet() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/CLI/Commands/SetupCommand.swift"]
        )
        #expect(!result.runFull)
        #expect(Set(result.selectedFixtures) == ["golden-path-onboarding", "cli-commands", "xcode-config-detector"])
    }

    @Test("ReadinessCheck.swift (not under Commands/) also selects the onboarding fixture set")
    func readinessCheckSelectsOnboardingSet() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/CLI/ReadinessCheck.swift"]
        )
        #expect(!result.runFull)
        #expect(Set(result.selectedFixtures) == ["golden-path-onboarding", "cli-commands", "xcode-config-detector"])
    }

    @Test("a sharding-layer path selects shard-merge and cli-commands, not the whole swift-package family")
    func shardCommandSelectsShardingSet() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/CLI/Commands/MergeCommand.swift"]
        )
        #expect(!result.runFull)
        #expect(Set(result.selectedFixtures) == ["shard-merge", "cli-commands"])
    }

    @Test("a schemata-named path selects the schemata fixture set")
    func schemataPathSelectsSchemataSet() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/MutantKitSchemataRuntimeC/runtime.c"]
        )
        #expect(!result.runFull)
        #expect(result.runSchemataTargeted)
        #expect(Set(result.selectedFixtures) == ["ror-schemata-compile"])
    }

    @Test("an Xcode-adapter path selects every xcode-* fixture plus cli-commands")
    func xcodeAdapterPathSelectsXcodeSet() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/AppleBuildAdapters/XcodeBuildAdapter.swift"]
        )
        #expect(!result.runFull)
        #expect(Set(result.selectedFixtures) == [
            "xcode-project", "xcode-workspace", "xcode-app-debug-dylib", "xcode-unlinked-source",
            "xcode-config-detector", "xcode-batch-testing", "xcode-batch-testing-ui-target",
            "xcode-coverage-selection", "xcode-incremental-batch-testing", "xcode-wave-early-kill",
            "cli-commands"
        ])
    }

    @Test("a SwiftPM-adapter path selects the swift-package fixture family")
    func swiftPackageAdapterPathSelectsSwiftPackageSet() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/AppleBuildAdapters/SwiftPackageMacOSAdapter.swift"]
        )
        #expect(!result.runFull)
        #expect(Set(result.selectedFixtures) == ["swift-package", "swift-package-coverage", "swift-package-ios", "shard-merge"])
    }

    // MARK: - Unknown paths -> fail toward the full matrix

    @Test("a mix of a known group path and an unknown path runs the full matrix")
    func knownPlusUnknownPathRunsFull() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: [
                "Sources/CLI/Commands/InspectCommand.swift",
                "Sources/BrandNewSubsystem/Whatever.swift"
            ]
        )
        #expect(result.runFull)
    }

    @Test("an unknown-only path runs the full matrix")
    func unknownOnlyPathRunsFull() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/BrandNewSubsystem/Whatever.swift"]
        )
        #expect(result.runFull)
    }

    // MARK: - Every fixture the router can emit must be real

    /// The one, narrowly-scoped exception to "every fixture the router can
    /// emit must exist in the real matrix": `golden-path-onboarding` is the
    /// fixture the still-separate golden-path-onboarding feature branch
    /// will add (see `GoldenPathOnboardingAcceptanceTests` there). The
    /// router is deliberately taught this name now, keyed to what it will
    /// be, so routing is already correct the instant that branch merges —
    /// see `Scripts/ci-route.sh`'s own `onboarding` group comment. Nothing
    /// else may rely on this exception: any other name the router can emit
    /// that is missing from the real matrix is exactly the drift this test
    /// exists to catch (a renamed/removed fixture silently breaking the
    /// router's output).
    private static let fixturesAllowedToBePending: Set<String> = ["golden-path-onboarding"]

    /// Every distinct changed-path shape that exercises one non-full,
    /// non-trust-critical targeted group in `Scripts/ci-route.sh` — the
    /// union of `selectedFixtures` across all of these is therefore every
    /// fixture name the router's targeted groups can ever emit. Trust-
    /// critical paths are excluded on purpose: they emit no fixtures at all
    /// (they mean "run everything"), so they contribute nothing to this set.
    private static let representativeTargetedPaths: [String] = [
        "Sources/CLI/Commands/InspectCommand.swift", // cli-commands
        "Sources/CLI/Commands/SetupCommand.swift", // onboarding
        "Sources/CLI/Commands/ShardCommand.swift", // sharding
        "Sources/MutantKitSchemataRuntimeC/runtime.c", // schemata
        "Sources/AppleBuildAdapters/XcodeBuildAdapter.swift", // xcode-adapter
        "Sources/AppleBuildAdapters/SwiftPackageMacOSAdapter.swift" // swift-package
    ]

    /// Parses the acceptance job's real `- fixture: <name>` matrix entries
    /// out of the checked-in `ci.yml`, the same source of truth
    /// `CIAcceptanceMatrixClassificationTests` cross-checks against. Kept
    /// intentionally narrow (fixture names only, scoped to the `acceptance:`
    /// job's own `include:` block) rather than sharing that file's private
    /// parser, since this test only ever needs the name column.
    private func realMatrixFixtureNames() throws -> Set<String> {
        let url = Acceptance.packageRoot.appendingPathComponent(".github/workflows/ci.yml")
        let contents = try String(contentsOf: url, encoding: .utf8)

        var names: Set<String> = []
        var inAcceptanceJob = false
        var inMatrixInclude = false

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("  acceptance:") {
                inAcceptanceJob = true
                continue
            }
            if inAcceptanceJob, line.hasPrefix("  "), !line.hasPrefix("   "), !line.hasPrefix("  acceptance:") {
                break // left the acceptance job's own block entirely
            }
            guard inAcceptanceJob else { continue }

            if trimmed == "include:" { inMatrixInclude = true; continue }
            guard inMatrixInclude else { continue }
            if trimmed == "steps:" { break }

            if trimmed.hasPrefix("- fixture:") {
                var value = String(trimmed.dropFirst("- fixture:".count)).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                names.insert(value)
            }
        }

        try #require(!names.isEmpty, "parsed zero acceptance matrix fixture names from \(url.path)")
        return names
    }

    @Test("every fixture the router can emit exists in the real acceptance matrix, or is the one documented pending exception")
    func everyEmittableFixtureExistsOrIsDocumentedPending() throws {
        var reachable: Set<String> = []
        for path in Self.representativeTargetedPaths {
            let result = try route(event: "pull_request", changedFiles: [path])
            reachable.formUnion(result.selectedFixtures)
        }
        try #require(
            !reachable.isEmpty,
            "collected zero fixtures across every representative targeted path -- the paths above no longer match any group"
        )

        let realFixtures = try realMatrixFixtureNames()
        let missing = reachable.subtracting(realFixtures)

        #expect(
            missing == Self.fixturesAllowedToBePending,
            """
            the router can emit fixture name(s) \(missing.sorted()) that do not exist in the real acceptance \
            matrix and are not the documented pending exception \(Self.fixturesAllowedToBePending.sorted()) -- \
            a renamed or removed fixture would otherwise leave the router selecting a fixture that never runs
            """
        )
    }
}
