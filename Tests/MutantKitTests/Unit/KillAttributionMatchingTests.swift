import Foundation
import MutationExecution
@testable import MutationModel
import Reporting
import Testing

/// Whether a failing test lies inside the run's selection is decided from the
/// full identifier. A failing test that cannot be matched unambiguously to the
/// selection is never inside it: the kill becomes an infrastructure failure
/// with the unmatched names recorded, never the reverse.
@Suite("Kill attribution: test identifier matching")
struct KillAttributionMatchingTests {
    private static let planID = "plan-A"
    private static let workUnitID = "unit-1"

    private func inside(_ failing: String, selected: [String]) -> Bool {
        let execution = TestExecutionRecord(attribution: .standalone, selectedTests: selected)
        return AssertionKillAttribution.evaluate(execution: execution, failingTests: [failing]).disposition == .withinSelection
    }

    // MARK: - Decoration is tolerated

    @Test("XCTest Target/Class/method() matches its decorated spellings and nothing else")
    func xctestIdentifiers() {
        let selected = ["AppTests/AddTests/testAdd()"]
        for spelling in [
            "AppTests/AddTests/testAdd()", "AppTests/AddTests/testAdd", "AddTests/testAdd()", "AddTests/testAdd",
            "App.AddTests/testAdd()"
        ] {
            #expect(inside(spelling, selected: selected), "\(spelling)")
        }
        // The same selection spelled without the trailing parentheses.
        #expect(inside("AppTests/AddTests/testAdd()", selected: ["AppTests/AddTests/testAdd"]))
        #expect(!inside("AppTests/AddTests/testSub()", selected: selected))
        #expect(!inside("testAdd()", selected: selected))
    }

    @Test("The same method name in two classes, only one selected, matches only the selected one")
    func sameMethodInTwoClasses() {
        let selected = ["AppTests/ClassA/testShared()"]
        #expect(inside("AppTests/ClassA/testShared()", selected: selected))
        #expect(inside("ClassA/testShared()", selected: selected))
        #expect(!inside("AppTests/ClassB/testShared()", selected: selected))
        #expect(!inside("ClassB/testShared()", selected: selected))
    }

    // MARK: - Collisions the last two components used to hide

    @Test("Nested suites sharing an inner suite and method name do not collide")
    func nestedSuites() {
        let selected = ["AppTests/Outer/Inner/check()"]
        #expect(inside("AppTests/Outer/Inner/check()", selected: selected))
        #expect(inside("Inner/check()", selected: selected))
        #expect(!inside("AppTests/Other/Inner/check()", selected: selected))
        #expect(!inside("OtherTests/Outer/Inner/check()", selected: selected))
        #expect(!inside("Other/Inner/check()", selected: selected))
        // An enclosing type that is not the target's module is a different test.
        #expect(!inside("Outer.Inner/check()", selected: ["AppTests/Inner/check()"]))
    }

    @Test("Swift Testing Target/method() with no suite is only the selected test when the selection spells it that way")
    func swiftTestingWithoutSuite() {
        #expect(inside("AppTests/check()", selected: ["AppTests/check()"]))
        #expect(!inside("AppTests/check()", selected: ["AppTests/SuiteA/check()"]))
        #expect(!inside("AppTests/check()", selected: ["OtherTests/check()"]))
        #expect(!inside("check()", selected: ["AppTests/check()"]))
    }

    @Test("Parameterized and overloaded Swift Testing names are different tests unless their parameter lists agree")
    func parameterizedNames() {
        let selected = ["AppTests/Suite/check(value:)"]
        #expect(inside("AppTests/Suite/check(value:)", selected: selected))
        #expect(!inside("AppTests/Suite/check()", selected: selected))
        #expect(!inside("AppTests/Suite/check(other:)", selected: selected))
        #expect(!inside("AppTests/Suite/check(value: 1)", selected: selected))
        #expect(!inside("AppTests/Suite/check(value:)/arguments", selected: selected))
        #expect(!inside("AppTests/Suite/check(value:)", selected: ["AppTests/Suite/check()"]))
    }

    @Test("Any unmatched failing test among several keeps the kill out of its selection")
    func oneUnmatchedIsEnough() {
        let execution = TestExecutionRecord(attribution: .standalone, selectedTests: ["AppTests/A/m()"])
        let result = AssertionKillAttribution.evaluate(
            execution: execution, failingTests: ["AppTests/A/m()", "AppTests/B/m()"]
        )
        #expect(result.disposition == .outsideSelection)
        #expect(result.unmatchedFailingTests == ["AppTests/B/m()"])
    }

    // MARK: - Verdict, cache and checkpoint

    private var proven: ActivationEvidence { .buildProductDiffersFromBaseline(mutantHash: "h1", baselineHash: "h0") }

    private func observations(
        failing: String, selected: [String], planID: String = planID, workUnitID: String = workUnitID
    ) throws -> MutationObservations {
        let point = try makeAnchoredPoint()
        let ref = PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID)
        let run = TestRunResult(
            status: .failed,
            summary: TestOutcomeSummary(total: 10, passed: 9, failed: 1, failingTests: [failing], durationSeconds: 1),
            command: CommandRecord(executable: "/usr/bin/true", arguments: [], workingDirectory: "/tmp"),
            resultArtifactPath: nil, diagnosis: "diag"
        )
        return MutationObservations(
            plannedMutation: ref,
            sourceApplication: .applied(makeEvidence(buildProductHash: "h1", activation: proven)),
            build: BuildObservation(outcome: .succeeded(buildProductHash: "h1", command: nil)),
            test: SingleTestObservation(
                run: run, applicationEvidence: .isolated(proven),
                execution: TestExecutionRecord(attribution: .standalone, selectedTests: selected)
            ),
            confirmations: []
        )
    }

    private static let colliding = (failing: "OtherTests/Outer/Inner/check()", selected: ["AppTests/Outer/Inner/check()"])
    private static let policy = MutationVerdictVerifier.VerdictVerificationPolicy.permissive

    @Test("A failing test that only collided with a selected one is an infrastructure failure with the unmatched name recorded")
    func collidingKillIsNotCredited() throws {
        let colliding = Self.colliding
        let record = MutationVerdictVerifier.verify(
            try observations(failing: colliding.failing, selected: colliding.selected), policy: Self.policy
        )
        #expect(record.outcome == .infrastructureFailure)
        let attribution = try #require(record.proof.evidence?.assertionKillAttribution)
        #expect(attribution.disposition == .outsideSelection)
        #expect(attribution.unmatchedFailingTests == [colliding.failing])

        let exact = MutationVerdictVerifier.verify(
            try observations(failing: colliding.selected[0], selected: colliding.selected), policy: Self.policy
        )
        #expect(exact.outcome == .killedByAssertion)
    }

    @Test("The verifier version was bumped because the same observations now classify differently")
    func versionBumped() {
        #expect(MutationVerdictVerifier.currentVersion >= 16)
    }

    @Test("A cached kill stamped by the previous version is a miss, and a colliding one never reloads as a kill")
    func cacheDoesNotServeCollidingKills() async throws {
        struct RawCacheRecord: Codable {
            let key: MutationResultCache.Key
            let observations: MutationObservations
            let verificationVersion: Int
            let executionVersion: Int
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kill-matching-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: root, policy: Self.policy)
        func file(_ key: MutationResultCache.Key) -> URL {
            let name = ContentHash.shortDigest(of: key.mutationID.rawValue + "\u{1F}" + key.contextDigest, length: 32)
            return root.appendingPathComponent(name + ".json")
        }
        let colliding = Self.colliding
        let collided = try observations(failing: colliding.failing, selected: colliding.selected)

        let previous = MutationResultCache.Key(mutationID: point.id, contextDigest: "version-14")
        try JSONEncoder().encode(RawCacheRecord(
            key: previous, observations: collided, verificationVersion: 14, executionVersion: ExecutionImplementationVersion.current
        )).write(to: file(previous))
        #expect(await cache.load(previous, point: point, planID: Self.planID, workUnitID: Self.workUnitID) == nil)

        let previousVersion = MutationResultCache.Key(mutationID: point.id, contextDigest: "version-15")
        try JSONEncoder().encode(RawCacheRecord(
            key: previousVersion, observations: collided, verificationVersion: 15,
            executionVersion: ExecutionImplementationVersion.current
        )).write(to: file(previousVersion))
        #expect(await cache.load(previousVersion, point: point, planID: Self.planID, workUnitID: Self.workUnitID) == nil)

        let current = MutationResultCache.Key(mutationID: point.id, contextDigest: "version-current")
        try JSONEncoder().encode(RawCacheRecord(
            key: current, observations: collided, verificationVersion: MutationVerdictVerifier.currentVersion,
            executionVersion: ExecutionImplementationVersion.current
        )).write(to: file(current))
        let loaded = await cache.load(current, point: point, planID: Self.planID, workUnitID: Self.workUnitID)
        #expect(loaded?.outcome != .killedByAssertion)
    }

    @Test("A checkpoint entry whose failing test only collided is re-verified and not resumed as a kill")
    func checkpointIsReverified() async throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kill-matching-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CheckpointStore(url: url, policy: Self.policy)
        let colliding = Self.colliding
        let collided = try observations(
            failing: colliding.failing, selected: colliding.selected, planID: plan.planID, workUnitID: plan.workUnitID
        )
        try await store.record(collided, durationSeconds: 1)

        let resumed = try await store.loadAll(plan: plan)
        #expect(resumed.count == 1)
        #expect(resumed.first?.outcome == .infrastructureFailure)
    }

    @Test("A stored kill without any attribution is not a kill under the current version")
    func missingAttributionNeverValid() throws {
        let colliding = Self.colliding
        let stripped = try observations(failing: colliding.selected[0], selected: colliding.selected)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stripped)) as? [String: Any])
        var test = try #require(object["test"] as? [String: Any])
        test.removeValue(forKey: "execution")
        object["test"] = test
        let decoded = try JSONDecoder().decode(
            MutationObservations.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(MutationVerdictVerifier.verify(decoded, policy: Self.policy).outcome == .infrastructureFailure)
    }
}
