import Foundation
import MutationModel

/// Cross-run result cache: incremental mutation execution across commits.
///
/// Unlike checkpoints, which are scoped to one exact `RunContextFingerprint`
/// and exist only to resume an interrupted run, this cache is explicit about
/// the proof required to reuse a result: callers supply a context digest that
/// must already include source/test/toolchain/configuration identity. The
/// cache never guesses whether two contexts are equivalent.
///
/// Reuse rests on two independent checks, and both must pass:
///
/// 1. **Per-mutant identity**, enforced here in `load`: the entry's
///    `mutationID` must equal this point's, *and* its `pointDigest` must
///    equal `PlannedMutationRef.pointDigest(for: point)`. That digest folds
///    in the mutated file's own `sourceFileHash` (ADR-0002), so a mutant
///    whose file changed by even one byte can never be served from cache,
///    whatever the context digest says.
/// 2. **Per-context identity**, enforced by the caller's digest. Since
///    `RunContextProbe.computeContextDigest` became content-addressed rather
///    than commit-addressed, that digest is a function of the bytes of every
///    non-ignored file in the worktree and of nothing else — so an entry
///    written at one commit is reusable at another commit whose relevant
///    content is byte-identical, and is *not* reusable when any of it moved.
///    Transitive-dependency scoping (reusing across a commit that changed
///    some unrelated file) is deliberately not attempted: MutantKit has no
///    per-file dependency graph, so it cannot prove which other files a
///    mutant's verdict depends on, and a guess there would be a false hit.
public actor MutationResultCache {
    public struct Key: Codable, Sendable, Hashable {
        public let mutationID: MutationID
        public let contextDigest: String

        public init(mutationID: MutationID, contextDigest: String) {
            self.mutationID = mutationID
            self.contextDigest = contextDigest
        }

        fileprivate var storageName: String {
            ContentHash.shortDigest(
                of: mutationID.rawValue + "\u{1F}" + contextDigest,
                length: 32
            ) + ".json"
        }
    }

    private let root: URL
    private let fileManager = FileManager.default
    /// The confirmation policy every reverify (`load`) and initial verify
    /// (`store`) uses — the same `Configuration.execution.retestKilledMutants`/
    /// `confirmCrashKills` flags the run storing an entry was actually
    /// gated on. Without this, a hand-edited entry with its `confirmations`
    /// stripped would reverify a primary kill/crash as if no confirmation
    /// were ever required. Required, not defaulted: a caller not
    /// exercising confirmation-policy enforcement (a test, mainly) passes
    /// `.permissive` explicitly, so omitting it can never silently reopen
    /// this at the library boundary.
    private let policy: MutationVerdictVerifier.VerdictVerificationPolicy

    public init(root: URL, policy: MutationVerdictVerifier.VerdictVerificationPolicy) {
        self.root = root
        self.policy = policy
    }

    /// Whether a freshly re-verified record is safe to reuse from the
    /// cache — the single gate both `store` and `load` apply, so a record
    /// that would never have been written cannot slip back in through
    /// `load` after a hand edit changes it to something reusable-looking
    /// (e.g. flipping a `.flaky`/`.infrastructureFailure` observation into
    /// one that reverifies as `.survived`). `store` checks this before
    /// writing; `load` checks it again after reverifying the decoded
    /// entry, since the entry on disk is untrusted and `load`'s own
    /// version/identity checks say nothing about cacheability.
    private static func isReusable(_ record: VerifiedMutationRecord) -> Bool {
        record.outcome.isCacheableResult && record.proof.evidence?.provesSourceApplication == true
    }

    /// Loads a cached verdict re-anchored to the *current* run's plan
    /// identity, or `nil` on anything from "no entry" to "the entry cannot
    /// be trusted."
    ///
    /// ADR-0006 Stage 1 (second review round): the on-disk entry carries
    /// raw `MutationObservations`, not a decided outcome — never trusted
    /// directly, decoded as an untrusted envelope and re-verified through
    /// `MutationVerdictVerifier.verify` exactly like a fresh evaluation
    /// would be, only *then* re-anchored to `point`/`planID`/`workUnitID`
    /// (`MutationResult.reanchored`, which independently checks that
    /// `point`'s own content still matches what was cached). A prior
    /// version of this cache stored the already-decided `MutationResult`
    /// and merely rebuilt a `VerdictProof` consistent with its own
    /// `outcome` on load — internally consistent, but never re-judged
    /// against the underlying facts, so a structurally-valid forged entry
    /// (same outcome, real-looking evidence, current version) would have
    /// been served. A version-mismatched, corrupted, or content-stale
    /// entry all read as a plain cache miss here, not a crash or a
    /// silently-trusted stale result.
    public func load(_ key: Key, point: MutationPoint, planID: String, workUnitID: String) -> MutationResult? {
        let url = root.appendingPathComponent(key.storageName)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(CacheRecord.self, from: data),
              record.key == key,
              // ADR-0005 PR C: a record stamped by an older verifier version
              // (or one that predates this field entirely — see
              // `CacheRecord.init(from:)` — always decodes to
              // `unknownVerificationVersion`, which can never equal a real
              // version) is discarded, not migrated. `MutationVerdictVerifier
              // .currentVersion` changing means the rules that judged this
              // record's trustworthiness may have changed too; replaces the
              // previous convention of hand-bumping a cache-namespace string
              // (e.g. `resultCache2`) whenever cache-trust rules changed.
              record.verificationVersion == MutationVerdictVerifier.currentVersion,
              // P4 cache-soundness gap fix: independent of the verifier's own
              // version above, and independent of `RunContextProbe`'s context
              // digest (whose `toolVersion`/`toolCommitSHA` inputs are
              // hardcoded development-build placeholders until a release
              // substitutes them — see `ExecutionImplementationVersion`'s own
              // doc comment for the real gap this closes). A record stamped
              // by a superseded execution-implementation version is
              // discarded, not migrated, the same convention
              // `verificationVersion` already established.
              record.executionVersion == ExecutionImplementationVersion.current,
              record.observations.plannedMutation.mutationID == point.id,
              record.observations.plannedMutation.pointDigest == PlannedMutationRef.pointDigest(for: point)
        else { return nil }

        let verified = MutationVerdictVerifier.verify(record.observations, policy: policy)
        guard Self.isReusable(verified) else { return nil }
        guard let reanchored = try? MutationResult.reanchored(
            from: verified, point: point, planID: planID, workUnitID: workUnitID, durationSeconds: record.durationSeconds,
            buildDurationSeconds: record.buildDurationSeconds, testDurationSeconds: record.testDurationSeconds,
            confirmationDurationSeconds: record.confirmationDurationSeconds
        ) else { return nil }
        // Marked as a cross-run cache hit, distinct from a checkpoint resume:
        // this verdict came from a *prior* run's stored result, not this run's
        // own checkpoint. The distinction is recorded on the result so a
        // report can tell a cheap reuse from an interrupted-and-resumed run
        // (see `ResultOrigin`).
        return reanchored.markedAsCrossRunCacheHit()
    }

    /// `verificationVersion` is always read from re-verifying `observations`
    /// itself (ADR-0006 Stage 1) — never a separate caller-supplied argument
    /// that could in principle disagree with what actually backs the
    /// resulting verdict.
    public func store(
        _ observations: MutationObservations,
        durationSeconds: Double,
        buildDurationSeconds: Double? = nil,
        testDurationSeconds: Double? = nil,
        confirmationDurationSeconds: Double? = nil,
        for key: Key
    ) {
        let record = MutationVerdictVerifier.verify(observations, policy: policy)

        // Allow-list, not deny-list: only a definitive, environment-independent
        // verdict is worth reusing across runs. `.flaky`, an unconfirmed
        // `.timedOut`, infrastructure failures, integrity violations and
        // unapplied mutants all describe the environment or the plan, not the
        // tests, so they are never cached even when reportable — a re-run is
        // expected to reach a different answer. See `MutationOutcome
        // .isCacheableResult`.
        //
        // The evidence check alongside it mirrors `MutationResult
        // .isReportable`: a cacheable outcome with no proof the mutation was
        // actually applied is exactly what `IntegrityChecker` used to flag as
        // a phantom mutant. Caching it anyway would replay the same unproven
        // verdict on every future run instead of giving the mutant a real
        // chance to be re-evaluated and reach a provable result. Every
        // cacheable outcome is an `.executed`/`.noCoverage` proof, so
        // `record.proof.evidence` is never `nil` for a proof this check lets
        // through — `provesSourceApplication` is the one still worth
        // checking explicitly.
        guard Self.isReusable(record) else { return }

        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let cacheRecord = CacheRecord(
            key: key, observations: observations, verificationVersion: record.verificationVersion,
            executionVersion: ExecutionImplementationVersion.current,
            durationSeconds: durationSeconds, buildDurationSeconds: buildDurationSeconds,
            testDurationSeconds: testDurationSeconds, confirmationDurationSeconds: confirmationDurationSeconds
        )
        guard let data = try? JSONEncoder().encode(cacheRecord) else { return }
        try? data.write(to: root.appendingPathComponent(key.storageName), options: .atomic)
    }

    public func removeAll() {
        try? fileManager.removeItem(at: root)
    }

    /// The untrusted, on-disk shape of one cached verdict. Carries the raw
    /// `MutationObservations`, never a decided outcome — see `load`'s doc
    /// comment for why.
    private struct CacheRecord: Codable {
        /// Never a real verifier version (`MutationVerdictVerifier
        /// .currentVersion` starts at 1 and only increases), so a record
        /// missing this field — written before it existed — always reads as
        /// version-mismatched and is discarded, exactly like a record
        /// stamped by a superseded version.
        static let unknownVerificationVersion = -1
        /// Same convention as `unknownVerificationVersion`, for the same
        /// reason: `ExecutionImplementationVersion.current` starts at 1 and
        /// only increases, so a record missing this field entirely (written
        /// before it existed) always reads as version-mismatched rather
        /// than being silently trusted as if execution behavior had never
        /// changed.
        static let unknownExecutionVersion = -1

        let key: Key
        let observations: MutationObservations
        let verificationVersion: Int
        let executionVersion: Int
        let durationSeconds: Double
        let buildDurationSeconds: Double?
        let testDurationSeconds: Double?
        let confirmationDurationSeconds: Double?

        init(
            key: Key, observations: MutationObservations, verificationVersion: Int, executionVersion: Int,
            durationSeconds: Double, buildDurationSeconds: Double?, testDurationSeconds: Double?, confirmationDurationSeconds: Double?
        ) {
            self.key = key
            self.observations = observations
            self.verificationVersion = verificationVersion
            self.executionVersion = executionVersion
            self.durationSeconds = durationSeconds
            self.buildDurationSeconds = buildDurationSeconds
            self.testDurationSeconds = testDurationSeconds
            self.confirmationDurationSeconds = confirmationDurationSeconds
        }

        enum CodingKeys: String, CodingKey {
            case key, observations, verificationVersion, executionVersion, durationSeconds, buildDurationSeconds, testDurationSeconds,
                 confirmationDurationSeconds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(Key.self, forKey: .key)
            observations = try container.decode(MutationObservations.self, forKey: .observations)
            verificationVersion = try container.decodeIfPresent(Int.self, forKey: .verificationVersion)
                ?? Self.unknownVerificationVersion
            executionVersion = try container.decodeIfPresent(Int.self, forKey: .executionVersion)
                ?? Self.unknownExecutionVersion
            durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
            buildDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .buildDurationSeconds)
            testDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .testDurationSeconds)
            confirmationDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .confirmationDurationSeconds)
        }
    }
}
