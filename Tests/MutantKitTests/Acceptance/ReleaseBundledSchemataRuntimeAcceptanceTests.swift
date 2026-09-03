import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// The clean-machine proof: a real `mutantkit` release install —
/// exactly what `scripts/release-build.sh` produces and an end user
/// downloads — runs schemata mode with **no**
/// `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` set at all, resolving
/// `MutantKitSchemataRuntime` purely from the `lib/mutantkit/schemata/`
/// tree the release package bundles next to the executable
/// (`SchemataRuntimeLibraryLocator`'s bundled path).
///
/// What this actually proves is narrower than "runs with no repo checkout
/// present": the *test harness* driving this suite (`swift test`, staged
/// fixtures under `Fixtures/`, `xcodegen` for the Xcode-project case) still
/// runs from a real source checkout, same as every other acceptance suite —
/// what's proven is that the *released `mutantkit` executable's own runtime
/// resolution* never touches that checkout or `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE`
/// at all, which is the only thing `SchemataRuntimeLibraryLocator`'s bundled
/// path is actually claiming.
///
/// Deliberately does **not** shell out to `scripts/release-build.sh` or to
/// `swift build` itself, for the same package-build-lock reason
/// `SchemataIOSSimulatorRuntimeArtifactAcceptanceTests`'s own doc comment
/// gives: the release package must already exist, built as a prerequisite
/// CI step (see `.github/workflows/ci.yml`'s `release-bundled-schemata-*`
/// jobs), with its root handed in via `MUTANTKIT_RELEASE_PACKAGE_ROOT`.
///
/// Two suites in this file cover the macOS side; `ReleaseBundledSchemataXcodeIOSSimulatorAcceptanceTests`
/// below covers the iOS-Simulator side with the same two-layer proof:
///
/// - A real, full `mutantkit plan`/`mutantkit run` against a fixture,
///   through the actual release executable — the strongest available
///   proof, since it exercises the whole pipeline (locate, link, build,
///   execute, collect evidence) rather than just the locator's own
///   resolution step. `macOSArchiveResolvesFromBundle`'s sibling on the
///   macOS side is `schemataRunSucceedsFromBundledRuntimeAlone`; on the
///   iOS-Simulator side it is
///   `ReleaseBundledSchemataXcodeIOSSimulatorAcceptanceTests
///   .xcodeProjectSchemataRunSucceedsFromBundledRuntimeAlone` — an earlier
///   draft of this suite had no iOS-Simulator counterpart to this real-run
///   proof at all, only the archive-inspection test below; that was a real
///   gap, not a deliberate scope decision.
/// - `macOSArchiveResolvesFromBundle`/`iOSSimulatorArchiveResolvesFromBundle`:
///   inspects the real Mach-O archive directly (`nm`/`lipo`/`otool`) —
///   proof the bundled artifact itself is real and correctly built, distinct
///   from proof that a run can actually use it.
@Suite("Acceptance: release package's bundled schemata runtime", .enabled(if: Acceptance.releasePackageRoot != nil))
struct ReleaseBundledSchemataRuntimeAcceptanceTests {
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    operators:
      profile: experimental
    execution:
      strategy: schemata
    reports: [console, json]
    """

    /// Fails loudly (never silently passes) if the CI job wiring this
    /// suite is meant to prove ever regresses to inheriting an override
    /// from its own environment — the whole point of this suite is a run
    /// with none set.
    private func requireNoOverrideInEnvironment() throws {
        let value = ProcessInfo.processInfo.environment[SchemataRuntimeLibraryLocator.overrideEnvironmentVariable]
        #expect(value == nil, "this suite must run with no \(SchemataRuntimeLibraryLocator.overrideEnvironmentVariable) set, or it proves nothing about the bundled path")
    }

    @Test("A real schemata run against the packaged release binary succeeds with no override set")
    func schemataRunSucceedsFromBundledRuntimeAlone() throws {
        try requireNoOverrideInEnvironment()

        let result = try Acceptance.planAndRun(
            fixture: "SchemataSwiftPackageMacOS", configuration: Self.configuration, binary: try Acceptance.releasePackageBinary()
        )
        #expect(result.exitCode == 0, "\(result.runOutput)")
        #expect(result.report.baseline.passed, "the baseline must reflect a genuinely passing suite")

        let strategy = try #require(result.report.executionStrategy)
        #expect(strategy.requested == .schemata)
        #expect(
            strategy.effectiveCount > 0,
            """
            at least one candidate must have actually run through the schemata backend — a silent full fallback \
            would mean the bundled runtime was never really linked, and this suite would prove nothing
            """
        )
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [tool] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) \(arguments.joined(separator: " ")) failed:\n\(output)")
        return output
    }

    @Test("The bundled macOS archive resolves with provenance .bundled and exports both v3 runtime entry points")
    func macOSArchiveResolvesFromBundle() throws {
        let located = try SchemataRuntimeLibraryLocator.locate(
            for: .macOS, environment: [:], sourceDirectory: nil, executableURL: try Acceptance.releasePackageBinary()
        )
        #expect(located.provenance == .bundled)

        let output = try run("nm", ["-gU", located.archivePath.path])
        #expect(output.contains("T _mutantkit_register_unit_v3"))
        #expect(output.contains("T _mutantkit_is_active_v3"))
    }

    @Test("The bundled iOS-Simulator archive resolves with provenance .bundled, contains both slices, and is built for the simulator")
    func iOSSimulatorArchiveResolvesFromBundle() throws {
        let located = try SchemataRuntimeLibraryLocator.locate(
            for: .iOSSimulator, environment: [:], sourceDirectory: nil, executableURL: try Acceptance.releasePackageBinary()
        )
        #expect(located.provenance == .bundled)

        let archsOutput = try run("lipo", ["-archs", located.archivePath.path])
        let archs = Set(archsOutput.split(whereSeparator: \.isWhitespace).map(String.init))
        #expect(archs.isSuperset(of: ["arm64", "x86_64"]), "expected arm64 and x86_64, got: \(archsOutput)")

        let otoolOutput = try run("otool", ["-l", located.archivePath.path])
        let platformLines = otoolOutput
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("platform ") }
        #expect(!platformLines.isEmpty, "expected at least one LC_BUILD_VERSION platform line in:\n\(otoolOutput)")
        #expect(platformLines.allSatisfy { $0 == "platform 7" }, "expected every slice to report platform 7 (iOS Simulator): \(platformLines)")

        let nmOutput = try run("nm", ["-gU", located.archivePath.path])
        #expect(nmOutput.contains("T _mutantkit_register_unit_v3"))
        #expect(nmOutput.contains("T _mutantkit_is_active_v3"))
    }
}

/// The real E2E counterpart to `iOSSimulatorArchiveResolvesFromBundle`
/// above: that test only proves the bundled iOS-Simulator archive is a
/// real, well-formed Mach-O with the right symbols — it never proves a
/// released binary can actually *run* schemata mode against a real Xcode
/// project on a real simulator using nothing but its own bundled runtime.
/// This suite closes that gap, driving the same fully-covered fixture
/// (`Fixtures/SchemataMatrixXcodeProject`) `SchemataSupportedMatrixXcodeProjectAcceptanceTests`
/// already proves works via the developer override — here through the
/// packaged release executable instead, with no
/// `MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` anywhere in this process's
/// environment. A separate `@Suite` from the one above (not just a third
/// `@Test`) because this one additionally needs a real simulator
/// (`Acceptance.simulatorEnabled`), which the macOS-only tests above do
/// not.
@Suite(
    "Acceptance: release package's bundled schemata runtime (Xcode project, iOS Simulator)",
    .enabled(if: Acceptance.releasePackageRoot != nil && Acceptance.simulatorEnabled)
)
struct ReleaseBundledSchemataXcodeIOSSimulatorAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeProject
          scheme: MatrixWidget
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [MatrixWidgetTests]
        operators:
          profile: default
        execution:
          strategy: schemata
          workers: 1
        reports: [console, json]
        """
    }

    /// Same requirement as `ReleaseBundledSchemataRuntimeAcceptanceTests`'s
    /// own — see its doc comment.
    private func requireNoOverrideInEnvironment() throws {
        let value = ProcessInfo.processInfo.environment[SchemataRuntimeLibraryLocator.overrideEnvironmentVariable]
        #expect(
            value == nil,
            "this suite must run with no \(SchemataRuntimeLibraryLocator.overrideEnvironmentVariable) set, or it proves nothing about the bundled path"
        )
    }

    @Test("Xcode project + iOS Simulator via the packaged release binary: fully activates, zero fallback, bundled runtime alone")
    func xcodeProjectSchemataRunSucceedsFromBundledRuntimeAlone() throws {
        try requireNoOverrideInEnvironment()

        let run = try Acceptance.planAndRun(
            fixture: "SchemataMatrixXcodeProject", configuration: try Self.configuration(), binary: try Acceptance.releasePackageBinary()
        )
        #expect(run.exitCode == 0, "\(run.runOutput)")
        #expect(run.report.baseline.passed, "the baseline must reflect a genuinely passing suite")

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")

        let strategy = try #require(run.report.executionStrategy)
        #expect(strategy.requested == .schemata)
        #expect(strategy.degradationReason == nil, "a whole-run degradation means the bundled runtime was never really used")
        #expect(
            strategy.effectiveCount == integrity.planned,
            "every planned mutation must go through the real schemata backend, purely from the bundled runtime"
        )
        #expect(
            strategy.fallbackCount == 0,
            "this fixture is fully covered on purpose — any fallback here means the bundled iOS-Simulator path has a real gap"
        )
        #expect((strategy.fallbackReasonCounts ?? [:]).isEmpty)
        #expect((strategy.plannerFallbackReasonCounts ?? [:]).isEmpty)

        let operationalIssueKinds = Set(run.report.operationalIssues.map(\.kind))
        #expect(!operationalIssueKinds.contains(.schemataChunkBuildFailed))
        #expect(!operationalIssueKinds.contains(.schemataChunkReceiptUnavailable))
    }
}
