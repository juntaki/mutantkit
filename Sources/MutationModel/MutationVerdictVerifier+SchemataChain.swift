// The schemata activation-chain verification, split out of `MutationVerdictVerifier.swift`.
// Members are module-internal rather than `private` only so they can live in this file.
extension MutationVerdictVerifier {
    /// One process's own complete, unambiguous proof: a STARTUP that loaded
    /// the expected unit/image under this run, and the one HIT that same
    /// process recorded for the expected mutation.
    struct VerifiedProcessSchemataChain {
        let startup: RuntimeStartupEvent
        let hit: RuntimeHitEvent
    }

    /// A compilation unit, independently proven by the build receipt to
    /// land in a real built image, plus at least one complete per-process
    /// STARTUP -> HIT chain proving that unit's mutation was selected and
    /// hit in this exact run.
    ///
    /// `processes` is never empty (`verifySchemataChain` throws rather than
    /// construct one with zero) — but it is not required to hold exactly
    /// one, either. A single `mutantkit run` invocation can genuinely
    /// spawn more than one test process for the identical build (the test
    /// runner's own multi-process execution model, not a MutantKit
    /// decision) — every one of those processes independently loading the
    /// same image and independently hitting the same mutation site is
    /// *more* proof of activation, never ambiguity. What must stay unique
    /// is each *process's own* STARTUP and HIT (`SchemataChainError
    /// .duplicateStartup`/`.duplicateHit`) and the semantic identity every
    /// chain is built from (unit/image/token/embedding/run) — never how
    /// many processes ran it.
    struct VerifiedSchemataChain {
        let unit: CompilationUnitReceipt
        /// Every image the receipt proves contains the unit. Activation needs
        /// one complete STARTUP -> HIT in `processes`, not one per image.
        let images: [BuiltImageReceipt]
        let processes: [VerifiedProcessSchemataChain]
    }

    /// STARTUP/HIT uniqueness is per (process, image): several images can be
    /// loaded into one test process, each with its own runtime instance, and
    /// whether bundles share a process is a build-tool detail, not an invariant.
    struct ProcessImageKey: Hashable, Comparable {
        let processID: Int32
        let imageUUID: String

        init(processID: Int32, imageUUID: ImageUUID) {
            self.processID = processID
            self.imageUUID = imageUUID.rawValue
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.processID, lhs.imageUUID) < (rhs.processID, rhs.imageUUID)
        }
    }

    enum SchemataChainError: Error, CustomStringConvertible {
        case noBuildReceipt
        case nonUniqueCompilationUnit
        case nonUniqueBuiltImage
        case noStartup
        case noHit
        case duplicateStartup(processID: Int32)
        case duplicateHit(processID: Int32)
        case orphanHit(processID: Int32)

        var description: String {
            switch self {
            case .noBuildReceipt:
                "the build-time compilation-unit-to-image mapping could not be proven"
            case .nonUniqueCompilationUnit:
                "the build receipt does not name exactly one compilation unit matching this mutation's own identity"
            case .nonUniqueBuiltImage:
                "the build receipt does not prove any built image containing the matched compilation unit"
            case .noStartup:
                "the transcript contains no STARTUP event matching this run's own expectation and the receipt's real image"
            case .noHit:
                "the transcript contains no HIT event from any process that started up under this run's own expectation"
            case let .duplicateStartup(processID):
                "process \(processID) recorded more than one STARTUP event matching this run's own expectation — the runtime's own at-most-once contract was violated"
            case let .duplicateHit(processID):
                "process \(processID) recorded more than one HIT event matching this run's own expectation — the runtime's own at-most-once contract was violated"
            case let .orphanHit(processID):
                "process \(processID) recorded a HIT event with no matching STARTUP in that same process — an inconsistent transcript"
            }
        }
    }

    /// Requires exactly one candidate, or throws — the shared discipline
    /// every stage of `verifySchemataChain` uses: zero candidates and more
    /// than one are both refused identically, never resolved by
    /// `.first`/`.max` picking (multi-image STARTUP/HIT matching).
    static func exactlyOne<T>(_ candidates: [T], or error: SchemataChainError) throws -> T {
        guard candidates.count == 1, let only = candidates.first else { throw error }
        return only
    }

    /// Builds the one, fully-proven chain from raw observations alone —
    /// `PlannedMutationRef -> sourceEmbeddingID -> CompilationUnitReceipt ->
    /// BuiltImageReceipt/architecture/LC_UUID -> {STARTUP -> HIT}+`. The
    /// only place this proof chain is ever constructed (the schemata proof chain):
    /// `SchemataMutationRunner` collects `observation` and decides nothing.
    ///
    /// Every raw STARTUP/HIT event not matching the expected semantic
    /// identity (run/unit/embedding/token/image) is treated as noise from
    /// an unrelated compilation unit or mutation sharing the same
    /// transcript — filtered out before any cardinality check, never
    /// itself a source of ambiguity. What remains is grouped *by process*:
    /// a real test invocation can legitimately spawn more than one process
    /// for the identical build (see `VerifiedSchemataChain`'s own doc
    /// comment), so uniqueness is enforced per process, not across the
    /// whole raw transcript.
    static func verifySchemataChain(_ observation: SchemataExecutionObservation) throws -> VerifiedSchemataChain {
        guard let receipt = observation.buildReceipt else { throw SchemataChainError.noBuildReceipt }
        let expectation = observation.expectation

        let unit = try exactlyOne(
            receipt.compilationUnits.filter {
                $0.compilationUnitID == expectation.compilationUnitID && $0.sourceEmbeddingID == expectation.sourceEmbeddingID
            },
            or: .nonUniqueCompilationUnit
        )
        let containingImages = receipt.images(containing: unit)
        guard !containingImages.isEmpty else { throw SchemataChainError.nonUniqueBuiltImage }

        func matchesExpectedIdentity(
            runID: RunID, compilationUnitID: CompilationUnitID, sourceEmbeddingID: SHA256Digest,
            token: SchemataSelectorToken, imageUUID: ImageUUID
        ) -> Bool {
            runID == expectation.runID && compilationUnitID == unit.compilationUnitID && sourceEmbeddingID == unit.sourceEmbeddingID
                && token == expectation.selectorToken
                && containingImages.contains { $0.slices.contains { $0.imageUUID == imageUUID } }
        }

        // Both collected before any absence is classified: a transcript
        // that has a HIT but genuinely no matching STARTUP in that same
        // process (an inconsistent transcript, `.orphanHit`) must never be
        // misreported as `.noStartup` — which Group 2's isolated-fallback
        // routing (`MutationVerdictVerifier.schemataIsolatedFallbackReason`)
        // treats as "legitimately never executed" and would otherwise
        // silently paper over a real inconsistency instead of failing
        // closed.
        let matchingStartups = observation.transcript.records.compactMap { record -> RuntimeStartupEvent? in
            guard case let .startup(event) = record else { return nil }
            return event
        }.filter {
            matchesExpectedIdentity(
                runID: $0.runID, compilationUnitID: $0.compilationUnitID, sourceEmbeddingID: $0.sourceEmbeddingID,
                token: $0.token, imageUUID: $0.imageUUID
            )
        }
        let matchingHits = observation.transcript.records.compactMap { record -> RuntimeHitEvent? in
            guard case let .hit(event) = record else { return nil }
            return event
        }.filter {
            matchesExpectedIdentity(
                runID: $0.runID, compilationUnitID: $0.compilationUnitID, sourceEmbeddingID: $0.sourceEmbeddingID,
                token: $0.token, imageUUID: $0.imageUUID
            )
        }

        let startupsByKey = Dictionary(grouping: matchingStartups) { ProcessImageKey(processID: $0.processID, imageUUID: $0.imageUUID) }
        let hitsByKey = Dictionary(grouping: matchingHits) { ProcessImageKey(processID: $0.processID, imageUUID: $0.imageUUID) }

        for key in startupsByKey.keys.sorted() where startupsByKey[key]!.count > 1 {
            throw SchemataChainError.duplicateStartup(processID: key.processID)
        }
        for key in hitsByKey.keys.sorted() where hitsByKey[key]!.count > 1 {
            throw SchemataChainError.duplicateHit(processID: key.processID)
        }
        let startupByKey = startupsByKey.compactMapValues(\.first)
        for key in hitsByKey.keys.sorted() where startupByKey[key] == nil {
            throw SchemataChainError.orphanHit(processID: key.processID)
        }

        guard !matchingStartups.isEmpty else { throw SchemataChainError.noStartup }

        let processes = hitsByKey.keys.sorted().map { key in
            VerifiedProcessSchemataChain(startup: startupByKey[key]!, hit: hitsByKey[key]!.first!)
        }
        guard !processes.isEmpty else { throw SchemataChainError.noHit }

        return VerifiedSchemataChain(unit: unit, images: containingImages, processes: processes)
    }

    static func schemataChainDiagnosis(_ chain: Result<VerifiedSchemataChain, Error>) -> String {
        guard case let .failure(error) = chain else {
            return "the schemata evidence does not prove this mutation was built, selected, and hit in this run"
        }
        return "the schemata chain could not be verified: \((error as? SchemataChainError)?.description ?? "\(error)")"
    }
}
