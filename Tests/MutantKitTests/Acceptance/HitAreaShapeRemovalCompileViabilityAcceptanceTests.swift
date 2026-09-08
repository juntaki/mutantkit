import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Empirical proof, via a real `swiftc` compile against real `import
/// SwiftUI` source, that `HitAreaShapeRemovalOperator`'s mutation compiles
/// for every shape its own matcher accepts. Per the task contract,
/// SwiftSyntax correctness alone is insufficient for a SwiftUI-shaped
/// operator — this suite exercises the real `View.contentShape(_:)` overload
/// and real `Button` initializers on the current Apple SDK.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: hit-area-shape-removal compile viability", .enabled(if: Acceptance.isEnabled))
struct HitAreaShapeRemovalCompileViabilityAcceptanceTests {
    private let operatorID = "apple.swiftui.hit-area-shape-removal"

    /// A full compile, not `-typecheck` — matches every other acceptance
    /// suite in this catalog.
    private func compiles(_ source: String) throws -> (succeeded: Bool, output: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("hit-area-shape-removal-compile-viability-\(UUID().uuidString).swift")
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

    private static func isContentShapeCandidate(_ text: String) -> Bool { text.contains(".contentShape(") }

    @Test("Button label HStack+Spacer: removing .contentShape(Rectangle()) still type-checks")
    func buttonLabelHStackSpacerTypeChecks() throws {
        let source = Self.preamble + """
        struct RowView: View {
            let name: String
            let onSelect: () -> Void
            var body: some View {
                Button {
                    onSelect()
                } label: {
                    HStack {
                        Text(name)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isContentShapeCandidate)
        #expect(!mutated.contains("contentShape"), "the modifier call must be gone")
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Plain button style: removing .contentShape(Rectangle()) still type-checks")
    func plainButtonStyleTypeChecks() throws {
        let source = Self.preamble + """
        struct RowView: View {
            var body: some View {
                Button {
                    print("tap")
                } label: {
                    HStack {
                        Text("Item")
                        Spacer()
                        Text("$9.99")
                    }
                    .padding()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isContentShapeCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Modifier before AND after padding/frame in the chain still type-checks")
    func modifierBeforeAndAfterPaddingFrameTypeChecks() throws {
        let source = Self.preamble + """
        struct RowView: View {
            var body: some View {
                Button {
                    print("tap")
                } label: {
                    HStack {
                        Text("Item")
                        Spacer()
                    }
                    .padding()
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.1))
                }
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isContentShapeCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("Nested view-builder context (VStack wrapping the row inside the label) still type-checks")
    func nestedViewBuilderContextTypeChecks() throws {
        let source = Self.preamble + """
        struct RowView: View {
            var body: some View {
                Button {
                    print("tap")
                } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Item")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        Text("subtitle").font(.caption)
                    }
                }
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isContentShapeCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }

    @Test("A helper function returning some View still type-checks once mutated")
    func helperFunctionReturningSomeViewTypeChecks() throws {
        let source = Self.preamble + """
        struct RowView: View {
            let name: String

            func row() -> some View {
                Button {
                    print("tap")
                } label: {
                    HStack {
                        Text(name)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .contentShape(Rectangle())
                }
            }

            var body: some View {
                row()
            }
        }
        """
        #expect(try compiles(source).succeeded, "the original source itself must compile")

        let mutated = try mutatedSource(source, candidateMatching: Self.isContentShapeCandidate)
        let result = try compiles(mutated)
        #expect(result.succeeded, "\(result.output)")
    }
}
