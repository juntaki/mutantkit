import Foundation
import MutationModel
import Testing

/// `SchemataPlanLoader` is ADR-0006's fix for `decodeAndValidate`'s
/// `executionContext: SchemataExecutionContext? = nil` shape: with an
/// optional parameter, a production execution path can call the weaker,
/// context-free overload just as easily as the real one, and nothing at
/// the type level says which callers must not.
/// `SchemataPlanLoader.validateForExecution` requires the context as a
/// non-optional parameter, and its return type (`ExecutableSchemataPlan`,
/// constructible only there) is what a real execution path should require
/// in its own signature instead of a bare `SchemataPlan`.
@Suite("Schemata plan loader: type-state boundary")
struct SchemataPlanLoaderTests {
    private static let context = SchemataPlan.SchemataExecutionContext(
        schemaVersion: SchemaVersion.schemataPlan, backendID: "swiftpm-process-executor", backendVersion: 1,
        toolchainHash: "sha256:toolchain", buildArgumentsHash: "sha256:args"
    )

    @Test("decodeForInspection decodes without running any self-consistency check")
    func decodeForInspectionSkipsValidation() throws {
        // A plan whose mutationPlanID does not match anything -- decodeForInspection
        // has no MutationPlan to check against, and must not pretend to have run
        // one anyway.
        let mutationPlan = SchemataPlanTests.mutationPlan(ids: ["mut_a"])
        let original = SchemataPlanTests.plan(mutationPlan: mutationPlan, entries: [SchemataPlanTests.entry(id: "mut_a")])
        let data = try JSONEncoder().encode(original)

        let unvalidated = try SchemataPlanLoader.decodeForInspection(data)
        // No public accessor exposes the decoded value directly -- reaching
        // validateForExecution successfully is this test's proof that
        // decodeForInspection actually decoded real data, not a stub.
        let executable = try SchemataPlanLoader.validateForExecution(unvalidated, against: mutationPlan, context: Self.context)
        #expect(executable.plan.schemataPlanID == original.schemataPlanID)
    }

    @Test("validateForExecution accepts a plan matching both its parent MutationPlan and the execution context")
    func validateForExecutionAcceptsMatchingPlan() throws {
        let mutationPlan = SchemataPlanTests.mutationPlan(ids: ["mut_a"])
        let original = SchemataPlanTests.plan(mutationPlan: mutationPlan, entries: [SchemataPlanTests.entry(id: "mut_a")])
        let data = try JSONEncoder().encode(original)
        let unvalidated = try SchemataPlanLoader.decodeForInspection(data)

        let executable = try SchemataPlanLoader.validateForExecution(unvalidated, against: mutationPlan, context: Self.context)

        #expect(executable.mutationPlan.planID == mutationPlan.planID)
        #expect(executable.executionContext.backendID == Self.context.backendID)
    }

    @Test("validateForExecution rejects a plan paired with the wrong MutationPlan")
    func validateForExecutionRejectsWrongMutationPlan() throws {
        let mutationPlan = SchemataPlanTests.mutationPlan(ids: ["mut_a"])
        let otherPlan = SchemataPlanTests.mutationPlan(ids: ["mut_b"])
        let original = SchemataPlanTests.plan(mutationPlan: mutationPlan, entries: [SchemataPlanTests.entry(id: "mut_a")])
        let data = try JSONEncoder().encode(original)
        let unvalidated = try SchemataPlanLoader.decodeForInspection(data)

        #expect(throws: SchemataPlan.ValidationError.self) {
            _ = try SchemataPlanLoader.validateForExecution(unvalidated, against: otherPlan, context: Self.context)
        }
    }

    @Test("validateForExecution rejects a plan built for a different execution context, even though it is self-consistent")
    func validateForExecutionRejectsWrongExecutionContext() throws {
        let mutationPlan = SchemataPlanTests.mutationPlan(ids: ["mut_a"])
        let original = SchemataPlanTests.plan(mutationPlan: mutationPlan, entries: [SchemataPlanTests.entry(id: "mut_a")])
        let data = try JSONEncoder().encode(original)
        let unvalidated = try SchemataPlanLoader.decodeForInspection(data)
        let wrongContext = SchemataPlan.SchemataExecutionContext(
            schemaVersion: Self.context.schemaVersion, backendID: "a-different-backend", backendVersion: 1,
            toolchainHash: Self.context.toolchainHash, buildArgumentsHash: Self.context.buildArgumentsHash
        )

        #expect(throws: SchemataPlan.ValidationError.self) {
            _ = try SchemataPlanLoader.validateForExecution(unvalidated, against: mutationPlan, context: wrongContext)
        }
    }

    @Test("decodeForInspection surfaces a decoding error for genuinely malformed JSON, not a silent empty plan")
    func decodeForInspectionSurfacesMalformedJSON() {
        #expect(throws: (any Error).self) {
            _ = try SchemataPlanLoader.decodeForInspection(Data("not json".utf8))
        }
    }
}
