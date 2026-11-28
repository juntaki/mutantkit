import Foundation
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Inline `mutantkit:disable` comments come from real line-comment trivia of the
/// one parse discovery already did, and are applied before the budget.
@Suite("Inline suppression directives")
struct InlineSuppressionDirectiveTests {
    private func scan(_ source: String) throws -> InlineSuppressionScan {
        try MutationDiscovery(operators: [])
            .analyze(source: Data(source.utf8), relativePath: "F.swift").suppressions
    }

    @Test("next-line / same-line / operator lists / multiple directives")
    func realLineComments() throws {
        let source = """
        // mutantkit:disable-next-line
        let a = 1 < 2
        let b = !true // mutantkit:disable-line swift.core.unary-not-removal
        //mutantkit:disable-next-line swift.core.a ,  swift.core.b
        let c = 3
        """
        let result = try scan(source)
        #expect(result.malformed.isEmpty)
        #expect(result.directives == [
            .init(targetLine: 2, operatorIDs: [], commentLine: 1),
            .init(targetLine: 3, operatorIDs: ["swift.core.unary-not-removal"], commentLine: 3),
            .init(targetLine: 5, operatorIDs: ["swift.core.a", "swift.core.b"], commentLine: 4)
        ])
    }

    @Test("string literals, raw and multiline strings, block and doc comments never suppress")
    func notRealLineComments() throws {
        let source = ##"""
        let s = "// mutantkit:disable-next-line"
        let r = #"// mutantkit:disable-line"#
        let m = """
        // mutantkit:disable-next-line
        """
        /* // mutantkit:disable-next-line */
        /// mutantkit:disable-next-line
        let x = 1
        """##
        let result = try scan(source)
        #expect(result.directives.isEmpty)
        #expect(result.malformed.isEmpty)
    }

    @Test("CRLF files: lines match the tree and the operator ID carries no CR")
    func crlf() throws {
        let source = "// mutantkit:disable-next-line swift.core.a\r\nlet x = 1\r\n"
        #expect(try scan(source).directives == [.init(targetLine: 2, operatorIDs: ["swift.core.a"], commentLine: 1)])
    }

    @Test("Unicode before the comment does not shift the line")
    func unicode() throws {
        let source = "let s = \"日本語🙂\"\n// mutantkit:disable-line\nlet y = 2 // 日本 mutantkit:disable-line"
        #expect(try scan(source).directives == [.init(targetLine: 2, operatorIDs: [], commentLine: 2)])
    }

    @Test("misspelled keywords and empty list elements are malformed, not silent no-ops")
    func malformed() throws {
        let source = """
        // mutantkit:disable-nextline
        // mutantkit:disable-line:swift.core.a
        // mutantkit:disable-next-line swift.core.a,
        // mutantkit:disable-line swift.core.a swift.core.b
        // mutantkit: some other note
        """
        let result = try scan(source)
        #expect(result.directives.isEmpty)
        #expect(result.malformed.map(\.commentLine) == [1, 2, 3, 4])
    }
}

@Suite("Planner inline suppression pipeline")
struct PlannerInlineSuppressionTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutantkit-inline-suppression-\(UUID().uuidString)")
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0", toolCommitSHA: nil, swiftVersion: "6.3.3", swiftSyntaxVersion: "603.0.2", xcodeVersion: nil
    )

    private func write(_ source: String) throws {
        let url = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(source.utf8).write(to: url)
    }

    private func plan(maxMutants: Int? = nil, external: [MutationSuppressionRule] = []) async throws -> MutationPlan {
        var configuration = Configuration()
        configuration.execution.budget.maxMutants = maxMutants
        return try await MutationPlanner().makePlan(
            configuration: configuration,
            projectRoot: root,
            toolchain: toolchain,
            inputs: PlanningExternalInputs(suppressions: MutationSuppressionSet(rules: external))
        )
    }

    private static let source = """
    func f(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Bool {
        // mutantkit:disable-next-line
        let x = a < b
        // mutantkit:disable-next-line
        let y = b < c
        let z = c < d
        let w = a < d
        return x && y && z && w
    }
    """

    @Test("suppressed mutants never take a budget slot: eligible alternatives fill it")
    func suppressionPrecedesBudget() async throws {
        try write(Self.source)
        defer { try? FileManager.default.removeItem(at: root) }
        let unbudgeted = try await plan()
        let suppressed = unbudgeted.skipped.filter { $0.reason == .userRequested }
        #expect(!suppressed.isEmpty)

        let budgeted = try await plan(maxMutants: 3)
        #expect(budgeted.mutations.count == 3)
        let suppressedIDs = Set(suppressed.map(\.id))
        #expect(budgeted.mutations.allSatisfy { !suppressedIDs.contains($0.id) })
        #expect(Set(budgeted.skipped.filter { $0.reason == .userRequested }.map(\.id)) == suppressedIDs)
    }

    @Test("a comment only inside a string literal suppresses nothing")
    func stringLiteralDoesNotSuppress() async throws {
        try write("""
        let s = "// mutantkit:disable-next-line"
        let t = 1 < 2
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await plan()
        #expect(result.skipped.filter { $0.reason == .userRequested }.isEmpty)
        #expect(!result.mutations.isEmpty)
    }

    @Test("inline and external rules combine; external is listed first")
    func inlinePlusExternal() async throws {
        try write(Self.source)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try await plan()
        let extra = try #require(base.mutations.first { $0.line == 6 })
        let combined = try await plan(external: [.fileLine(file: "Sources/A.swift", line: extra.line)])
        #expect(!combined.mutations.contains { $0.id == extra.id })
        #expect(combined.skipped.contains { $0.id == extra.id && $0.reason == .userRequested })
        #expect(combined.mutations.count < base.mutations.count)
    }

    @Test("unknown operator ID and malformed directive fail planning")
    func invalidDirectivesFail() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("// mutantkit:disable-next-line swift.core.nope\nlet a = 1 < 2")
        await #expect(throws: PlannerError.self) { _ = try await plan() }
        try write("// mutantkit:disable-nextline\nlet a = 1 < 2")
        await #expect(throws: PlannerError.self) { _ = try await plan() }
    }
}
