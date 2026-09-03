import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Turns an earlier semantic-quality sample's own else-clause-deletion
/// finding (12 of 19 real candidates from swift-argument-parser flagged
/// "suspicious" for a definite-assignment/initializer-completeness risk) into
/// real, reproducible fixtures — and confirms the real-world rate empirically:
/// a full build-viability sweep of all 19 sample candidates against the same
/// corpus found 10 of 19 (52.6%) actually `unviable`, not merely "suspicious".
///
/// `ElseClauseDeletionOperator`'s own `isSafePosition` guard covers a
/// different hazard entirely (the deleted `else` being the block's own
/// implicit-return/missing-return value at the *last* statement of a
/// non-`Void` function) — it has no guard at all for a `let`/`var` binding,
/// or a `self`-stored-property/`self.init` delegation, that only becomes
/// definitely-initialized because *both* the `if` and `else` branches assign
/// it. This is a distinct compile-unsound class this operator's own doc
/// comment does not yet name.
///
/// Both fixture classes below reproduce a real compile failure that
/// `swiftc -typecheck` alone does **not** catch (definite-assignment/
/// initializer-completeness diagnostics run during SIL emission, a later
/// compiler stage) — matching the same gap already documented for the
/// "missing return" hazard `isSafePosition` guards against. A full compile
/// (`swiftc -o <binary>`) is required, not `-typecheck`.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: else-clause-deletion compile correctness", .enabled(if: Acceptance.isEnabled))
struct ElseClauseDeletionCompileCorrectnessAcceptanceTests {
    private func compiles(_ source: String) throws -> Bool {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("else-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let sourceFile = workDir.appendingPathComponent("main.swift")
        try Data(source.utf8).write(to: sourceFile)
        let binary = workDir.appendingPathComponent("main")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", sourceFile.path, "-o", binary.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func mutatedSource(_ source: String) throws -> String {
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: "swift.core.else-clause-deletion")
        let point = try #require(points.first, "expected at least one mutation candidate")
        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        return String(decoding: applied.mutatedSource, as: UTF8.self)
    }

    @Test("Deleting an else clause that is the only other path to a definite-assignment let fails to compile")
    func definiteAssignmentLetMutantFailsToCompile() throws {
        let source = """
        func classify(_ condition: Bool) -> Int {
            let value: Int
            if condition {
                value = 1
            } else {
                value = 2
            }
            return value
        }
        """
        #expect(try compiles(source), "the original source itself must compile")

        let mutated = try mutatedSource(source)
        #expect(
            try !compiles(mutated),
            """
            with the else branch gone, `value` is only assigned on the true path — \
            the false path falls through with `value` never initialized
            """
        )
    }

    @Test("Deleting an else clause that is the only other path to a stored property's initialization fails to compile")
    func initializerStoredPropertyMutantFailsToCompile() throws {
        // The `if`/`else` is deliberately not the init's last statement:
        // `isSafePosition` already, correctly, excludes a last-statement
        // candidate inside an `init` (a different, already-guarded hazard —
        // see the type's own doc comment). This fixture isolates the
        // *unguarded* hazard: a non-last `if`/`else` that is still the only
        // path initializing a stored property.
        let source = """
        struct S {
            let value: Int

            init(_ condition: Bool) {
                if condition {
                    value = 1
                } else {
                    value = 2
                }
                print("initialized")
            }
        }
        """
        #expect(try compiles(source), "the original source itself must compile")

        let mutated = try mutatedSource(source)
        #expect(
            try !compiles(mutated),
            """
            with the else branch gone, `self.value` is only initialized on the true path — \
            a struct init must initialize every stored property on every path
            """
        )
    }

    @Test("A var already initialized at its declaration is unaffected by else deletion")
    func varWithDefaultInitializerMutantStillCompiles() throws {
        let source = """
        func classify(_ condition: Bool) -> String {
            var label: String = "default"
            if condition {
                label = "matched"
            } else {
                label = "unmatched"
            }
            return label
        }
        """
        #expect(try compiles(source), "the original source itself must compile")

        let mutated = try mutatedSource(source)
        #expect(
            try compiles(mutated),
            """
            `label` already has an initial value from its own declaration — \
            losing the else branch just leaves it at that default, no definite-assignment risk
            """
        )
    }
}
