import Foundation
import MutationModel
import Testing

/// A mutant that never terminates, and what the tool does about it.
///
/// Two separate guarantees are checked here, and neither had ever been exercised
/// against a real hang:
///
/// 1. **The run ends.** The tool owns the timeout, because `swift test` and
///    `xcodebuild` cannot be relied on to bound their own runtime.
/// 2. **Nothing survives it.** The child is spawned as a process-group leader
///    specifically so the whole subtree can be killed. `Foundation.Process` puts
///    the child in *our* group, where `kill(-pgid)` would kill the tool itself —
///    which is why this path is raw `posix_spawn`. If the escalation is wrong, the
///    orphans are compilers, test runners and simulators, and they accumulate
///    across a run until the machine dies.
///
/// The second is the one that looks correct by inspection and can only be settled
/// by trying it.
@Suite("Acceptance: a hanging mutant is killed and leaves nothing behind",
       .enabled(if: Acceptance.isEnabled))
struct ProcessSupervisionAcceptanceTests {
    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "HangingMutant")
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    /// Any process still holding the fixture's path in its command line is one we
    /// started and failed to reclaim. The sandbox directory is gone by now, but a
    /// surviving process still carries the path in its `argv`, which is exactly
    /// what makes it findable.
    private func survivingProcesses(referencing path: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            // pgrep matches its own invocation, which is not an orphan.
            .filter { !$0.contains("pgrep") }
    }

    @Test("The hanging mutant is bounded and reported as timed out")
    func hangingMutantTimesOut() throws {
        let run = try self.run()

        // `settle(ready:)` has two independent hanging mutants once
        // unary-not-removal is in the default profile alongside
        // bool-literal-inversion: `true -> false` on the default argument and
        // `!ready -> ready` both leave `ready` permanently true with no
        // reassignment in the loop, so both hang the same way. Both must be
        // bounded and reported as timed out, not just the first discovered.
        let hanging = run.report.results.filter { $0.point.enclosingDeclaration.path.last == "settle(ready:)" }
        #expect(!hanging.isEmpty, "the fixture should contain mutations that hang")
        #expect(hanging.allSatisfy { $0.outcome == .timedOut }, "\(hanging.map { ($0.point.operatorID, $0.outcome) })")
    }

    /// The guarantee: `kill(-pgid)` reaches the whole subtree, not just the
    /// process we launched.
    @Test("No descendant survives the timeout")
    func timeoutLeavesNoOrphans() throws {
        let run = try self.run()

        let survivors = survivingProcesses(referencing: run.directory.path)
        #expect(survivors.isEmpty, "orphaned after the run:\n\(survivors.joined(separator: "\n"))")
    }

    /// A hang must not take the run down with it. The other mutants still have to
    /// be built, run and classified.
    @Test("The run survives the hang and still classifies everything else")
    func theRestOfTheRunIsUnaffected() throws {
        let run = try self.run()

        #expect(run.report.baseline.passed)
        #expect(run.report.integrity.violations.isEmpty, "\(run.report.integrity.violations.map(\.detail))")
        #expect(run.report.integrity.classified == run.report.integrity.planned)

        #expect(run.killed == [
            .init(declaration: "isPositive(_:)", original: ">", replacement: ">="),
            .init(declaration: "isPositive(_:)", original: ">", replacement: "<=")
        ])
    }

    /// A timeout is a fact about the tool run, not about the test suite: the suite
    /// neither caught the mutant nor failed to. Scoring it either way would be a
    /// claim we cannot support, so it is counted and excluded from both
    /// denominators.
    @Test("A timeout is excluded from the score, and counted")
    func timeoutIsExcludedFromTheScore() throws {
        let run = try self.run()

        let score = try #require(run.report.score)
        // Two independent hangs now that unary-not-removal is in the default
        // profile alongside bool-literal-inversion — see
        // `hangingMutantTimesOut`'s doc comment for why both hang.
        #expect(score.excluded["timedOut"] == 2)
        // 2 killed, 0 survived, and the hangs in neither denominator.
        #expect(score.killed == 2)
        #expect(score.survived == 0)
        #expect(score.tested == 1.0)
    }
}
