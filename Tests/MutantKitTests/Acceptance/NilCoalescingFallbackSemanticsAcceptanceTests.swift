import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Empirical proof of `NilCoalescingFallbackOperator`'s actual semantics —
/// see its doc comment: the mutant (`a ?? b` → `b`) is indistinguishable
/// from the original exactly when the left-hand side is `nil`, and can only
/// possibly be caught when the left-hand side is non-nil. A test suite that
/// only exercises the `nil` case does not kill this mutant; one that
/// exercises a non-nil, fallback-distinguishing value does. Confirmed by
/// actually compiling and running both the original and the mutated
/// program, not merely asserted in prose.
///
/// Off by default like every other acceptance suite (real `swiftc`
/// compilation and execution per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: nil-coalescing fallback semantics", .enabled(if: Acceptance.isEnabled))
struct NilCoalescingFallbackSemanticsAcceptanceTests {
    /// Compiles and runs `source` (expected to `print` exactly one line) and
    /// returns what it printed.
    private func runAndCapture(_ source: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nil-coalescing-semantics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceFile = directory.appendingPathComponent("main.swift")
        try Data(source.utf8).write(to: sourceFile)
        let binary = directory.appendingPathComponent("program")

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", sourceFile.path, "-o", binary.path]
        compile.standardOutput = Pipe()
        compile.standardError = Pipe()
        try compile.run()
        compile.waitUntilExit()
        #expect(compile.terminationStatus == 0, "fixture must compile cleanly")

        let run = Process()
        run.executableURL = binary
        let stdout = Pipe()
        run.standardOutput = stdout
        try run.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        run.waitUntilExit()

        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mutatedSource(_ source: String) throws -> String {
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: "swift.core.nil-coalescing-fallback"
        )
        let point = try #require(points.first, "expected exactly one ?? site")
        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        return String(decoding: applied.mutatedSource, as: UTF8.self)
    }

    @Test("A suite exercising only the nil case cannot distinguish the mutant from the original")
    func nilOnlyCaseSurvives() throws {
        let source = """
        let value: Int? = nil
        print(value ?? -1)
        """

        let originalOutput = try runAndCapture(source)
        let mutatedOutput = try runAndCapture(try mutatedSource(source))

        #expect(originalOutput == mutatedOutput, "when the left-hand side is nil, original and mutant must agree")
        #expect(originalOutput == "-1")
    }

    @Test("A suite exercising the non-nil case, with a value distinguishable from the fallback, kills the mutant")
    func nonNilCaseIsKilled() throws {
        let source = """
        let value: Int? = 7
        print(value ?? -1)
        """

        let originalOutput = try runAndCapture(source)
        let mutatedOutput = try runAndCapture(try mutatedSource(source))

        #expect(originalOutput == "7")
        #expect(mutatedOutput == "-1")
        #expect(originalOutput != mutatedOutput, "a non-nil left-hand value distinguishable from the fallback must catch this mutant")
    }
}
