@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel
import Testing

/// The log added on 2026-09-19 to answer a question three CI failures could
/// not: `xcodebuild -list -json` has been killed at its 120-second budget at
/// 120.056s, 120.119s and 120.164s, which says the budget touches the edge of
/// the current distribution and nothing about where the edge is. Only the
/// failures were ever recorded; the successes — the half that would say what
/// a correct budget is — were not.
///
/// So these tests pin two things: that a run with the log switched off writes
/// nothing at all (the default, and the only acceptable cost for an
/// observation), and that a run with it on records *one row per attempt made*,
/// successes included. A log that recorded only failures would reproduce the
/// exact gap it was written to close.
@Suite("Scheme-discovery observation log")
struct SchemeDiscoveryObservationLogTests {
    private func adapter(
        logPath: String?, processRunner: @escaping ProcessRunner
    ) -> XcodeBuildAdapter {
        let root = FileManager.default.temporaryDirectory
        var adapter = XcodeBuildAdapter(
            configuration: Configuration(),
            kind: .xcodeProject,
            projectFile: nil,
            projectRoot: root,
            resolvedDestination: nil,
            simulators: SimulatorPool(workingDirectory: root),
            processRunner: processRunner
        )
        adapter.schemeDiscoveryLogPath = logPath
        return adapter
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-discovery-\(UUID().uuidString).jsonl").path
    }

    private func listing(_ schemes: [String]) -> ProcessResult {
        ProcessResult(
            exitCode: 0,
            standardOutput: Data("{\"project\":{\"name\":\"Demo\",\"schemes\":\(schemes)}}".utf8),
            standardError: Data(),
            durationSeconds: 3.25, timedOut: false, terminatingSignal: nil, outputComplete: true
        )
    }

    /// The exact shape observed on `juntaki/mutantkit` PR #66 attempts 1 and
    /// 2 (`f198959`): killed at the deadline, nothing written.
    private var timedOut: ProcessResult {
        ProcessResult(
            exitCode: 143, standardOutput: Data(), standardError: Data(),
            durationSeconds: 120.119, timedOut: true, terminatingSignal: 15, outputComplete: false
        )
    }

    private func rows(at path: String) throws -> [[String: Any]] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(object as? [String: Any])
        }
    }

    @Test("With no log path, a discovery run writes nothing -- the default costs nothing")
    func writesNothingWhenDisabled() async throws {
        let path = temporaryPath()
        let runner: ProcessRunner = { _, _, _, _ in self.listing(["Demo"]) }

        let schemes = await adapter(logPath: nil, processRunner: runner)
            .discoverSchemes(in: FileManager.default.temporaryDirectory)

        #expect(schemes == ["Demo"])
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("An empty log path is treated as off, not as a path to the current directory")
    func treatsEmptyPathAsDisabled() async {
        let runner: ProcessRunner = { _, _, _, _ in self.listing(["Demo"]) }

        let schemes = await adapter(logPath: "", processRunner: runner)
            .discoverSchemes(in: FileManager.default.temporaryDirectory)

        #expect(schemes == ["Demo"])
    }

    @Test("A successful discovery is recorded, with its duration -- not only failures")
    func recordsSuccessfulAttempts() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let runner: ProcessRunner = { _, _, _, _ in self.listing(["Demo", "DemoTests"]) }

        _ = await adapter(logPath: path, processRunner: runner)
            .discoverSchemes(in: FileManager.default.temporaryDirectory)

        let rows = try rows(at: path)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["outcome"] as? String == "schemes-found")
        #expect(row["durationSeconds"] as? Double == 3.25)
        #expect(row["schemeCount"] as? Int == 2)
        #expect(row["budgetSeconds"] as? Double == 120)
        #expect(row["timedOut"] as? Bool == false)
        #expect(row["attempt"] as? Int == 0)
    }

    @Test("A run killed at the budget records the duration and the budget it was held to")
    func recordsTimeoutAgainstItsBudget() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let runner: ProcessRunner = { _, _, _, _ in self.timedOut }

        _ = await adapter(logPath: path, processRunner: runner)
            .discoverSchemes(in: FileManager.default.temporaryDirectory)

        let row = try #require(rows(at: path).first)
        #expect(row["outcome"] as? String == "did-not-succeed")
        #expect(row["durationSeconds"] as? Double == 120.119)
        #expect(row["budgetSeconds"] as? Double == 120)
        #expect(row["exitCode"] as? Int == 143)
        #expect(row["timedOut"] as? Bool == true)
        #expect(row["terminatingSignal"] as? Int == 15)
        #expect(row["outputComplete"] as? Bool == false)
    }

    /// The retry loop is the case a per-call log gets wrong most easily:
    /// recording only the attempt that decided the outcome would undercount
    /// every `xcodebuild` invocation that actually ran and actually took
    /// time, which is exactly the quantity being measured.
    @Test("Every attempt in a retried discovery gets its own row, not just the last")
    func recordsOneRowPerAttempt() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let runner: ProcessRunner = { _, _, _, _ in self.listing([]) }

        _ = await adapter(logPath: path, processRunner: runner)
            .discoverSchemes(in: FileManager.default.temporaryDirectory)

        let rows = try rows(at: path)
        #expect(rows.count == 3)
        #expect(rows.map { $0["attempt"] as? Int } == [0, 1, 2])
        #expect(rows.map { $0["outcome"] as? String }
            == ["empty-retrying", "empty-retrying", "answered-none"])
    }

    @Test("Output the supervisor never confirmed complete is recorded as that, not as 'none'")
    func distinguishesIncompleteOutputFromAnsweredNone() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let incomplete = ProcessResult(
            exitCode: 0, standardOutput: Data(), standardError: Data(),
            durationSeconds: 1.5, timedOut: false, terminatingSignal: nil, outputComplete: false
        )
        let runner: ProcessRunner = { _, _, _, _ in incomplete }

        _ = await adapter(logPath: path, processRunner: runner)
            .discoverSchemes(in: FileManager.default.temporaryDirectory)

        let rows = try rows(at: path)
        #expect(rows.count == 1)
        #expect(rows.first?["outcome"] as? String == "output-incomplete")
    }

    /// Several workers discover schemes at once, in separate processes,
    /// against one file. Rows must accumulate; a writer that truncates or
    /// seeks-then-writes loses the rows that make the distribution.
    @Test("Rows from separate discoveries accumulate in one file rather than replacing it")
    func appendsRatherThanTruncates() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let runner: ProcessRunner = { _, _, _, _ in self.listing(["Demo"]) }

        for _ in 0 ..< 3 {
            _ = await adapter(logPath: path, processRunner: runner)
                .discoverSchemes(in: FileManager.default.temporaryDirectory)
        }

        #expect(try rows(at: path).count == 3)
    }

    @Test("A row is one line of parseable JSON, so a whole file is readable line by line")
    func rowIsSingleLineJSON() throws {
        let line = SchemeDiscoveryObservationLog.line(
            attempt: 0, outcome: .schemesFound, result: listing(["Demo"]),
            schemeCount: 1, budgetSeconds: 120
        )

        #expect(line.hasSuffix("\n"))
        #expect(!line.dropLast().contains("\n"))
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        #expect((object as? [String: Any])?["outcome"] as? String == "schemes-found")
    }

    @Test("A row for a process that never started carries no invented timing")
    func omitsTimingWhenNothingRan() throws {
        let line = SchemeDiscoveryObservationLog.line(
            attempt: 0, outcome: .notStarted, result: nil, schemeCount: 0, budgetSeconds: 120
        )

        let row = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(row["outcome"] as? String == "not-started")
        #expect(row["durationSeconds"] == nil)
        #expect(row["exitCode"] == nil)
    }
}
