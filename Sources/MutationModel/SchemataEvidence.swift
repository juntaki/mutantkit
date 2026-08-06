import Foundation

/// Which backend produced a mutant's evidence, and what that evidence
/// actually proves.
///
/// `ActivationEvidence` (a whole-binary hash comparison) is sound for
/// isolated mode because one binary maps to exactly one mutant. It is not
/// sound for schemata: every mutant in a schema shares the same binary and
/// the same source-after-hash, so a hash diff cannot say *which* embedded
/// mutant a given test run actually exercised. Splitting evidence by backend
/// keeps that distinction explicit at the type level instead of overloading
/// one evidence shape to mean two different things depending on context. See
/// ADR-0003.
///
/// The two cases carry proof of very different strength. `.isolated`'s
/// `ActivationEvidence.provesActivation` is sound on its own. `.schemata`'s
/// `SchemataExecutionObservation` is deliberately raw and unproven — the
/// runner that collects it decides nothing (ADR-0006 Stage 2, Finding 2/3/4):
/// only `MutationVerdictVerifier.verifySchemataChain` may turn it into a
/// verdict, by building the whole proof chain (compilation unit -> built
/// image -> STARTUP -> HIT) from scratch, with unique-candidate matching at
/// every step.
public enum MutationApplicationEvidence: Codable, Sendable, Hashable {
    case isolated(ActivationEvidence)
    case schemata(SchemataExecutionObservation)
}

/// What the harness that launched one schemata mutant's test run already
/// knows before it ever looks at raw observations — the expectation the
/// observed chain (STARTUP -> HIT) is checked against by
/// `MutationVerdictVerifier.verifySchemataChain`. Never inferred from the
/// observations themselves: a process could always claim to be whatever it
/// likes, so ground truth has to come from the side that planned the run.
public struct SchemataRunExpectation: Codable, Sendable, Hashable {
    public let mutationID: MutationID
    /// The real compilation unit (ADR-0006 Stage 2) this mutation's source
    /// file was lowered into — checked against a candidate STARTUP/HIT
    /// event's own reported `compilationUnitID`.
    public let compilationUnitID: CompilationUnitID
    public let sourceEmbeddingID: SHA256Digest
    public let selectorToken: SchemataSelectorToken
    /// Fresh per run (including per confirmation retest) — see `RunID`'s
    /// own doc comment for why a nonce-primary identity, not a reused one,
    /// is what makes a stale/replayed transcript detectable.
    public let runID: RunID

    public init(
        mutationID: MutationID, compilationUnitID: CompilationUnitID, sourceEmbeddingID: SHA256Digest,
        selectorToken: SchemataSelectorToken, runID: RunID
    ) {
        self.mutationID = mutationID
        self.compilationUnitID = compilationUnitID
        self.sourceEmbeddingID = sourceEmbeddingID
        self.selectorToken = selectorToken
        self.runID = runID
    }
}

/// Everything one schemata mutant's test run actually produced, as raw,
/// unfiltered observations — collecting this is `SchemataMutationRunner`'s
/// whole job for schemata mode (ADR-0006 Stage 2): gather the facts, decide
/// nothing. `MutationVerdictVerifier.verifySchemataChain` is the only place
/// that turns this into a verdict, building the full proof chain
/// (`PlannedMutationRef -> sourceEmbeddingID -> CompilationUnitReceipt ->
/// BuiltImageReceipt/architecture/LC_UUID -> STARTUP -> HIT ->
/// TestRunResult -> VerifiedMutationRecord`) from scratch, requiring exactly
/// one candidate at every step — zero or more than one both fail closed,
/// never resolved by `.first`/`.max` picking (Finding 3).
public struct SchemataExecutionObservation: Codable, Sendable, Hashable {
    public let expectation: SchemataRunExpectation
    /// `nil` when the build-time compilation-unit-to-image mapping itself
    /// could not be proven (`SchemataBuildable.resolveSchemataBuildReceipt`
    /// threw, or resolved ambiguously — see `SchemataMutationRunner`). The
    /// verifier treats this exactly like a build receipt whose lookup
    /// resolved to zero or multiple candidates: not scorable, never a
    /// guess standing in for a real mapping.
    public let buildReceipt: SchemataBuildReceipt?
    /// The whole, unfiltered v3 binary transcript this run's process wrote
    /// — every STARTUP/HIT record it ever recorded, in file order. Never
    /// pre-filtered or matched by the collector that parses it (Finding 3);
    /// selecting the one real STARTUP/HIT candidate this run's own
    /// `expectation` describes is the verifier's job alone.
    public let transcript: RuntimeTranscript

    public init(expectation: SchemataRunExpectation, buildReceipt: SchemataBuildReceipt?, transcript: RuntimeTranscript) {
        self.expectation = expectation
        self.buildReceipt = buildReceipt
        self.transcript = transcript
    }
}
