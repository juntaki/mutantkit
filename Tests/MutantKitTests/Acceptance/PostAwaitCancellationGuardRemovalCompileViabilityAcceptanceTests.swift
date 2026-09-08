import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Empirical proof, via a real `swiftc` compile, of the structural safety
/// claim `PostAwaitCancellationGuardRemovalOperator`'s own doc comment
/// makes: removing its narrowly-matched guard never needs the extra
/// syntax-shape exclusions `ContinuationResumeRemovalOperator` and
/// `RequiredDecodeIntroductionOperator` require, because the guard's own
/// preceding-item constraint already rules out an emptied block, an
/// implicit-single-expression-return closure, or a generic-inference
/// hazard. Five representative enclosing shapes are checked directly, not
/// assumed from syntax alone.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: post-await-cancellation-guard-removal compile viability", .enabled(if: Acceptance.isEnabled))
struct PostAwaitCancellationGuardRemovalCompileViabilityAcceptanceTests {
    private let operatorID = "apple.concurrency.post-await-cancellation-guard-removal"

    /// A full compile, not `-typecheck` -- same reasoning as the sibling
    /// acceptance suites: definite-initialization and missing-return
    /// diagnostics only surface at a later compiler phase.
    private func compiles(_ source: String) throws -> (succeeded: Bool, output: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-await-cancellation-guard-compile-viability-\(UUID().uuidString).swift")
        try Data(source.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-o", "/dev/null", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    private func mutatedSource(_ source: String, candidateMatching predicate: (String) -> Bool) throws -> String {
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(
            points.first { predicate($0.originalText) },
            "expected a matching mutation candidate among \(points.map(\.originalText))"
        )
        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        return String(decoding: applied.mutatedSource, as: UTF8.self)
    }

    private static let preamble = """
    import Foundation

    """

    private static func isGuardCandidate(_ text: String) -> Bool { text.contains("Task.isCancelled") }

    @Test("Removing the guard from a plain async function still type-checks")
    func plainAsyncFunctionRemovalTypeChecks() throws {
        let source = Self.preamble + """
        final class Box {
            var state: Int = 0
            func load() async -> Int { 42 }
            func run() async {
                let value = await load()
                guard !Task.isCancelled else { return }
                state = value
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isGuardCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing the guard from an async throws function (try await) still type-checks")
    func asyncThrowsFunctionRemovalTypeChecks() throws {
        let source = Self.preamble + """
        enum SomeError: Error { case failed }
        final class Box {
            var state: Int = 0
            func load() async throws -> Int { 42 }
            func run() async throws {
                let value = try await load()
                guard !Task.isCancelled else { return }
                state = value
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isGuardCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing the guard from inside a for loop body, after the loop's own await, still type-checks")
    func forLoopBodyRemovalTypeChecks() throws {
        // Mirrors zubair-io/Maple PR #3018's MuiRemoteImageController.start(tiers:).
        let source = Self.preamble + """
        final class Box {
            var count = 0
            func loader(_ x: Int) async throws -> Int { x }
            func run(_ xs: [Int]) async {
                for x in xs {
                    let loaded = try? await loader(x)
                    guard !Task.isCancelled else { return }
                    guard let loaded else { continue }
                    count += loaded
                }
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isGuardCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing the guard as the last statement of a switch case still type-checks")
    func switchCaseLastStatementRemovalTypeChecks() throws {
        let source = Self.preamble + """
        enum Action { case load, none }
        final class Box {
            var state: Int = 0
            func load() async -> Int { 1 }
            func run(_ action: Action) async {
                switch action {
                case .load:
                    let v = await load()
                    guard !Task.isCancelled else { return }
                    state = v
                case .none:
                    break
                }
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isGuardCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing the guard from inside a Task { } closure still type-checks")
    func taskClosureRemovalTypeChecks() throws {
        let source = Self.preamble + """
        final class Box {
            var state: Int = 0
            func load() async -> Int { 7 }
            func run() {
                Task {
                    let v = await self.load()
                    guard !Task.isCancelled else { return }
                    self.state = v
                }
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isGuardCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A guard with cleanup in its else body is never proposed as a candidate at all")
    func guardWithCleanupIsNeverACandidate() throws {
        let source = Self.preamble + """
        final class Box {
            var state: Int = 0
            func load() async -> Int { 1 }
            func cleanup() {}
            func run() async {
                let value = await load()
                guard !Task.isCancelled else {
                    cleanup()
                    return
                }
                state = value
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(
            !points.contains { $0.originalText.contains("Task.isCancelled") },
            "removing this guard would also delete cleanup(), a different, unrelated fault"
        )
    }
}
