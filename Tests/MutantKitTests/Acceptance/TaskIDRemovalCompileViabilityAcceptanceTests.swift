import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Empirical proof, via a real `swiftc` compile against real `import
/// SwiftUI` source (not only a fake minimal stand-in method named `task`),
/// that `TaskIDRemovalOperator`'s mutation compiles for every shape its own
/// matcher accepts. Per the task contract, SwiftSyntax correctness alone is
/// insufficient for a SwiftUI-shaped operator — this suite exercises the
/// real `View.task(id:priority:_:)` overloads on the current Apple SDK.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: task-id-removal compile viability", .enabled(if: Acceptance.isEnabled))
struct TaskIDRemovalCompileViabilityAcceptanceTests {
    private let operatorID = "apple.swiftui.task-id-removal"

    /// A full compile, not `-typecheck` — matches every other acceptance
    /// suite in this catalog.
    private func compiles(_ source: String) throws -> (succeeded: Bool, output: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-id-removal-compile-viability-\(UUID().uuidString).swift")
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

    private static let preamble = "import SwiftUI\n\n"

    private static func isTaskCandidate(_ text: String) -> Bool { text.contains(".task(") }

    @Test("Removing id: from a real SwiftUI .task(id:) still type-checks")
    func plainTaskIDRemovalTypeChecks() throws {
        let source = Self.preamble + """
        struct Item: Identifiable {
            let id: Int
        }

        struct ItemView: View {
            let item: Item
            var body: some View {
                Text("hi")
                    .task(id: item.id) {
                        await reload()
                    }
            }
            func reload() async {}
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isTaskCandidate)
        #expect(!mutated.contains(".task(id:") && !mutated.contains(", id:"), "the id: argument must be gone from the .task call")
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing id: from .task(id:priority:) keeps priority: and still type-checks")
    func taskIDWithPriorityRemovalTypeChecks() throws {
        let source = Self.preamble + """
        struct Item: Identifiable {
            let id: Int
        }

        struct ItemView: View {
            let item: Item
            var body: some View {
                Text("hi")
                    .task(id: item.id, priority: .userInitiated) {
                        await reload()
                    }
            }
            func reload() async {}
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isTaskCandidate)
        #expect(!mutated.contains(".task(id:") && !mutated.contains(", id:"), "the id: argument must be gone from the .task call")
        #expect(mutated.contains("priority: .userInitiated"), "the priority: argument must be preserved")
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing id: from a multiline id: expression still type-checks")
    func multilineIDExpressionRemovalTypeChecks() throws {
        // Mirrors zubair-io/Maple PR #3018's own shape.
        let source = Self.preamble + """
        struct Tiers {
            var ordered: [(Int, URL)] = []
        }

        final class Controller: ObservableObject {
            func start(tiers: Tiers) async {}
        }

        struct RemoteImageView: View {
            let tiers: Tiers
            @StateObject var controller = Controller()
            var body: some View {
                Color.clear
                    .task(
                        id: tiers.ordered.map(\\.1)
                    ) {
                        await controller.start(tiers: tiers)
                    }
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isTaskCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing id: from a .task(id:) nested in a modifier chain still type-checks")
    func nestedModifierChainRemovalTypeChecks() throws {
        let source = Self.preamble + """
        struct Model: Identifiable {
            let id: Int
        }

        struct RowView: View {
            let model: Model
            var body: some View {
                Text("row")
                    .padding()
                    .background(Color.white)
                    .task(id: model.id) {
                        await reload()
                    }
                    .accessibilityLabel("row")
            }
            func reload() async {}
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isTaskCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A plain .task { } with no arguments is never proposed as a candidate at all")
    func plainTaskIsNeverACandidate() throws {
        let source = Self.preamble + """
        struct ItemView: View {
            var body: some View {
                Text("hi")
                    .task {
                        await reload()
                    }
            }
            func reload() async {}
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty, "a bare .task { } has no id: argument to remove")
    }
}
