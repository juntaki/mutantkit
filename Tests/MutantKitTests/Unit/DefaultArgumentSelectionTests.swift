import Foundation
import MutationExecution
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// A literal default argument has no coverage region, so nothing attributes a test to it. Narrowing it
/// to the tests that ran the owning function is only sound if the owner is found exactly and every
/// other unmeasured line keeps running everything.
@Suite("Default argument test selection")
struct DefaultArgumentSelectionTests {
    private static let source = """
    struct Q {
        func run(
            flag: Bool = false,
            other: Int = 1
        ) {
            print(flag)
        }

        var enabled = true

        func plain() {
            let local = false
            print(local)
        }
    }
    """

    private static let path = "Sources/Q.swift"

    private static func point(containing original: String) throws -> MutationPoint {
        let points = try discover(source, path: path, using: Operators.boolLiteral)
        return try #require(points.first { $0.originalText == original && $0.line == line(of: original) })
    }

    private static func line(of text: String) -> Int {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        return (lines.firstIndex { $0.contains(text) } ?? 0) + 1
    }

    private func map(owner covered: [Int: [String]], mapped: Set<Int>, unattributed: Set<String> = []) -> PerTestCoverageMap {
        let id = { (name: String) in TestIdentifier(target: "T", qualifiedName: name) }
        var covering: [Int: Set<TestIdentifier>] = [:]
        for (line, names) in covered { covering[line] = Set(names.map(id)) }
        return PerTestCoverageMap(
            coveringTests: [Self.path: covering], source: "test", unattributedTests: Set(unattributed.map(id)),
            mappedLines: [Self.path: mapped]
        )
    }

    @Test("The owner of a default argument is the whole function")
    func ownerRange() throws {
        let point = try Self.point(containing: "false")
        let range = DefaultArgumentOwner.lineRange(in: Data(Self.source.utf8), containing: point.utf8Range)
        #expect(range == 2 ... 7)
    }

    @Test("A literal outside a parameter default has no owner")
    func localLiteralHasNoOwner() throws {
        let points = try discover(Self.source, path: Self.path, using: Operators.boolLiteral)
        let local = try #require(points.first { $0.line == Self.line(of: "let local = false") })
        #expect(DefaultArgumentOwner.lineRange(in: Data(Self.source.utf8), containing: local.utf8Range) == nil)
        let stored = try #require(points.first { $0.line == Self.line(of: "var enabled = true") })
        #expect(DefaultArgumentOwner.lineRange(in: Data(Self.source.utf8), containing: stored.utf8Range) == nil)
    }

    @Test("An unmeasured default argument runs the tests that ran its function")
    func narrowsToOwner() throws {
        let point = try Self.point(containing: "false")
        let coverage = map(owner: [6: ["a", "b"], 12: ["c"]], mapped: [6, 12])

        let selected = coverage.selection(for: point, originalSource: Data(Self.source.utf8))

        #expect(selected == [TestIdentifier(target: "T", qualifiedName: "a"), TestIdentifier(target: "T", qualifiedName: "b")])
    }

    @Test("Unattributed tests are kept in the narrowed selection")
    func keepsUnattributed() throws {
        let point = try Self.point(containing: "false")
        let coverage = map(owner: [6: ["a"]], mapped: [6], unattributed: ["u"])

        let selected = coverage.selection(for: point, originalSource: Data(Self.source.utf8))

        #expect(selected?.contains(TestIdentifier(target: "T", qualifiedName: "u")) == true)
    }

    @Test("No test ran the owner means run everything")
    func ownerNeverRunFallsBackToEverything() throws {
        let point = try Self.point(containing: "false")
        let coverage = map(owner: [12: ["c"]], mapped: [6, 12])

        #expect(coverage.selection(for: point, originalSource: Data(Self.source.utf8)) == nil)
    }

    @Test("A measured line keeps its own attribution")
    func measuredLineIsUnchanged() throws {
        let point = try Self.point(containing: "false")
        let coverage = map(owner: [point.line: ["only"], 6: ["a", "b"]], mapped: [point.line, 6])

        let selected = coverage.selection(for: point, originalSource: Data(Self.source.utf8))
        #expect(selected == [TestIdentifier(target: "T", qualifiedName: "only")])
    }

    @Test("An unmeasured line that is not a default argument still runs everything")
    func otherUnmeasuredLineRunsEverything() throws {
        let points = try discover(Self.source, path: Self.path, using: Operators.boolLiteral)
        let stored = try #require(points.first { $0.line == Self.line(of: "var enabled = true") })
        let coverage = map(owner: [6: ["a"]], mapped: [6])

        #expect(coverage.selection(for: stored, originalSource: Data(Self.source.utf8)) == nil)
    }

    @Test("Without the original source nothing is narrowed")
    func noSourceRunsEverything() throws {
        let point = try Self.point(containing: "false")
        let coverage = map(owner: [6: ["a"]], mapped: [6])

        #expect(coverage.selection(for: point, originalSource: nil) == nil)
    }
}
