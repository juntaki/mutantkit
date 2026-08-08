import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// Empirical proof that `RelationalOperatorReplacementSchemataLowerer`'s
/// embedding type-checks at every eligible operand shape it claims to
/// support — same `swiftc -typecheck` discipline as
/// `BoolLiteralSchemataCompileViabilityAcceptanceTests`.
///
/// The heterogeneous-integer and `Decimal`-contextual-literal fixtures here
/// pin the real compile failure found via ~100-mutation Expansion against
/// swift-numerics/swift-syntax: the old `__mkPair<T>` lowering forced both
/// operands into one shared generic type parameter, which does not compile
/// when the two operands are of different (but comparable) concrete types.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: relational-operator schemata compile viability", .enabled(if: Acceptance.isEnabled))
struct RORSchemataCompileViabilityAcceptanceTests {
    private func typeChecks(_ source: String) throws -> Bool {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("relational-schemata-compile-viability-\(UUID().uuidString).swift")
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

    private func lowered(_ source: String, replacement: String) throws -> String {
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: RelationalOperatorReplacementOperator.descriptor.id
        )
        let point = try #require(
            points.first { $0.replacementText == replacement }, "expected a relational candidate with replacementText \(replacement)"
        )
        let chunk = SchemataChunk(
            chunkID: "acceptance", points: [point], projectIdentity: "App.xcodeproj", target: "App", module: "App", product: "App.app"
        )
        let program = try RelationalOperatorReplacementSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: "Sample.swift", contents: source)]
        )
        let file = try #require(program.loweredSources.first { $0.relativePath == "Sample.swift" })
        return file.contents
    }

    private func expectLoweredCompiles(_ source: String, replacement: String) throws {
        let original = try typeChecks(source)
        #expect(original, "the original fixture itself must compile")

        let mutatedSource = try lowered(source, replacement: replacement)
        let mutated = try typeChecks(mutatedSource)
        #expect(mutated, "the schemata-lowered form should compile identically to the original: \(mutatedSource)")
    }

    @Test("Same-type Int operands compile once lowered")
    func sameTypeIntOperands() throws {
        try expectLoweredCompiles(
            "func f(a: Int, b: Int) -> Bool { a >= b }", replacement: ">"
        )
    }

    @Test("A Decimal operand compared against an untyped integer literal keeps its contextual typing once lowered")
    func decimalContextualLiteral() throws {
        try expectLoweredCompiles(
            """
            import Foundation
            func f(value: Decimal) -> Bool { value >= 10 }
            """, replacement: ">"
        )
    }

    @Test("Heterogeneous but individually-Comparable integer operands compile once lowered")
    func heterogeneousIntegerOperands() throws {
        // The real shape found during Expansion: `BinaryInteger` provides a
        // heterogeneous comparison operator (`static func >= <Other:
        // BinaryInteger>(Self, Other) -> Bool`) — `Int >= UInt32` compiles
        // directly with no shared type. The old `__mkPair<T>` lowering
        // forced both operands into one shared generic `T`, which does not
        // compile for this pair ("conflicting arguments to generic
        // parameter 'T' ('Int' vs. 'UInt32')") even though the original,
        // un-lowered expression does.
        try expectLoweredCompiles(
            """
            func f(a: Int, b: UInt32) -> Bool { a >= b }
            """, replacement: ">"
        )
    }

    @Test("A generic Comparable-constrained comparison compiles once lowered")
    func genericComparableOperands() throws {
        try expectLoweredCompiles(
            "func f<T: Comparable>(a: T, b: T) -> Bool { a >= b }", replacement: ">"
        )
    }

    @Test("A custom Comparable type's overloaded operators compile once lowered")
    func customComparableOperands() throws {
        try expectLoweredCompiles(
            """
            struct Meters: Comparable {
                let value: Double
                static func < (lhs: Meters, rhs: Meters) -> Bool { lhs.value < rhs.value }
            }
            func f(a: Meters, b: Meters) -> Bool { a >= b }
            """, replacement: ">"
        )
    }
}
