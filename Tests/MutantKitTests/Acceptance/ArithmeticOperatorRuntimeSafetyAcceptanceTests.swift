import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Turns
/// `ArithmeticOperatorReplacementOperator`'s own doc comment claim — "2
/// genuine, reproducible hangs remain... clustered in loop/index-arithmetic
/// code, consistent with... an arithmetic swap turning a terminating
/// computation into one that hangs" — into a real, reproducible fixture,
/// not left as prose alone. The original corpus sites are in a private
/// external project, not available here — this is a minimal, self-contained
/// reproduction of the same *class* of hang: a `*` mutated to `/` inside a
/// loop's own increment expression, where integer division floors a
/// positive step down to `0`, turning a terminating loop into an infinite
/// one (the loop's own guard condition never becomes false, since the
/// index that condition reads never changes again).
///
/// Off by default like every other acceptance suite (a real, executed
/// subprocess per case, not just a `swiftc -typecheck`):
/// `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: arithmetic-operator-replacement runtime safety", .enabled(if: Acceptance.isEnabled))
struct ArithmeticOperatorRuntimeSafetyAcceptanceTests {
    /// Compiles `source` to a real executable and runs it, bounded by
    /// `timeoutSeconds` — `true` if it exited on its own within that
    /// bound, `false` if it had to be killed for still running (the
    /// signature of a genuine hang, not a slow-but-terminating
    /// computation: `timeoutSeconds` is chosen generously relative to how
    /// fast the *original*, unmutated program actually finishes below).
    private func terminatesWithinTimeout(_ source: String, timeoutSeconds: Double) throws -> Bool {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("arith-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let sourceFile = workDir.appendingPathComponent("main.swift")
        try Data(source.utf8).write(to: sourceFile)
        let binary = workDir.appendingPathComponent("main")

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", "-O", sourceFile.path, "-o", binary.path]
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

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while run.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if run.isRunning {
            run.terminate()
            run.waitUntilExit()
            return false
        }
        return true
    }

    @Test("A * mutated to / inside a loop's own increment can turn a positive step into 0, hanging forever")
    func multiplyToDivideStepMutantHangs() throws {
        // `2 * stepScale` -> `2 / stepScale`: for `stepScale >= 3`, integer
        // division floors to 0, so `index` never advances past its start —
        // `index < limit` never becomes false, forever. The *original*
        // program (step = 2 * 3 = 6) reaches `limit` and terminates near-
        // instantly; the mutant has no exit at all, relying entirely on
        // `terminatesWithinTimeout`'s own external `Process.terminate()`
        // to end it, never a safety valve inside the fixture itself (a
        // break-after-N-iterations valve would let the mutant "terminate"
        // too, just slower — defeating the point of this fixture).
        let source = """
        func countUp(from start: Int, limit: Int, stepScale: Int) -> Int {
            var index = start
            var iterations = 0
            while index < limit {
                index += 2 * stepScale
                iterations += 1
            }
            return iterations
        }

        print(countUp(from: 0, limit: 1_000_000_000, stepScale: 3))
        """
        let original = try mutatedSource(source, from: nil)
        #expect(try terminatesWithinTimeout(original, timeoutSeconds: 5), "the original, unmutated program must terminate quickly")

        let mutated = try mutatedSource(source, from: "swift.core.arithmetic-operator-replacement")
        let terminated = try terminatesWithinTimeout(mutated, timeoutSeconds: 2)
        #expect(
            !terminated,
            """
            stepScale >= 3 floors `2 / stepScale` to 0 via integer division — index never advances, \
            so this must NOT terminate within the bound
            """
        )
    }

    /// `operatorID: nil` returns `source` unmodified — the original,
    /// unmutated program, used as this fixture's own negative control (it
    /// must terminate quickly, proving the *mutation*, not the fixture's
    /// own loop-with-a-break-safety-valve, is what hangs).
    private func mutatedSource(_ source: String, from operatorID: String?) throws -> String {
        guard let operatorID else { return source }
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected the one * site in the loop's own increment expression")
        let point = try #require(points.first)
        return try String(decoding: MutationApplication.apply(point, to: Data(source.utf8)).mutatedSource, as: UTF8.self)
    }
}
