import Darwin
import Foundation
import MutationModel
import Testing

/// The interrupt-and-resume flow against the real binary: SIGINT once -> a
/// partial report, a resume command and exit 7; the same command again ->
/// the run completes; SIGINT twice -> the running mutant is discarded.
///
/// Signals go to the spawned CLI child only, never to the test process.
@Suite("Acceptance: graceful stop and resume", .enabled(if: Acceptance.isEnabled), .serialized)
struct RunGracefulStopAcceptanceTests {
    private static let interruptedExit: Int32 = 7

    /// One worker, so "the first mutant finished" is a clean moment to stop.
    private static let configuration = """
    version: 1
    project:
      kind: swiftPackageMacOS
    sources:
      include: [Sources/**]
    operators:
      profile: default
    execution:
      strategy: isolated
      workers: 1
      confirmTimedOutMutants: false
    timeouts:
      mutant:
        strategy: fixed
        maximum: 20s
      terminationGracePeriod: 2
    reports: [console, json]
    """

    private let runArguments = ["run", "--plan", "plan.json", "--report", "json"]

    private func stage(_ fixture: String) throws -> URL {
        let directory = try Acceptance.stageFixture(fixture)
        try Data(Self.configuration.utf8).write(to: directory.appendingPathComponent("mutantkit.yml"), options: .atomic)
        // Resume needs a git repository to prove the project is unchanged
        // since the checkpoint; run artifacts are ignored so they never count
        // as a change.
        try Data(".build/\n.mutantkit/\nplan.json\ninterrupted-run.log\n".utf8)
            .write(to: directory.appendingPathComponent(".gitignore"), options: .atomic)
        for arguments in [
            ["init", "-q"], ["add", "-A"],
            ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "fixture"]
        ] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = arguments
            git.currentDirectoryURL = directory
            git.standardOutput = FileHandle.nullDevice
            git.standardError = FileHandle.nullDevice
            try git.run()
            BoundedProcessWait.wait(git, timeoutSeconds: 60)
            guard git.terminationStatus == 0 else {
                throw AcceptanceError.commandFailed(command: "git \(arguments.joined(separator: " "))", exitCode: git.terminationStatus, output: "")
            }
        }
        let plan = try Acceptance.run(["plan", "--output", "plan.json"], in: directory)
        guard plan.exitCode == 0 else {
            throw AcceptanceError.commandFailed(command: "plan", exitCode: plan.exitCode, output: plan.output)
        }
        return directory
    }

    private func checkpointLines(in directory: URL) -> Int {
        let root = directory.appendingPathComponent(".mutantkit")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("checkpoint-") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.split(separator: "\n").count }
            .reduce(0, +)
    }

    /// Starts `run`, waits until at least one mutant is checkpointed, sends
    /// `signals` SIGINTs to the child (spaced out), and returns how it ended.
    private func runAndInterrupt(in directory: URL, signals: Int) throws -> (exitCode: Int32, output: String) {
        let output = directory.appendingPathComponent("interrupted-run.log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = try Acceptance.binary()
        process.arguments = runArguments
        process.currentDirectoryURL = directory
        process.standardOutput = handle
        process.standardError = handle
        try process.run()

        let deadline = Date().addingTimeInterval(240)
        while process.isRunning, checkpointLines(in: directory) < 1, Date() < deadline { usleep(100_000) }
        guard process.isRunning else {
            throw AcceptanceError.commandFailed(
                command: "run (finished before it could be interrupted)", exitCode: process.terminationStatus,
                output: (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            )
        }
        for index in 0 ..< signals {
            if index > 0 { usleep(500_000) }
            kill(process.processIdentifier, SIGINT)
        }
        // A bounded wait that SIGKILLs the child (not us) if it never exits.
        BoundedProcessWait.wait(process, timeoutSeconds: 120)
        return (process.terminationStatus, (try? String(contentsOf: output, encoding: .utf8)) ?? "")
    }

    private func loadReport(in directory: URL) throws -> RunReport {
        let data = try Data(contentsOf: directory.appendingPathComponent(".mutantkit/report.json"))
        return try MutationPlan.decoder().decode(RunReport.self, from: data)
    }

    private func expectPartial(_ report: RunReport) throws -> RunInterruption {
        let interruption = try #require(report.interruption)
        #expect(interruption.signal == "SIGINT")
        #expect(interruption.completedMutants >= 1)
        #expect(interruption.completedMutants < interruption.plannedMutants)
        #expect(report.score == nil, "a partial report must not carry a score")
        // Exactly one collapsed violation, never one per unfinished mutant.
        let missing = report.integrity.violations.filter { $0.kind == .plannedMutationWithoutResult }
        #expect(missing.count == 1)
        let unfinished = interruption.plannedMutants - interruption.completedMutants
        #expect(missing.first?.detail.contains("\(unfinished) of \(interruption.plannedMutants) planned mutants did not run") == true)
        #expect(missing.first?.unfinishedMutationIDs?.count == unfinished)
        return interruption
    }

    @Test("One SIGINT writes a partial report and exits 7; resuming completes the run")
    func singleSignalThenResume() throws {
        let directory = try stage("SwiftPackageMacOS")
        defer { try? FileManager.default.removeItem(at: directory) }

        let interrupted = try runAndInterrupt(in: directory, signals: 1)
        #expect(interrupted.exitCode == Self.interruptedExit, "\(interrupted.output)")
        #expect(interrupted.output.contains("Resume with: "), "\(interrupted.output)")
        let interruption = try expectPartial(try loadReport(in: directory))

        let resumed = try Acceptance.run(runArguments, in: directory)
        #expect(resumed.exitCode == 0, "\(resumed.output)")
        let final = try loadReport(in: directory)
        #expect(final.interruption == nil)
        #expect(final.integrity.violations.isEmpty, "\(final.integrity.violations)")
        #expect(final.score != nil)
        #expect(final.results.count == interruption.plannedMutants)
    }

    @Test("A second SIGINT discards the running mutant but still exits 7 with a partial report")
    func doubleSignalDiscardsRunningMutant() throws {
        let directory = try stage("HangingMutant")
        defer { try? FileManager.default.removeItem(at: directory) }

        let interrupted = try runAndInterrupt(in: directory, signals: 2)
        #expect(interrupted.exitCode == Self.interruptedExit, "\(interrupted.output)")
        _ = try expectPartial(try loadReport(in: directory))
    }
}
