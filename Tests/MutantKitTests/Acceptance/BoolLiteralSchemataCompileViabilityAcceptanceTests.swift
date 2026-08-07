import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Empirical proof that `BoolLiteralSchemataLowerer`'s ternary-selector
/// embedding type-checks at every site the isolated operator itself already
/// discovers a boolean literal at — including the hard positions ADR-0003
/// calls out as the ones a naive lowering can silently break (argument
/// position, return position, a closure body, an `async` function, an
/// actor-isolated context, a global initializer, a hot loop). A real
/// `swiftc -typecheck` invocation per case, not merely asserted in prose —
/// same discipline as `CoreOperatorCompileViabilityAcceptanceTests`.
///
/// This tests `lower(_:sources:)` directly, bypassing `analyze` — proving
/// the *shape* the lowering produces always compiles, independent of
/// whether `analyze` would actually choose to embed a given site.
///
/// A real, C-backed `__mutantkitIsActive` now exists
/// (`MutantKitSchemataRuntimeC`) — see `SchemataSwiftPMRuntimeAcceptanceTests`
/// for the end-to-end proof that links and runs it for real. This suite
/// stays deliberately narrower and faster: the lowered file's own
/// `@_silgen_name`-declared preamble (see `BoolLiteralSchemataLowerer
/// .runtimePreamble`) is *already* a self-contained declaration — no
/// import, no module, no linking required for `-typecheck` to accept it —
/// so these cases run the real lowered output verbatim, proving type-
/// checking alone at every hard site without paying a full-package-build
/// cost per case.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: bool-literal schemata compile viability", .enabled(if: Acceptance.isEnabled))
struct BoolLiteralSchemataCompileViabilityAcceptanceTests {
    private func typeChecks(_ source: String) throws -> Bool {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("schemata-compile-viability-\(UUID().uuidString).swift")
        try Data(source.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-typecheck", file.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func lowered(_ source: String) throws -> String {
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: BoolLiteralInversionOperator.descriptor.id
        )
        let point = try #require(points.first, "expected at least one bool-literal candidate")
        let chunk = SchemataChunk(
            chunkID: "acceptance", points: [point], projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)]
        )
        let file = try #require(program.loweredSources.first { $0.relativePath == "Sample.swift" })
        // With a single-file chunk, `lower(_:sources:)` prepends the
        // runtime declaration directly into that file's own content — see
        // `BoolLiteralSchemataLowerer.runtimePreamble`'s doc comment.
        return file.contents
    }

    private func expectLoweredCompiles(_ source: String) throws {
        let original = try typeChecks(source)
        #expect(original, "the original fixture itself must compile")

        let mutatedSource = try lowered(source)
        let mutated = try typeChecks(mutatedSource)
        #expect(mutated, "the schemata-lowered form should compile identically to the original: \(mutatedSource)")
    }

    @Test("A boolean literal in argument position compiles once lowered")
    func argumentPosition() throws {
        try expectLoweredCompiles("""
        func gate(_ enabled: Bool) -> Int { enabled ? 1 : 0 }
        func call() -> Int { gate(true) }
        """)
    }

    @Test("A boolean literal in return position compiles once lowered")
    func returnPosition() throws {
        try expectLoweredCompiles("""
        func flag() -> Bool {
            return true
        }
        """)
    }

    @Test("A boolean literal in a closure body compiles once lowered")
    func closureBody() throws {
        try expectLoweredCompiles("""
        let predicate: () -> Bool = {
            true
        }
        """)
    }

    @Test("A boolean literal in an async function compiles once lowered")
    func asyncFunction() throws {
        try expectLoweredCompiles("""
        func check() async -> Bool {
            true
        }
        """)
    }

    @Test("A boolean literal in an actor-isolated context compiles once lowered")
    func actorIsolatedContext() throws {
        try expectLoweredCompiles("""
        actor Counter {
            func isReady() -> Bool {
                true
            }
        }
        """)
    }

    @Test("A boolean literal in a global initializer compiles once lowered")
    func globalInitializer() throws {
        try expectLoweredCompiles("""
        let featureEnabled = true
        """)
    }

    @Test("A boolean literal in a hot loop compiles once lowered")
    func hotLoop() throws {
        try expectLoweredCompiles("""
        func spin() -> Int {
            var count = 0
            for _ in 0 ..< 1000 {
                if true {
                    count += 1
                }
            }
            return count
        }
        """)
    }
}
