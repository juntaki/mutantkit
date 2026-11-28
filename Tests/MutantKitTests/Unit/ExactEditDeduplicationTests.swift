import Foundation
import MutationModel
import MutationPlanner
import Testing

/// One textual edit proposed by two operators must be planned, budgeted and
/// scored once, with the other operator kept as provenance on the skipped ledger.
@Suite("Exact-edit deduplication")
struct ExactEditDeduplicationTests {
    private let generic = "swift.core.side-effect-call-removal"
    private let specialized = "apple.concurrency.continuation-resume-removal"
    private let toolchain = ToolchainFingerprint(
        toolVersion: "0.1.0", toolCommitSHA: nil, swiftVersion: "6.3.3",
        swiftSyntaxVersion: "603.0.2", xcodeVersion: nil
    )
    private let source = """
    func complete(_ cont: CheckedContinuation<Void, Never>) {
        cont.resume()
        log()
    }
    """

    private func plan(enable: [String], maxMutants: Int? = nil) async throws -> MutationPlan {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-dedup-\(UUID().uuidString)")
        let file = root.appendingPathComponent("Sources/A.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(source.utf8).write(to: file)
        let configuration = Configuration(
            operators: OperatorSettings(profile: .conservative, enable: enable),
            execution: ExecutionSettings(budget: BudgetSettings(maxMutants: maxMutants, seed: 1))
        )
        return try await MutationPlanner().makePlan(
            configuration: configuration, projectRoot: root, toolchain: toolchain
        )
    }

    private func resumeEdits(_ plan: MutationPlan) -> [MutationPoint] {
        plan.mutations.filter { $0.originalText == "cont.resume()" }
    }

    @Test("both operators enabled: one point for the edit, specialized owns it, generic is skipped with provenance")
    func bothEnabled() async throws {
        let plan = try await plan(enable: [generic, specialized])
        #expect(resumeEdits(plan).map(\.operatorID) == [specialized])
        let dup = try #require(plan.skipped.first { $0.reason == .duplicateEdit })
        #expect(dup.operatorID == generic)
        #expect(dup.detail?.contains(specialized) == true && dup.detail?.contains(generic) == true)
        #expect(IntegrityChecker.validatePlan(plan).isEmpty)
    }

    @Test("IDs of each operator alone are unchanged by dedup")
    func idsStable() async throws {
        let both = try await plan(enable: [generic, specialized])
        let onlySpecialized = try await plan(enable: [specialized])
        let onlyGeneric = try await plan(enable: [generic])
        #expect(resumeEdits(onlySpecialized).map(\.id) == resumeEdits(both).map(\.id))
        #expect(onlySpecialized.skipped.allSatisfy { $0.reason != .duplicateEdit })
        #expect(onlyGeneric.skipped.allSatisfy { $0.reason != .duplicateEdit })
        #expect(resumeEdits(onlyGeneric).count == 1)
        let dup = try #require(both.skipped.first { $0.reason == .duplicateEdit })
        #expect(resumeEdits(onlyGeneric).map(\.id) == [dup.id])
    }

    @Test("the duplicate takes no budget slot")
    func budgetCountsOnce() async throws {
        // Distinct edits = each operator's own edits minus the one they share.
        let onlySpecialized = try await plan(enable: [specialized]).mutations.count
        let onlyGeneric = try await plan(enable: [generic]).mutations.count
        let eligible = onlySpecialized + onlyGeneric - 1
        let budgeted = try await plan(enable: [generic, specialized], maxMutants: eligible)
        #expect(budgeted.mutations.count == eligible)
        #expect(budgeted.skipped.filter { $0.reason == .budgetExceeded }.isEmpty)
    }
}
