import Foundation
import MutationModel
import Testing

/// Pins `SchemataPlan.decodeAndValidate`'s `executionContext` parameter:
/// closes the gap self-consistency-only validation leaves open — a plan
/// whose recorded fields are internally consistent but no longer describe
/// the *current* execution environment (schema version, backend, toolchain,
/// build arguments) must still be rejected. Split into its own file rather
/// than folded into `SchemataPlanTests` to keep that file under SwiftLint's
/// `type_body_length` cap; reuses `SchemataPlanTests`'s own fixture helpers
/// rather than duplicating them.
@Suite("Schemata plan contract: execution context")
struct SchemataPlanExecutionContextTests {
    private static let matchingExecutionContext = SchemataPlan.SchemataExecutionContext(
        schemaVersion: SchemaVersion.schemataPlan, backendID: "swiftpm-process-executor", backendVersion: 1,
        toolchainHash: "sha256:toolchain", buildArgumentsHash: "sha256:args"
    )

    @Test("decodeAndValidate accepts a plan whose recorded fields match the current execution context")
    func decodeAndValidateAcceptsMatchingExecutionContext() throws {
        let mutationPlan = SchemataPlanTests.mutationPlan(ids: ["mut_a"])
        let original = SchemataPlanTests.plan(mutationPlan: mutationPlan, entries: [SchemataPlanTests.entry(id: "mut_a")])
        let data = try JSONEncoder().encode(original)

        let validated = try SchemataPlan.decodeAndValidate(data, against: mutationPlan, executionContext: Self.matchingExecutionContext)
        #expect(validated.schemataPlanID == original.schemataPlanID)
    }

    @Test("decodeAndValidate rejects a plan built under a different schemaVersion than the current execution context")
    func decodeAndValidateRejectsWrongSchemaVersion() throws {
        let mutationPlan = SchemataPlanTests.mutationPlan(ids: ["mut_a"])
        let original = SchemataPlanTests.plan(mutationPlan: mutationPlan, entries: [SchemataPlanTests.entry(id: "mut_a")])
        let data = try JSONEncoder().encode(original)
        let context = SchemataPlan.SchemataExecutionContext(
            schemaVersion: SchemaVersion.schemataPlan + 1, backendID: "swiftpm-process-executor", backendVersion: 1,
            toolchainHash: "sha256:toolchain", buildArgumentsHash: "sha256:args"
        )

        #expect(throws: SchemataPlan.ValidationError.schemaVersionMismatch(
            expected: SchemaVersion.schemataPlan + 1, found: SchemaVersion.schemataPlan
        )) {
            _ = try SchemataPlan.decodeAndValidate(data, against: mutationPlan, executionContext: context)
        }
    }

    @Test("decodeAndValidate rejects a plan built for a different backend than the current execution context")
    func decodeAndValidateRejectsWrongBackendID() throws {
        let mutationPlan = SchemataPlanTests.mutationPlan(ids: ["mut_a"])
        let original = SchemataPlanTests.plan(mutationPlan: mutationPlan, entries: [SchemataPlanTests.entry(id: "mut_a")])
        let data = try JSONEncoder().encode(original)
        let context = SchemataPlan.SchemataExecutionContext(
            schemaVersion: SchemaVersion.schemataPlan, backendID: "xcodebuild-executor", backendVersion: 1,
            toolchainHash: "sha256:toolchain", buildArgumentsHash: "sha256:args"
        )

        #expect(throws: SchemataPlan.ValidationError.backendIDMismatch(
            expected: "xcodebuild-executor", found: "swiftpm-process-executor"
        )) {
            _ = try SchemataPlan.decodeAndValidate(data, against: mutationPlan, executionContext: context)
        }
    }

    @Test("decodeAndValidate rejects a plan built under a different toolchain than the current execution context")
    func decodeAndValidateRejectsWrongToolchain() throws {
        let mutationPlan = SchemataPlanTests.mutationPlan(ids: ["mut_a"])
        let original = SchemataPlanTests.plan(mutationPlan: mutationPlan, entries: [SchemataPlanTests.entry(id: "mut_a")])
        let data = try JSONEncoder().encode(original)
        let context = SchemataPlan.SchemataExecutionContext(
            schemaVersion: SchemaVersion.schemataPlan, backendID: "swiftpm-process-executor", backendVersion: 1,
            toolchainHash: "sha256:toolchain-newer", buildArgumentsHash: "sha256:args"
        )

        #expect(throws: SchemataPlan.ValidationError.toolchainMismatch(
            expected: "sha256:toolchain-newer", found: "sha256:toolchain"
        )) {
            _ = try SchemataPlan.decodeAndValidate(data, against: mutationPlan, executionContext: context)
        }
    }

    @Test("decodeAndValidate ignores the execution context entirely when none is supplied, unchanged from before")
    func decodeAndValidateWithNoExecutionContextIsUnaffected() throws {
        // A plan whose recorded fields would fail every executionContext
        // check imaginable still validates fine when the parameter is
        // simply omitted — the pre-existing, context-free behavior this
        // feature must not silently change for callers that don't opt in.
        let mutationPlan = SchemataPlanTests.mutationPlan(ids: ["mut_a"])
        let original = SchemataPlan(
            mutationPlan: mutationPlan, backendID: "some-future-backend", backendVersion: 99,
            toolchainHash: "sha256:anything", buildArgumentsHash: "sha256:anything",
            entries: [SchemataPlanTests.entry(id: "mut_a")]
        )
        let data = try JSONEncoder().encode(original)

        let validated = try SchemataPlan.decodeAndValidate(data, against: mutationPlan)
        #expect(validated.schemataPlanID == original.schemataPlanID)
    }
}
