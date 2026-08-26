import Foundation
import MutationExecution
import MutationModel
import Testing

/// Direct unit tests for `MutationResultCache`: a stored entry round-trips
/// through the same key, does not leak across keys, and a corrupted file on
/// disk is treated as a miss rather than propagating as a thrown error. The
/// runner-level behaviour — a hit skips build/test, a miss evaluates and
/// stores back — is covered by `MutationRunnerResultCacheTests`.
@Suite("Mutation result cache")
struct MutationResultCacheTests {
    private let root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mutation-result-cache-tests-\(UUID().uuidString)")
    private let planID = "plan-cache-tests"
    private let workUnitID = "plan-cache-tests"

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func load(_ cache: MutationResultCache, _ key: MutationResultCache.Key, point: MutationPoint) async -> MutationResult? {
        await cache.load(key, point: point, planID: planID, workUnitID: workUnitID)
    }

    private func store(_ cache: MutationResultCache, observations: MutationObservations, for key: MutationResultCache.Key) async {
        await cache.store(observations, durationSeconds: 2, for: key)
    }

    @Test("A stored entry round-trips through the same key, re-verified fresh")
    func storeAndLoadRoundTrip() async throws {
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: root, policy: .permissive)
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "digest-A")
        let observations = makeObservations(point: point, outcome: .killedByAssertion, planID: planID, workUnitID: workUnitID)

        await store(cache, observations: observations, for: key)
        let loaded = await load(cache, key, point: point)

        #expect(loaded?.outcome == .killedByAssertion)
        #expect(loaded?.origin == .crossRunCache, "a cache hit is a cross-run reuse, distinct from a checkpoint resume")
    }

    @Test("A load against a different key returns nil")
    func differentKeyMisses() async throws {
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: root, policy: .permissive)
        await store(
            cache, observations: makeObservations(point: point, outcome: .killedByAssertion, planID: planID, workUnitID: workUnitID),
            for: MutationResultCache.Key(mutationID: point.id, contextDigest: "digest-A")
        )

        let loaded = await load(cache, MutationResultCache.Key(mutationID: point.id, contextDigest: "digest-B"), point: point)

        #expect(loaded == nil)
    }

    @Test("removeAll empties the cache")
    func removeAllEmpties() async throws {
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: root, policy: .permissive)
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "digest-A")
        await store(cache, observations: makeObservations(point: point, outcome: .killedByAssertion, planID: planID, workUnitID: workUnitID), for: key)

        await cache.removeAll()
        let loaded = await load(cache, key, point: point)

        #expect(loaded == nil)
    }

    @Test("A load against an empty cache returns nil without throwing")
    func emptyCacheReturnsNil() async throws {
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: root, policy: .permissive)

        let loaded = await load(cache, MutationResultCache.Key(mutationID: point.id, contextDigest: "never-stored"), point: point)

        #expect(loaded == nil)
    }

    @Test("A corrupted cache file yields nil, not a throw — the caller re-evaluates")
    func corruptedFileReturnsNil() async throws {
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: root, policy: .permissive)
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "corrupt")
        // Write a real entry through the public store API first, then
        // clobber that same on-disk file with garbage. The cache must treat
        // this exactly like a miss — load() already decodes with `try?`,
        // but this test pins the fail-closed contract explicitly: a bad
        // file never propagates as a thrown error, and — critically for a
        // result cache specifically — it never causes a phantom verdict to
        // be silently served. It just falls back to nil, which forces a
        // fresh evaluation, which is exactly what a miss already means.
        await store(cache, observations: makeObservations(point: point, outcome: .killedByAssertion, planID: planID, workUnitID: workUnitID), for: key)
        let anyFile = try #require(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first
        )
        try Data("not valid JSON".utf8).write(to: anyFile)

        let loaded = await load(cache, key, point: point)

        #expect(loaded == nil)
    }

    /// Critical finding from an independent review: a prior version of this
    /// cache stored the already-decided `MutationResult` and, on load,
    /// merely rebuilt a `VerdictProof` consistent with its own `outcome` —
    /// internally consistent, but never re-judged against the underlying
    /// facts. A structurally-valid forgery (a `.survived` outcome, a
    /// real-looking evidence blob, the current verifier version) would have
    /// been served as-is. This pins the actual fix: the cache stores raw
    /// `MutationObservations`, and a hand-edited file that changes the
    /// *facts* (the test actually failed) is caught the moment `load`
    /// re-runs `MutationVerdictVerifier.verify` on them — the served
    /// outcome reflects the edited facts, not whatever the file's stale
    /// framing implied, so this is not a coherent forgery at all once the
    /// verifier re-derives it.
    @Test("Editing a stored entry's underlying test result changes the re-verified outcome, not just the label")
    func editingStoredFactsChangesTheReverifiedOutcome() async throws {
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: root, policy: .permissive)
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "forged")
        await store(cache, observations: makeObservations(point: point, outcome: .survived, planID: planID, workUnitID: workUnitID), for: key)

        let url = root.appendingPathComponent(storageName(for: key))
        var object = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
        var observations = try #require(object["observations"] as? [String: Any])
        var test = try #require(observations["test"] as? [String: Any])
        var run = try #require(test["run"] as? [String: Any])
        // The stored fact "the test passed" flipped to "the test failed" —
        // exactly the shape of a hand-edited file trying to smuggle a
        // different verdict in without recomputing anything.
        run["status"] = "failed"
        test["run"] = run
        observations["test"] = test
        object["observations"] = observations
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let loaded = await load(cache, key, point: point)

        // Re-verification reads the edited fact honestly: a failed test with
        // proven activation is a real kill, not the `.survived` the file's
        // stale framing (and an unverified reconstruction) would have kept.
        #expect(loaded?.outcome == .killedByAssertion)
    }

    @Test("Editing a stored entry to reverify as a non-cacheable outcome is a miss, not served")
    func editingStoredEntryToNonCacheableOutcomeMisses() async throws {
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: root, policy: .permissive)
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "edited-non-reusable")
        await store(cache, observations: makeObservations(point: point, outcome: .survived, planID: planID, workUnitID: workUnitID), for: key)

        let url = root.appendingPathComponent(storageName(for: key))
        var object = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
        var observations = try #require(object["observations"] as? [String: Any])
        var test = try #require(observations["test"] as? [String: Any])
        var run = try #require(test["run"] as? [String: Any])
        // Re-verifying this edit produces `.infrastructureFailure` — a
        // non-cacheable outcome. `load` must apply the same reuse policy
        // `store` applies, not just re-verify and serve whatever comes out.
        run["status"] = "infrastructureFailure"
        test["run"] = run
        observations["test"] = test
        object["observations"] = observations
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let loaded = await load(cache, key, point: point)

        #expect(loaded == nil, "a hand-edited entry that reverifies as non-cacheable must not be served")
    }

    @Test("A cache hit preserves build/test/confirmation durations, not just the total")
    func cacheHitPreservesDetailedTimings() async throws {
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: root, policy: .permissive)
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "digest-timing")
        await cache.store(
            makeObservations(point: point, outcome: .killedByAssertion, planID: planID, workUnitID: workUnitID),
            durationSeconds: 12, buildDurationSeconds: 5, testDurationSeconds: 6, confirmationDurationSeconds: 1,
            for: key
        )

        let loaded = await load(cache, key, point: point)

        #expect(loaded?.durationSeconds == 12)
        #expect(loaded?.buildDurationSeconds == 5)
        #expect(loaded?.testDurationSeconds == 6)
        #expect(loaded?.confirmationDurationSeconds == 1)
    }

    // MARK: - ADR-0005 PR C: verificationVersion gating

    @Test("A record stamped by an older verifier version is a miss, not served stale")
    func staleVerificationVersionMisses() async throws {
        let point = try makeAnchoredPoint()
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "digest-A")
        let observations = makeObservations(point: point, outcome: .killedByAssertion, planID: planID, workUnitID: workUnitID)

        // `store` always stamps the version from re-verifying `observations`
        // itself (ADR-0006 Stage 1) — a stale version can no longer be
        // injected through the public API, so this simulates the on-disk
        // shape a superseded verifier would have left behind directly, the
        // same way `legacyRecordWithoutVersionFieldMisses` below does.
        try writeRawCacheRecord(key: key, observations: observations, verificationVersion: MutationVerdictVerifier.currentVersion - 1)

        let cache = MutationResultCache(root: root, policy: .permissive)
        let loaded = await load(cache, key, point: point)

        #expect(loaded == nil, "a superseded verifier version must not be served")
    }

    @Test("A legacy record with no verificationVersion field at all is a miss, not migrated")
    func legacyRecordWithoutVersionFieldMisses() async throws {
        let point = try makeAnchoredPoint()
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "digest-legacy")
        let observations = makeObservations(point: point, outcome: .killedByAssertion, planID: planID, workUnitID: workUnitID)

        // Simulate a cache file written before `verificationVersion` existed:
        // encode the old shape (`key`/`observations` only) directly to the
        // same storage path `store` would use, bypassing the public API
        // entirely.
        struct LegacyCacheRecord: Codable {
            let key: MutationResultCache.Key
            let observations: MutationObservations
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(LegacyCacheRecord(key: key, observations: observations))
        try data.write(to: root.appendingPathComponent(storageName(for: key)))

        let cache = MutationResultCache(root: root, policy: .permissive)
        let loaded = await load(cache, key, point: point)

        #expect(loaded == nil, "a pre-PR-C record must be discarded, not silently trusted")
    }

    // MARK: - Content-identity gating

    @Test("An entry whose point content no longer matches the current plan is a miss")
    func staleContentMisses() async throws {
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: root, policy: .permissive)
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "digest-A")
        await store(cache, observations: makeObservations(point: point, outcome: .killedByAssertion, planID: planID, workUnitID: workUnitID), for: key)

        // Same ID, different content — the anchor moved since this was cached.
        let movedPoint = point.with(utf8Range: ByteRange(start: point.utf8Range.start + 1, end: point.utf8Range.end + 1))
        let loaded = await load(cache, key, point: movedPoint)

        #expect(loaded == nil, "content that no longer matches the cached observation's pointDigest must not be served")
    }

    // MARK: - Per-mutant validity: the half of the cache key that was always correct

    /// The single most important thing the context digest does *not* have to
    /// do. A mutant whose own file changed must miss even under an identical
    /// context digest, because `load` independently re-checks
    /// `PlannedMutationRef.pointDigest`, which folds in `sourceFileHash`.
    ///
    /// The setup is the adversarial one: the *same* mutation site in a file
    /// that changed somewhere else entirely. ADR-0002 makes the `MutationID`
    /// stable across that edit on purpose — occurrence index is scoped to the
    /// enclosing declaration, so adding a function above it renumbers
    /// nothing. So the ID matches, the key matches, and the only thing
    /// standing between the caller and a stale verdict is the content digest.
    /// The test asserts the IDs really are equal first; without that it would
    /// pass for the wrong reason.
    @Test("A mutant whose own file changed misses, even with an identical context digest")
    func mutantWhoseOwnFileChangedMisses() async throws {
        let before = """
        struct Example {
            func isReady() -> Bool { return true }
        }
        """
        let after = """
        struct Example {
            func unrelatedHelper() -> Int { return 7 }
            func isReady() -> Bool { return true }
        }
        """
        let oldPoint = try #require(try discover(before, using: Operators.boolLiteral).first)
        let newPoint = try #require(try discover(after, using: Operators.boolLiteral).first)

        #expect(oldPoint.id == newPoint.id, "ADR-0002 keeps the ID stable here — that is what makes this adversarial")
        #expect(oldPoint.sourceFileHash != newPoint.sourceFileHash, "the file's content really did move")

        let cache = MutationResultCache(root: makeScratch(), policy: .permissive)
        // Same context digest on purpose: this test is about the per-mutant
        // half of the key doing its job with no help from the context half.
        let key = MutationResultCache.Key(mutationID: oldPoint.id, contextDigest: "identical-context")
        let observations = makeObservations(point: oldPoint, outcome: .survived, planID: planID, workUnitID: workUnitID)
        await store(cache, observations: observations, for: key)

        let loaded = await load(cache, key, point: newPoint)

        #expect(loaded == nil, "a verdict measured against different file content must never be served")
    }

    /// Two genuinely different mutants that share every superficial property
    /// a careless key might use — same file, same source, same operator, same
    /// enclosing declaration — must not be able to read each other's entries.
    @Test("Two different mutants in one declaration never collide")
    func differentMutantsInOneDeclarationNeverCollide() async throws {
        let source = """
        struct Example {
            func check() -> Bool { return true && false }
        }
        """
        let points = try discover(source, using: Operators.boolLiteral)
        #expect(points.count >= 2, "the fixture must actually yield two same-operator mutants in one declaration")
        let first = points[0]
        let second = points[1]
        #expect(first.id != second.id)

        let cache = MutationResultCache(root: makeScratch(), policy: .permissive)
        let digest = "shared-context"
        await store(
            cache, observations: makeObservations(point: first, outcome: .survived, planID: planID, workUnitID: workUnitID),
            for: MutationResultCache.Key(mutationID: first.id, contextDigest: digest)
        )

        // The second mutant asking under its own key: nothing stored for it.
        let ownKey = await load(cache, MutationResultCache.Key(mutationID: second.id, contextDigest: digest), point: second)
        #expect(ownKey == nil, "the second mutant has no entry of its own")

        // ...and the second mutant presented against the *first* mutant's key,
        // which is what a key collision would look like from the inside.
        let borrowedKey = await load(cache, MutationResultCache.Key(mutationID: first.id, contextDigest: digest), point: second)
        #expect(borrowedKey == nil, "one mutant's stored verdict must never be re-anchored onto a different mutant")
    }

    /// `storageName` hashes `mutationID ⧉ contextDigest` down to 32 hex
    /// characters, so a filename collision is conceivable in principle. It
    /// cannot produce a wrong answer, because `load` re-checks `record.key ==
    /// key` against the record's own stored copy of the key rather than
    /// trusting the path it was found at. This forces exactly that situation
    /// by planting one key's record at another key's path.
    @Test("An entry found at another key's storage path is rejected, not served")
    func recordFoundUnderAnotherKeysPathIsRejected() async throws {
        let point = try makeAnchoredPoint()
        let root = makeScratch()
        let cache = MutationResultCache(root: root, policy: .permissive)
        let stored = MutationResultCache.Key(mutationID: point.id, contextDigest: "context-A")
        let victim = MutationResultCache.Key(mutationID: point.id, contextDigest: "context-B")
        await cache.store(
            makeObservations(point: point, outcome: .survived, planID: planID, workUnitID: workUnitID),
            durationSeconds: 1, for: stored
        )

        // Simulate the collision: the same bytes now also live where a lookup
        // for `victim` will find them.
        let storedURL = root.appendingPathComponent(storageName(for: stored))
        try Data(contentsOf: storedURL).write(to: root.appendingPathComponent(storageName(for: victim)))

        let loaded = await load(cache, victim, point: point)

        #expect(loaded == nil, "the record's own key, not the path it was found at, decides whether it applies")
    }

    // MARK: - Allow-list store

    @Test("Only definitive, environment-independent verdicts are cached")
    func cacheableOutcomesAreStored() async throws {
        let point = try makeAnchoredPoint()
        for outcome in [MutationOutcome.survived, .noCoverage, .killedByAssertion,
                        .killedByCrash, .verifiedTimeout] {
            let cache = MutationResultCache(root: makeScratch(), policy: .permissive)
            let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "c-\(outcome.rawValue)")
            await store(cache, observations: makeObservations(point: point, outcome: outcome, planID: planID, workUnitID: workUnitID), for: key)

            let loaded = await load(cache, key, point: point)
            #expect(loaded != nil, "\(outcome.rawValue) should be cached")
            #expect(loaded?.outcome == outcome)
        }
    }

    @Test("Flaky, unconfirmed timeouts and environmental outcomes are never cached")
    func nonCacheableOutcomesAreRejected() async throws {
        let point = try makeAnchoredPoint()
        // `.flaky` is the headline fix: it looks like a verdict but moves with
        // the environment. The old deny-list stored it. `.baselineMismatch`/
        // `.skipped` are omitted: `MutationVerdictVerifier.verify` never
        // emits either from any observation shape (see `makeObservations`'s
        // doc comment), so `store`'s internal re-verify can never even
        // produce them — there is nothing left to test here for those two.
        let rejected: [MutationOutcome] = [.flaky, .timedOut, .unviable, .notApplied, .infrastructureFailure]
        for outcome in rejected {
            let cache = MutationResultCache(root: makeScratch(), policy: .permissive)
            let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "n-\(outcome.rawValue)")
            await store(cache, observations: makeObservations(point: point, outcome: outcome, planID: planID, workUnitID: workUnitID), for: key)

            let loaded = await load(cache, key, point: point)
            #expect(loaded == nil, "\(outcome.rawValue) must not be cached — a re-run is expected to differ")
        }
    }

    @Test("A cacheable outcome with no evidence of source application is not cached")
    func unreportableCacheableOutcomeIsRejected() async throws {
        // A phantom mutant: `killedByAssertion` is on the allow-list, but a
        // hollow (identical before/after hash) evidence proves nothing was
        // actually applied. Caching it anyway would replay the same
        // unproven verdict on every future run instead of giving the
        // mutant a real chance to be re-evaluated.
        let point = try makeAnchoredPoint()
        let cache = MutationResultCache(root: makeScratch(), policy: .permissive)
        let key = MutationResultCache.Key(mutationID: point.id, contextDigest: "phantom")
        let ref = PlannedMutationRef.forPoint(point, planID: planID, workUnitID: workUnitID)
        let hollow = MutationEvidence(
            sourceBeforeHash: ContentHash.of("same"), sourceAfterHash: ContentHash.of("same"), sourceDiff: ""
        )
        let command = CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: "/tmp")
        let observations = MutationObservations(
            plannedMutation: ref, sourceApplication: .applied(hollow),
            build: BuildObservation(outcome: .succeeded(buildProductHash: "hash", command: command)),
            test: SingleTestObservation(
                run: TestRunResult(status: .failed, summary: nil, command: command, resultArtifactPath: nil, diagnosis: "d"),
                applicationEvidence: .isolated(.buildProductDiffersFromBaseline(mutantHash: "a", baselineHash: "b"))
            )
        )
        #expect(!hollow.provesSourceApplication, "the fixture must actually exercise the phantom case")

        await store(cache, observations: observations, for: key)
        let loaded = await load(cache, key, point: point)

        #expect(loaded == nil)
    }

    private func makeScratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutation-result-cache-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func storageName(for key: MutationResultCache.Key) -> String {
        ContentHash.shortDigest(of: key.mutationID.rawValue + "\u{1F}" + key.contextDigest, length: 32) + ".json"
    }

    private func writeRawCacheRecord(key: MutationResultCache.Key, observations: MutationObservations, verificationVersion: Int) throws {
        struct RawCacheRecord: Codable {
            let key: MutationResultCache.Key
            let observations: MutationObservations
            let verificationVersion: Int
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(RawCacheRecord(key: key, observations: observations, verificationVersion: verificationVersion))
        try data.write(to: root.appendingPathComponent(storageName(for: key)))
    }
}
