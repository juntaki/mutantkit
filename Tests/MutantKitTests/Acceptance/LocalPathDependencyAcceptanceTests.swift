import Foundation
import MutationExecution
import MutationModel
import Testing

/// The whole pipeline against a project whose local package dependencies live
/// beside it rather than inside it (#77): `Core -> ../SwiftMapper ->
/// ../Logging` (`Fixtures/LocalPathDependencies`), with `Core` as
/// `--project-root`.
///
/// `swift test` in `Core` passes in place. A sandbox holding a copy of `Core`
/// alone could not find `../SwiftMapper`: the unmutated build exited 1 with no
/// compiler diagnostic and `run` ended in a baseline mismatch. Each sandbox
/// now carries the siblings beside the project copy, at their original
/// relative positions, with no manifest rewriting.
@Suite(
    "Acceptance: Swift package with sibling local-path dependencies",
    .enabled(if: Acceptance.isEnabled),
    .subprocessExclusive
)
struct LocalPathDependencyAcceptanceTests {
    private static func configuration(
        retestKilledMutants: Bool = false, selectCoveringTests: Bool = false, projectPath: String? = nil,
        sources: String = "Sources/**"
    ) -> String {
        """
        version: 1
        project:
          kind: swiftPackageMacOS
        \(projectPath.map { "  path: \($0)" } ?? "")
        sources:
          include: [\(sources)]
        operators:
          profile: default
        execution:
          strategy: isolated
          workers: 1
          retestKilledMutants: \(retestKilledMutants)
          measureCoverage: \(selectCoveringTests)
          selectCoveringTests: \(selectCoveringTests)
        reports: [console, json]
        """
    }

    /// The staged fixture: the layout root holding `Core`, `SwiftMapper` and
    /// `Logging`, and `Core` itself with its configuration written in.
    private static func stageCore(configuration: String = Self.configuration()) throws -> (staged: URL, core: URL) {
        let staged = try Acceptance.stageFixture("LocalPathDependencies")
        let core = staged.appendingPathComponent("Core")
        try Data(configuration.utf8).write(to: core.appendingPathComponent("mutantkit.yml"), options: .atomic)
        return (staged, core)
    }

    /// `Core` moved to `Umbrella/Package` and pointed at its siblings with
    /// `../../`, so `--project-root` (`Umbrella`) holds the package under
    /// `project.path` while the siblings stay outside it: a sandbox workspace
    /// nested in its container, `project.path` below that, and external
    /// packages beside it (#78 combined with #77).
    private static func stageUmbrella() throws -> (staged: URL, umbrella: URL) {
        let staged = try Acceptance.stageFixture("LocalPathDependencies")
        let umbrella = staged.appendingPathComponent("Umbrella")
        try FileManager.default.createDirectory(at: umbrella, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staged.appendingPathComponent("Core"), to: umbrella.appendingPathComponent("Package"))
        let manifest = umbrella.appendingPathComponent("Package/Package.swift")
        let text = try String(contentsOf: manifest, encoding: .utf8)
            .replacingOccurrences(of: #".package(path: "../SwiftMapper")"#, with: #".package(path: "../../SwiftMapper")"#)
        try Data(text.utf8).write(to: manifest, options: .atomic)
        try Data(Self.configuration(projectPath: "Package", sources: "Package/Sources/**").utf8)
            .write(to: umbrella.appendingPathComponent("mutantkit.yml"), options: .atomic)
        return (staged, umbrella)
    }

    private static func planAndRun(in directory: URL) throws -> (run: (exitCode: Int32, output: String), report: RunReport?) {
        let plan = try Acceptance.run(["plan", "--output", "plan.json"], in: directory)
        guard plan.exitCode == 0 else {
            throw AcceptanceError.commandFailed(command: "plan", exitCode: plan.exitCode, output: plan.output)
        }
        let reportURL = directory.appendingPathComponent(".mutantkit/report.json")
        try? FileManager.default.removeItem(at: reportURL)
        let run = try Acceptance.run(["run", "--plan", "plan.json", "--report", "json"], in: directory)
        guard let data = try? Data(contentsOf: reportURL) else { return (run, nil) }
        return (run, try MutationPlan.decoder().decode(RunReport.self, from: data))
    }

    private static func killed(_ report: RunReport) -> Set<String> {
        Set(report.results.filter { $0.outcome == .killedByAssertion }.map(\.point.id.rawValue))
    }

    /// What a run that really built and tested every mutant in a sandbox looks
    /// like, as opposed to one that failed to build it.
    private static func expectRealOutcomes(_ outcome: (run: (exitCode: Int32, output: String), report: RunReport?)) throws {
        let report = try #require(outcome.report, "no report was written: \(outcome.run.output)")
        #expect(report.baseline.passed, "\(outcome.run.output)")
        #expect(report.integrity.violations.isEmpty, "\(report.integrity.violations.map(\.detail))")
        #expect(!report.results.isEmpty, "\(outcome.run.output)")
        let infrastructure = report.results.filter { $0.outcome == .infrastructureFailure }
        #expect(infrastructure.isEmpty, "\(infrastructure.map(\.diagnosis))")
        #expect(!killed(report).isEmpty, "\(report.results.map(\.outcome))")
    }

    // MARK: - The reported case

    @Test("dry-run builds and tests the unmutated project with its sibling dependencies")
    func dryRunSucceeds() throws {
        let (staged, core) = try Self.stageCore()
        defer { try? FileManager.default.removeItem(at: staged) }

        let dryRun = try Acceptance.run(["dry-run"], in: core)

        #expect(dryRun.exitCode == 0, "\(dryRun.output)")
        #expect(dryRun.output.contains("Local packages: Logging (../Logging), SwiftMapper (../SwiftMapper)"), "\(dryRun.output)")
    }

    @Test("run gives every mutant a real outcome, including through the transitive sibling")
    func runSucceeds() throws {
        let (staged, core) = try Self.stageCore()
        defer { try? FileManager.default.removeItem(at: staged) }

        try Self.expectRealOutcomes(Self.planAndRun(in: core))
    }

    /// The confirmation retest runs in the real project location, where the
    /// siblings sit at their true place. If it could not load the graph, a kill
    /// would surface as one it could not confirm.
    @Test("With retestKilledMutants on, every kill is confirmed and the killed set is unchanged")
    func confirmationRetestIsConsistent() throws {
        let (plainStaged, plainCore) = try Self.stageCore()
        defer { try? FileManager.default.removeItem(at: plainStaged) }
        let (retestStaged, retestCore) = try Self.stageCore(configuration: Self.configuration(retestKilledMutants: true))
        defer { try? FileManager.default.removeItem(at: retestStaged) }

        let plain = try Self.planAndRun(in: plainCore)
        let retest = try Self.planAndRun(in: retestCore)

        let plainReport = try #require(plain.report, "no report was written: \(plain.run.output)")
        let retestReport = try #require(retest.report, "no report was written: \(retest.run.output)")
        #expect(plainReport.baseline.passed && retestReport.baseline.passed)
        #expect(!Self.killed(plainReport).isEmpty)
        #expect(Self.killed(retestReport) == Self.killed(plainReport))
        #expect(retestReport.integrity.violations.isEmpty, "\(retestReport.integrity.violations.map(\.detail))")
    }

    // MARK: - With project.path (#78)

    @Test("A package at project.path whose siblings are outside --project-root builds in a nested workspace")
    func projectPathWithExternalSiblings() throws {
        let (staged, umbrella) = try Self.stageUmbrella()
        defer { try? FileManager.default.removeItem(at: staged) }

        try Self.expectRealOutcomes(Self.planAndRun(in: umbrella))
    }

    // MARK: - Run identity

    /// Runs the plan already written by `planAndRun`, replacing any earlier
    /// report so a failed run can never be read as the previous run's.
    private static func runPlanned(in core: URL) throws -> (run: (exitCode: Int32, output: String), report: RunReport?) {
        let reportURL = core.appendingPathComponent(".mutantkit/report.json")
        try? FileManager.default.removeItem(at: reportURL)
        let run = try Acceptance.run(["run", "--plan", "plan.json", "--report", "json"], in: core)
        guard let data = try? Data(contentsOf: reportURL) else { return (run, nil) }
        return (run, try MutationPlan.decoder().decode(RunReport.self, from: data))
    }

    /// Moves every checkpoint in a run directory into `destination` (or back
    /// again), returning how many were moved. With the checkpoints set aside, a
    /// run can reuse a verdict only through the result cache.
    @discardableResult
    private static func moveCheckpoints(from source: URL, to destination: URL) throws -> Int {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { $0.hasPrefix("checkpoint-") }
        for name in names {
            try FileManager.default.moveItem(
                at: source.appendingPathComponent(name), to: destination.appendingPathComponent(name)
            )
        }
        return names.count
    }

    private static func origins(_ report: RunReport) -> Set<ResultOrigin> {
        Set(report.results.map(\.origin))
    }

    private static func verdicts(_ report: RunReport) -> [String: MutationOutcome] {
        Dictionary(uniqueKeysWithValues: report.results.map { ($0.point.id.rawValue, $0.outcome) })
    }

    /// A sibling package is part of what every mutant is built and tested
    /// against. An unchanged tree reuses the per-test coverage and every
    /// verdict; an edit to `../Logging` alone, with the project untouched,
    /// has to measure coverage again and evaluate every mutant afresh,
    /// whether the earlier verdicts sit in the checkpoint or in the result
    /// cache.
    @Test("An edit to a sibling package re-measures coverage and misses the result cache and checkpoint")
    func siblingEditInvalidatesReusedWork() throws {
        let (staged, core) = try Self.stageCore(configuration: Self.configuration(selectCoveringTests: true))
        defer { try? FileManager.default.removeItem(at: staged) }
        // Only Core is a repository: the run fingerprints the project through
        // git, and the siblings outside any repository through their files.
        try Data(".build/\n.mutantkit/\n".utf8).write(to: core.appendingPathComponent(".gitignore"))
        for arguments in [
            ["init"], ["config", "user.email", "tests@mutantkit.local"], ["config", "user.name", "MutantKit Tests"],
            ["add", "."], ["commit", "-m", "baseline"]
        ] {
            try GitFixture.run(arguments, in: core)
        }

        let first = try Self.planAndRun(in: core)
        let firstReport = try #require(first.report, "no report was written: \(first.run.output)")
        #expect(first.run.exitCode == 0, "\(first.run.output)")
        #expect(!firstReport.results.isEmpty)
        #expect(Self.origins(firstReport) == [.fresh])
        #expect(first.run.output.contains("coverage cache: miss"), "\(first.run.output)")

        // Control: with nothing changed, the result cache serves every
        // verdict and the coverage measurement is reused.
        let runDirectory = core.appendingPathComponent(".mutantkit")
        let setAside = staged.appendingPathComponent("checkpoints-set-aside")
        #expect(try Self.moveCheckpoints(from: runDirectory, to: setAside) > 0)
        let unchanged = try Self.runPlanned(in: core)
        let unchangedReport = try #require(unchanged.report, "no report was written: \(unchanged.run.output)")
        #expect(unchanged.run.exitCode == 0, "\(unchanged.run.output)")
        #expect(Self.origins(unchangedReport) == [.crossRunCache], "\(unchangedReport.results.map(\.origin))")
        #expect(unchanged.run.output.contains("coverage cache: hit"), "\(unchanged.run.output)")

        // The first run's checkpoint goes back, so the next run has both a
        // checkpoint and the result cache to reuse from. The edit leaves
        // Core's sources, tests and manifest untouched.
        try Self.moveCheckpoints(from: setAside, to: runDirectory)
        let trace = staged.appendingPathComponent("Logging/Sources/Logging/Trace.swift")
        let edited = try String(contentsOf: trace, encoding: .utf8) + "\n// Edited after the first run.\n"
        try Data(edited.utf8).write(to: trace, options: .atomic)

        let afterEdit = try Self.runPlanned(in: core)
        let afterEditReport = try #require(afterEdit.report, "no report was written: \(afterEdit.run.output)")
        #expect(afterEdit.run.exitCode == 0, "\(afterEdit.run.output)")
        #expect(Self.origins(afterEditReport) == [.fresh], "\(afterEditReport.results.map(\.origin))")
        #expect(afterEdit.run.output.contains("coverage cache: miss"), "\(afterEdit.run.output)")
        #expect(!afterEdit.run.output.contains("Resuming:"), "\(afterEdit.run.output)")
        #expect(Self.verdicts(afterEditReport) == Self.verdicts(firstReport))
    }

    // MARK: - Refused layouts

    /// Adds one more local dependency to `Core` (unused by its targets, so the
    /// manifest stays valid whatever it names), runs `dry-run`, and returns
    /// what it said. A refusal comes before any build, so these are quick.
    private static func dryRunRefusal(
        dependency: String, prepare: (URL) throws -> Void = { _ in }
    ) throws -> (exitCode: Int32, output: String) {
        let (staged, core) = try stageCore()
        defer { try? FileManager.default.removeItem(at: staged) }
        try prepare(staged)
        let manifest = core.appendingPathComponent("Package.swift")
        let text = try String(contentsOf: manifest, encoding: .utf8)
            .replacingOccurrences(
                of: #".package(path: "../SwiftMapper")"#,
                with: #".package(path: "../SwiftMapper"), .package(path: "\#(dependency)")"#
            )
        try Data(text.utf8).write(to: manifest, options: .atomic)
        return try Acceptance.run(["dry-run"], in: core)
    }

    @Test("A dependency that contains the project is refused with the reason")
    func parentPackageIsRefused() throws {
        let refusal = try Self.dryRunRefusal(dependency: "..") { staged in
            try Data("// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: \"Parent\")\n".utf8)
                .write(to: staged.appendingPathComponent("Package.swift"))
        }

        #expect(refusal.exitCode != 0, "\(refusal.output)")
        #expect(refusal.output.contains("parent directory of the project"), "\(refusal.output)")
    }

    @Test("A dependency with no Package.swift is refused naming the manifest that declared it")
    func missingPackageIsRefused() throws {
        let refusal = try Self.dryRunRefusal(dependency: "../Missing")

        #expect(refusal.exitCode != 0, "\(refusal.output)")
        #expect(refusal.output.contains("no Package.swift"), "\(refusal.output)")
    }

    @Test("A dependency reached through a symbolic link is refused")
    func symlinkedPackageIsRefused() throws {
        let refusal = try Self.dryRunRefusal(dependency: "../Linked") { staged in
            try FileManager.default.createSymbolicLink(
                atPath: staged.appendingPathComponent("Linked").path, withDestinationPath: "SwiftMapper"
            )
        }

        #expect(refusal.exitCode != 0, "\(refusal.output)")
        #expect(refusal.output.contains("symbolic link"), "\(refusal.output)")
    }

    /// An absolute path still names the original tree from inside a sandbox, so
    /// the build would read (and mutations would never reach) the wrong copy.
    @Test("An absolute dependency path outside the project is refused before anything is built")
    func absolutePathIsRefused() throws {
        let staged = try Acceptance.stageFixture("LocalPathDependencies")
        defer { try? FileManager.default.removeItem(at: staged) }
        let core = staged.appendingPathComponent("Core")
        let absolute = try #require(CanonicalPath.resolve(staged.appendingPathComponent("SwiftMapper").path))
        let manifest = core.appendingPathComponent("Package.swift")
        let text = try String(contentsOf: manifest, encoding: .utf8)
            .replacingOccurrences(of: #".package(path: "../SwiftMapper")"#, with: #".package(path: "\#(absolute)")"#)
        try Data(text.utf8).write(to: manifest, options: .atomic)
        try Data(Self.configuration().utf8).write(to: core.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let dryRun = try Acceptance.run(["dry-run"], in: core)

        #expect(dryRun.exitCode != 0, "\(dryRun.output)")
        #expect(dryRun.output.contains("sandbox cannot be built in"), "\(dryRun.output)")
    }
}
