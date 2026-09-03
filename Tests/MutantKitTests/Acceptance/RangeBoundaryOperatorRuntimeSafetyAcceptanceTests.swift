import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Turns `RangeBoundaryReplacementOperator`'s own doc comment claim
/// — "`..<` -> `...` *adds* the upper bound... `array[0..<array.count]`...
/// including `array.count` is an out-of-bounds index, a genuine runtime
/// crash" — into a real, reproducible fixture, not left as prose alone.
///
/// Off by default like every other acceptance suite (a real, executed
/// subprocess): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: range-boundary-replacement runtime safety", .enabled(if: Acceptance.isEnabled))
struct RangeBoundaryOperatorRuntimeSafetyAcceptanceTests {
    /// Compiles `source` to a real executable and runs it — `true` if it
    /// exited with status 0, `false` if it crashed (a Swift array
    /// out-of-bounds access traps, terminating with a non-zero/signal
    /// status, not a thrown Swift error).
    private func runsToSuccess(_ source: String) throws -> Bool {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("range-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let sourceFile = workDir.appendingPathComponent("main.swift")
        try Data(source.utf8).write(to: sourceFile)
        let binary = workDir.appendingPathComponent("main")

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", sourceFile.path, "-o", binary.path]
        compile.standardOutput = Pipe()
        compile.standardError = Pipe()
        try compile.run()
        compile.waitUntilExit()
        #expect(compile.terminationStatus == 0, "fixture itself must compile cleanly")

        let run = Process()
        run.executableURL = binary
        run.standardOutput = Pipe()
        run.standardError = Pipe()
        try run.run()
        run.waitUntilExit()
        return run.terminationStatus == 0
    }

    @Test("array[0..<array.count] mutated to array[0...array.count] crashes with an out-of-bounds trap")
    func openRangeToClosedRangeMutantCrashes() throws {
        let source = """
        let values = [1, 2, 3]
        var total = 0
        for i in values[0..<values.count] {
            total += i
        }
        print(total)
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: "swift.core.range-boundary-replacement")
        #expect(points.count == 1, "expected the one ..< site")
        let point = try #require(points.first)

        #expect(try runsToSuccess(source), "the original, unmutated program must run cleanly")

        let mutatedSource = try MutationApplication.apply(point, to: Data(source.utf8)).mutatedSource
        let mutated = String(decoding: mutatedSource, as: UTF8.self)
        #expect(
            try !runsToSuccess(mutated),
            "values[0...values.count] indexes one past the array's own bounds — this must crash, not run to a clean exit"
        )
    }
}
