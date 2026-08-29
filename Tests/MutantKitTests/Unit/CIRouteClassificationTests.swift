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
struct CIRouteResult: Decodable, Equatable {
    let runFull: Bool
    let runSchemataTargeted: Bool
    let selectedFixtures: [String]
    let acceptanceMatrix: CIRouteAcceptanceMatrix
    let reason: String

    enum CodingKeys: String, CodingKey {
        case runFull = "run_full"
        case runSchemataTargeted = "run_schemata_targeted"
        case selectedFixtures = "selected_fixtures"
        case acceptanceMatrix = "acceptance_matrix"
        case reason
    }
}

/// Mirrors the `{"include": [...]}` shape GitHub Actions' `fromJSON(...)`
/// expects for `strategy.matrix` — see `Scripts/ci-route.sh`'s own header
/// comment and `.github/workflows/ci.yml`'s `acceptance` job. Each `include`
/// entry is a *shard* (one `acceptance` job) carrying one or more fixtures
/// to run in sequence — on a full-matrix run, fixtures grouped by
/// `Scripts/ci-fixtures.json`'s own `shard` field; on a targeted run, one
/// single-fixture shard per selected fixture (see `ci-route.sh`'s header
/// comment for why).
struct CIRouteAcceptanceMatrix: Decodable, Equatable {
    struct Fixture: Decodable, Equatable {
        let fixture: String
        let filter: String
        let simulator: String?
        let wave: String?
    }

    struct Entry: Decodable, Equatable {
        let shard: String
        let simulator: String?
        let fixtures: [Fixture]
    }

    let include: [Entry]
}

/// Shells out to the real `Scripts/ci-route.sh` — the same mechanism
/// `SchemataIOSSimulatorRuntimeArtifactAcceptanceTests` and friends already
/// use to invoke `Scripts/build-schemata-runtime.sh` and the `mutantkit`
/// binary itself (see `Acceptance.binary()`), applied here to a routing
/// script instead of the product under test. Shared by both halves of this
/// suite (split across two `@Suite` structs purely to stay under
/// SwiftLint's `type_body_length`, not because the two halves test
/// different things) so there is exactly one way to invoke the script.
func ciRoute(
    event: String,
    labels: [String] = [],
    changedFiles: [String] = []
) throws -> CIRouteResult {
    let scriptURL = Acceptance.packageRoot.appendingPathComponent("Scripts/ci-route.sh")
    try #require(
        FileManager.default.isExecutableFile(atPath: scriptURL.path),
        "Scripts/ci-route.sh is missing or not executable at \(scriptURL.path)"
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    let labelsData = try JSONEncoder().encode(labels)
    let labelsJSON = String(decoding: labelsData, as: UTF8.self)
    process.arguments = [scriptURL.path, event, labelsJSON]

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

    return try JSONDecoder().decode(CIRouteResult.self, from: outData)
}

@Suite("CI route classification (Scripts/ci-route.sh)")
struct CIRouteClassificationTests {
    private func route(
        event: String,
        labels: [String] = [],
        changedFiles: [String] = []
    ) throws -> CIRouteResult {
        try ciRoute(event: event, labels: labels, changedFiles: changedFiles)
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

    // C0 landed real defects in exactly these two files (PlanCommand writing
    // a plan from an unproven toolchain identity; VerifyCommand reporting a
    // false "match" from incomplete evidence) -- a future regression in
    // either must reach the full matrix, not the coarse cli-commands slice.
    @Test("PlanCommand.swift is trust-critical and runs the full matrix")
    func planCommandIsTrustCritical() throws {
        let result = try route(event: "pull_request", changedFiles: ["Sources/CLI/Commands/PlanCommand.swift"])
        #expect(result.runFull)
    }

    @Test("VerifyCommand.swift is trust-critical and runs the full matrix")
    func verifyCommandIsTrustCritical() throws {
        let result = try route(event: "pull_request", changedFiles: ["Sources/CLI/Commands/VerifyCommand.swift"])
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
}

/// The `acceptance_matrix` field, unknown-path fail-open behavior, and the
/// fixture-existence cross-check -- split into its own `@Suite` purely to
/// stay under SwiftLint's `type_body_length` (see `ciRoute(...)`'s own doc
/// comment); conceptually still one suite for `Scripts/ci-route.sh`.
@Suite("CI route classification: acceptance_matrix and fixture existence")
struct CIRouteAcceptanceMatrixTests {
    private func route(
        event: String,
        labels: [String] = [],
        changedFiles: [String] = []
    ) throws -> CIRouteResult {
        try ciRoute(event: event, labels: labels, changedFiles: changedFiles)
    }

    // MARK: - acceptance_matrix

    // `acceptance_matrix` is the real, already-filtered GitHub Actions
    // matrix object -- see Scripts/ci-route.sh's own header comment and
    // .github/workflows/ci.yml's `acceptance` job, which now reads this
    // field directly via `strategy.matrix: fromJSON(...)` instead of a
    // static `include:` list.

    @Test("a targeted run's acceptance_matrix contains only the selected fixtures, one single-fixture shard each")
    func targetedAcceptanceMatrixContainsOnlySelectedFixtures() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/CLI/Commands/InspectCommand.swift"]
        )
        #expect(!result.runFull)
        #expect(result.acceptanceMatrix.include == [
            CIRouteAcceptanceMatrix.Entry(
                shard: "cli-commands",
                simulator: "1",
                fixtures: [
                    CIRouteAcceptanceMatrix.Fixture(
                        fixture: "cli-commands",
                        filter: "CLICommandsAcceptanceTests",
                        simulator: "1",
                        wave: nil
                    )
                ]
            )
        ])
    }

    @Test("a targeted run keeps each selected fixture in its own independent shard (today's parallelism, unchanged)")
    func targetedRunKeepsOneShardPerFixture() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/AppleBuildAdapters/XcodeBuildAdapter.swift"]
        )
        #expect(!result.runFull)
        // Sharding (grouping several fixtures into one job) is a full-matrix-only
        // optimization -- see Scripts/ci-route.sh's own header comment. A
        // targeted run must still create one independent `include` entry per
        // selected fixture, exactly as before this change, so its own
        // parallelism/job count is never reduced.
        #expect(result.acceptanceMatrix.include.count == result.selectedFixtures.count)
        for entry in result.acceptanceMatrix.include {
            #expect(entry.fixtures.count == 1)
            #expect(entry.shard == entry.fixtures[0].fixture)
        }
        let shardNames = Set(result.acceptanceMatrix.include.map(\.shard))
        #expect(shardNames == Set(result.selectedFixtures))
    }

    @Test("a targeted run's acceptance_matrix includes golden-path-onboarding now that it's real")
    func targetedAcceptanceMatrixIncludesOnboardingFixture() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/CLI/Commands/SetupCommand.swift"]
        )
        #expect(!result.runFull)
        // `golden-path-onboarding` now exists for real in Scripts/ci-fixtures.json
        // (the golden-path onboarding feature merged) -- it must appear in the
        // real, ready-to-use matrix object, not just the informational
        // `selectedFixtures` list.
        let matrixFixtures = Set(result.acceptanceMatrix.include.flatMap(\.fixtures).map(\.fixture))
        #expect(matrixFixtures == ["cli-commands", "xcode-config-detector", "golden-path-onboarding"])
    }

    @Test("an xcode-adapter path's acceptance_matrix carries wave: \"1\" on xcode-wave-early-kill")
    func targetedAcceptanceMatrixCarriesWaveField() throws {
        let result = try route(
            event: "pull_request",
            changedFiles: ["Sources/AppleBuildAdapters/XcodeBuildAdapter.swift"]
        )
        let fixture = try #require(
            result.acceptanceMatrix.include.flatMap(\.fixtures).first { $0.fixture == "xcode-wave-early-kill" }
        )
        #expect(fixture.wave == "1")
    }

    @Test("push's acceptance_matrix contains every real fixture, not a second hardcoded copy")
    func fullRunAcceptanceMatrixContainsEveryRealFixture() throws {
        let result = try route(event: "push")
        #expect(result.runFull)
        let matrixFixtures = Set(result.acceptanceMatrix.include.flatMap(\.fixtures).map(\.fixture))
        #expect(matrixFixtures == (try realMatrixFixtureNames()))
    }

    // MARK: - Full-matrix sharding (Phase 1 acceptance-matrix reshaping)

    //
    // A full run groups the 18 fixtures into a handful of weighted shard
    // jobs instead of one job per fixture -- see Scripts/ci-route.sh's own
    // header comment and Scripts/ci-fixtures.json's `_shard_readme` for why.
    // These tests pin the three guarantees that matter for correctness
    // (never fixture count/scheduling speed): every fixture lands in
    // exactly one shard, no shard is empty, and each shard's own
    // `simulator` flag is the true OR of its member fixtures.

    @Test("a full run's shards partition every real fixture exactly once -- none missing, none duplicated")
    func fullRunShardsPartitionEveryFixtureExactlyOnce() throws {
        let result = try route(event: "push")
        #expect(result.runFull)

        let allFixturesAcrossShards = result.acceptanceMatrix.include.flatMap(\.fixtures).map(\.fixture)
        // Exactly-once membership: the flattened list's count matches its
        // own de-duplicated set's count, and that set matches the real
        // fixture list -- a fixture appearing in two shards, or in none,
        // would fail one of these two checks.
        #expect(allFixturesAcrossShards.count == Set(allFixturesAcrossShards).count)
        #expect(Set(allFixturesAcrossShards) == (try realMatrixFixtureNames()))

        for entry in result.acceptanceMatrix.include {
            #expect(!entry.fixtures.isEmpty, "shard '\(entry.shard)' has zero fixtures")
        }
    }

    @Test("a full run's shard-level simulator flag is the true OR of its member fixtures")
    func fullRunShardSimulatorFlagIsOrOfMembers() throws {
        let result = try route(event: "push")
        #expect(result.runFull)

        for entry in result.acceptanceMatrix.include {
            let anyMemberNeedsSimulator = entry.fixtures.contains { $0.simulator == "1" }
            let expectedSimulator = anyMemberNeedsSimulator ? "1" : "0"
            #expect(
                entry.simulator == expectedSimulator,
                """
                shard '\(entry.shard)' declares simulator: \(entry.simulator ?? "<missing>"), \
                but its own members' OR is \(expectedSimulator)
                """
            )
        }
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

    /// `golden-path-onboarding` used to be the one narrowly-scoped, documented
    /// exception here (taught to the router ahead of the feature branch that
    /// would add it) -- now that the golden-path onboarding work has merged
    /// and `Scripts/ci-fixtures.json` carries a real entry for it, there is no
    /// exception left. Any name the router can emit that is missing from the
    /// real matrix is exactly the drift this test exists to catch (a
    /// renamed/removed fixture silently breaking the router's output).
    private static let fixturesAllowedToBePending: Set<String> = []

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

    /// Reads the acceptance job's real fixture names out of the checked-in
    /// `Scripts/ci-fixtures.json` — the single source of truth both
    /// `Scripts/ci-route.sh` and `.github/workflows/ci.yml`'s own
    /// full-matrix case read (see that script's header comment), and the
    /// same source `CIAcceptanceMatrixClassificationTests` cross-checks
    /// against. Handles the same `oss-public/` overlay path that file's own
    /// loader does.
    private func realMatrixFixtureNames() throws -> Set<String> {
        struct FixturesFile: Decodable {
            struct Entry: Decodable { let fixture: String }
            let fixtures: [Entry]
        }

        let root = Acceptance.packageRoot
        var url: URL?
        for candidate in [
            root.appendingPathComponent("Scripts/ci-fixtures.json"),
            root.appendingPathComponent("oss-public/Scripts/ci-fixtures.json")
        ] where FileManager.default.fileExists(atPath: candidate.path) {
            url = candidate
            break
        }
        let resolvedURL = try #require(url, "no Scripts/ci-fixtures.json found under \(root.path)")

        let data = try Data(contentsOf: resolvedURL)
        let file = try JSONDecoder().decode(FixturesFile.self, from: data)
        let names = Set(file.fixtures.map(\.fixture))

        try #require(!names.isEmpty, "parsed zero acceptance matrix fixture names from \(resolvedURL.path)")
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
