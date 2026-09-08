import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Empirical proof, via a real `swiftc` compile against real `import
/// SwiftUI` source (not only a fake minimal stand-in method named
/// `accessibilityLabel`), that `ExplicitLabelRemovalOperator`'s mutation
/// compiles for every shape its own matcher accepts. Per the task contract,
/// SwiftSyntax correctness alone is insufficient for a SwiftUI-shaped
/// operator — this suite exercises the real
/// `View.accessibilityLabel(_:)`/`(Text)` overloads on the current Apple
/// SDK, including the closure-return shape where deleting the whole
/// statement (rather than replacing it with its receiver) would be
/// compile-invalid.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: explicit-label-removal compile viability", .enabled(if: Acceptance.isEnabled))
struct ExplicitLabelRemovalCompileViabilityAcceptanceTests {
    private let operatorID = "apple.accessibility.explicit-label-removal"

    /// A full compile, not `-typecheck` — matches every other acceptance
    /// suite in this catalog.
    private func compiles(_ source: String) throws -> (succeeded: Bool, output: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("explicit-label-removal-compile-viability-\(UUID().uuidString).swift")
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

    private static func isLabelCandidate(_ text: String) -> Bool { text.contains(".accessibilityLabel(") }

    @Test("Removing .accessibilityLabel(\"...\") from a simple modifier chain still type-checks")
    func simpleModifierChainTypeChecks() throws {
        let source = Self.preamble + """
        struct CloseButton: View {
            var body: some View {
                Button("Close") {}
                    .accessibilityLabel("Close")
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isLabelCandidate)
        #expect(!mutated.contains("accessibilityLabel"), "the modifier call must be gone")
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing .accessibilityLabel(...) inside a some View body still type-checks")
    func someViewBodyTypeChecks() throws {
        let source = Self.preamble + """
        struct RowView: View {
            let title: String
            var body: some View {
                Text(title)
                    .padding()
                    .accessibilityLabel(title)
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isLabelCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Closure-return form: replacing with the receiver (not deleting the statement) still type-checks")
    func closureReturnFormTypeChecks() throws {
        let source = Self.preamble + """
        func applyIfLet<V: View>(_ label: String?, to view: V, _ transform: (V, String) -> some View) -> some View {
            if let label {
                return AnyView(transform(view, label))
            }
            return AnyView(view)
        }

        struct LabeledIcon: View {
            let label: String?
            var body: some View {
                applyIfLet(label, to: Image(systemName: "xmark")) { view, label in
                    view.accessibilityLabel(label)
                }
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isLabelCandidate)
        #expect(!mutated.contains("accessibilityLabel"))
        #expect(mutated.contains("view.accessibilityLabel(label)") == false)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A chained .accessibilityLabel(...) before and after other modifiers still type-checks")
    func chainedBeforeAndAfterOtherModifiersTypeChecks() throws {
        let source = Self.preamble + """
        struct RowView: View {
            let title: String
            var body: some View {
                Text(title)
                    .padding()
                    .background(Color.white)
                    .accessibilityLabel(title)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("row")
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isLabelCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Removing .accessibilityLabel(Text(...)) still type-checks")
    func textArgumentFormTypeChecks() throws {
        let source = Self.preamble + """
        struct CloseButton: View {
            var body: some View {
                Button("Close") {}
                    .accessibilityLabel(Text("Close"))
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isLabelCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }
}
