import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// Empirical proof of the compile-viability gap
/// `ArithmeticOperatorReplacementOperator`/`AssignmentOperatorReplacementOperator`'s
/// doc comments describe: real Swift code where the original compiles but the
/// mutated form does not, confirmed by actually invoking the Swift compiler
/// (`swiftc -typecheck`) — not merely asserted in prose. This is exactly why
/// both operators ship `defaultEnabled: false`: neither operator has symbol
/// resolution, so neither can tell these cases apart from the ones where the
/// replacement genuinely does compile.
///
/// Off by default like every other acceptance suite (a real `swiftc`
/// invocation per case): `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: core operator compile viability", .enabled(if: Acceptance.isEnabled))
struct CoreOperatorCompileViabilityAcceptanceTests {
    private func typeChecks(_ source: String) throws -> Bool {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("compile-viability-\(UUID().uuidString).swift")
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

    private func mutatedSource(_ source: String, operatorID: String) throws -> String {
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        let point = try #require(points.first, "expected at least one mutation candidate")
        let applied = try MutationApplication.apply(point, to: Data(source.utf8))
        return String(decoding: applied.mutatedSource, as: UTF8.self)
    }

    @Test("A generic Numeric-constrained * mutates to a / that does not compile")
    func genericNumericMultiplyMutantFailsToCompile() throws {
        let source = """
        func multiply<T: Numeric>(_ lhs: T, _ rhs: T) -> T {
            lhs * rhs
        }
        """
        let original = try typeChecks(source)
        #expect(original, "the original source itself must compile")

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.arithmetic-operator-replacement"))
        #expect(!mutated, "Numeric does not guarantee `/`, so this mutant should fail to type-check")
    }

    @Test("String's + mutates to a - that does not compile")
    func stringConcatenationMutantFailsToCompile() throws {
        let source = """
        func join(_ lhs: String, _ rhs: String) -> String {
            lhs + rhs
        }
        """
        let original = try typeChecks(source)
        #expect(original)

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.arithmetic-operator-replacement"))
        #expect(!mutated, "String has no `-`, so this mutant should fail to type-check")
    }

    @Test("Array's + mutates to a - that does not compile")
    func arrayConcatenationMutantFailsToCompile() throws {
        let source = """
        func combine(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
            lhs + rhs
        }
        """
        let original = try typeChecks(source)
        #expect(original)

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.arithmetic-operator-replacement"))
        #expect(!mutated, "Array has no `-`, so this mutant should fail to type-check")
    }

    @Test("String's += mutates to a -= that does not compile")
    func stringCompoundAssignmentMutantFailsToCompile() throws {
        let source = """
        func append(_ value: inout String) {
            value += "a"
        }
        """
        let original = try typeChecks(source)
        #expect(original)

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.assignment-operator-replacement"))
        #expect(!mutated, "String has no `-=`, so this mutant should fail to type-check")
    }

    @Test("A custom type overloading only one side of + / - mutates to a call that does not compile")
    func customTypeWithOnlyOneSidedOperatorMutantFailsToCompile() throws {
        // Deliberately only one `+` site in the whole fixture: the operator
        // body itself must not contain a second, unrelated `+` (say, over
        // its own `Int` fields) or discovery — which has no way to prefer
        // one candidate over another — could pick that one instead, and an
        // `Int` mutating to `-` compiles just fine, silently defeating the
        // point of this fixture.
        let source = """
        struct Vector {
            var x: Int

            static func + (lhs: Vector, rhs: Vector) -> Vector {
                Vector(x: lhs.x)
            }
        }

        func combine(_ a: Vector, _ b: Vector) -> Vector {
            a + b
        }
        """
        let original = try typeChecks(source)
        #expect(original)

        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: "swift.core.arithmetic-operator-replacement"
        )
        #expect(points.count == 1, "expected exactly the one `+` site in `combine`")

        let mutated = try typeChecks(try mutatedSource(source, operatorID: "swift.core.arithmetic-operator-replacement"))
        #expect(!mutated, "Vector overloads + but not -, so this mutant should fail to type-check")
    }
}
