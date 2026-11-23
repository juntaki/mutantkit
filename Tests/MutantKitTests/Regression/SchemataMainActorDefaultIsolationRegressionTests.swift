import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Regression: **a target with main-actor default isolation never ran in
/// schemata mode.**
///
/// The failure being reproduced: in a SwiftPM target declaring
/// `swiftSettings: [.defaultIsolation(MainActor.self)]` (Swift 6.2+), every
/// schemata chunk failed to build with "main actor-isolated default value in
/// a nonisolated(unsafe) context", reported at the generated
/// `__mutantkitUnitDescriptor_…` declaration, and every mutant in the target
/// fell back to isolated mode. The verdicts stayed correct, so nothing in a
/// passing run pointed at the cause — only the fallback count did.
///
/// The cause: `BoolLiteralSchemataLowerer.sharedDeclarationPreamble`
/// declared `__mutantkitRegisterUnitV3` and `__mutantkitIsActiveV3` as plain
/// top-level functions. Prepended into the target's own sources, they took
/// that target's default isolation and became main-actor isolated, so
/// neither the descriptor's `nonisolated(unsafe)` initializer nor a mutated
/// call site in a `nonisolated` function could call them.
///
/// The check below type-checks the lowerer's *real* output with `swiftc`
/// under `-default-isolation MainActor`, rather than only matching the
/// preamble's text, so the fix is proven against the compiler that rejected
/// it — the same reason the `*DifferentialTests` suites compile the lowered
/// source instead of reading it.
@Suite("Regression: lowered schemata sources compile under main-actor default isolation")
struct SchemataMainActorDefaultIsolationRegressionTests {
    /// One literal in code that takes the target's default (main-actor)
    /// isolation, one in a `nonisolated` function: the descriptor
    /// initializer is the first failure the bug produced, a mutated call site
    /// off the main actor is the second.
    private static let source = """
    public enum Gate {
        public static func isOpen() -> Bool { true }

        nonisolated public static func isLocked() -> Bool { false }
    }

    """

    @Test("Both runtime declarations in the shared preamble are explicitly nonisolated")
    func sharedPreambleDeclaresBothFunctionsNonisolated() {
        let preamble = BoolLiteralSchemataLowerer.sharedDeclarationPreamble
        #expect(preamble.contains("nonisolated func __mutantkitRegisterUnitV3("))
        #expect(preamble.contains("nonisolated func __mutantkitIsActiveV3("))
    }

    @Test("A lowered chunk type-checks with -default-isolation MainActor, in a nonisolated function too")
    func loweredChunkTypeChecksUnderMainActorDefaultIsolation() throws {
        let lowered = try loweredSource()
        let diagnostics = try typeCheck(lowered, extraArguments: ["-default-isolation", "MainActor"])
        #expect(diagnostics == nil, "\(diagnostics ?? "")")
    }

    /// The control: the same lowered source must still compile where default
    /// isolation is `nonisolated` — every target that has not opted in.
    @Test("The same lowered chunk still type-checks with the default (nonisolated) default isolation")
    func loweredChunkTypeChecksUnderNonisolatedDefaultIsolation() throws {
        let lowered = try loweredSource()
        let diagnostics = try typeCheck(lowered, extraArguments: [])
        #expect(diagnostics == nil, "\(diagnostics ?? "")")
    }

    private func loweredSource() throws -> String {
        let points = try CoreOperatorExpansionTestSupport.discover(
            Self.source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: "Gate.swift"
        )
        try #require(points.count == 2, "expected one candidate per function, got \(points.count)")
        let chunk = SchemataChunk(
            chunkID: "chunk-1", points: points, projectIdentity: "Package.swift", target: "Gate", module: "Gate", product: "Gate"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: "Gate.swift", contents: Self.source)]
        )
        let lowered = try #require(program.loweredSources.first { $0.relativePath == "Gate.swift" })
        return lowered.contents
    }

    /// Returns `nil` when `swiftc -typecheck` accepts `contents` in Swift 6
    /// language mode, or the compiler's diagnostics when it does not.
    /// `-typecheck` stops before code generation, so the runtime symbols
    /// the preamble names never need to be linked.
    private func typeCheck(_ contents: String, extraArguments: [String]) throws -> String? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-main-actor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Gate.swift")
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        compile.arguments = ["swiftc", "-typecheck", "-parse-as-library", "-swift-version", "6", "-module-name", "Gate"]
            + extraArguments + [file.path]
        let errors = Pipe()
        compile.standardError = errors
        compile.standardOutput = Pipe()
        try compile.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        compile.waitUntilExit()
        return compile.terminationStatus == 0 ? nil : String(decoding: errorData, as: UTF8.self)
    }
}
