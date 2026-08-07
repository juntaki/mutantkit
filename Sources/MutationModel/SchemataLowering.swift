import Foundation

/// One mutation's runtime selector identity — the `(namespace, localIndex)`
/// pair every generated call site and every STARTUP/HIT record in the real
/// transcript must agree on bit-for-bit before a hit can be credited to a
/// specific mutation (checked by `MutationVerdictVerifier.verifySchemataChain`).
///
/// A bare per-chunk index alone cannot disambiguate two chunks loaded into
/// the same process at once — an app and a linked framework, say, each with
/// their own independently-numbered schema, would both claim "index 0" for
/// their first mutation. `namespace` (derived from the owning chunk's
/// content-addressed `chunkID`, see `SchemataChunk.namespace`) makes the
/// pair unique process-wide. `localIndex == 0` is reserved as the "no
/// mutation selected" sentinel and is never assigned to a real mutation, so
/// an uninitialized or bootstrap-time read of the runtime global can never
/// be mistaken for a live selection.
public struct SchemataSelectorToken: Codable, Sendable, Hashable {
    public let namespace: UInt64
    public let localIndex: UInt32

    public init(namespace: UInt64, localIndex: UInt32) {
        precondition(localIndex > 0, "localIndex 0 is reserved as the inactive sentinel")
        self.namespace = namespace
        self.localIndex = localIndex
    }

    private enum CodingKeys: String, CodingKey {
        case namespace, localIndex
    }

    /// Compiler-synthesized `Decodable` would call the memberwise fields
    /// directly, bypassing `init(namespace:localIndex:)`'s precondition
    /// entirely — a hand-edited or corrupted `schemata-plan.json` could
    /// decode a `localIndex: 0` token that no code path could ever have
    /// constructed. Explicit here so the invariant holds for every decode,
    /// not just every construction.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        namespace = try container.decode(UInt64.self, forKey: .namespace)
        let decodedLocalIndex = try container.decode(UInt32.self, forKey: .localIndex)
        guard decodedLocalIndex > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .localIndex, in: container,
                debugDescription: "localIndex 0 is reserved as the inactive sentinel and is never a valid token"
            )
        }
        localIndex = decodedLocalIndex
    }
}

/// Where one mutation ended up — embedded in a schema chunk under a specific
/// selector token, or left on the isolated backend and why. An enum, not a
/// cluster of independently-nilable fields (`chunkID`, `selectorToken`,
/// `sourceEmbeddingID`, `fallbackReason`): the old shape could represent
/// states no real lowering ever produces (`chunkID` set with
/// `selectorToken` nil, say), and a reader had no way to tell "not embedded
/// yet" apart from "a bug omitted a required field."
///
/// `.embedded` carries a *list* of placements (ADR-0005 PR F), not a single
/// flat set of fields: a mutation whose source file is compiled into more
/// than one target (a shared model file added directly to an app target and
/// a widget extension's own Compile Sources, say) embeds independently into
/// each target's own chunk and selector namespace — each is a genuinely
/// separate build, with its own build-time facts. A single-target mutation
/// simply has one placement in the list.
public enum SchemataPlacement: Codable, Sendable, Hashable {
    case embedded(placements: [SchemataEmbeddedPlacement])
    case isolatedFallback(reason: SchemataUnsupportedReason)
}

/// One target's own independent embedding of a mutation.
///
/// Everything here is specific to *this* target's build: two placements for
/// the same `MutationID` (one per target it is compiled into) can carry
/// entirely different `chunkID`/`selectorToken`/`sourceEmbeddingID` values,
/// since each target is built, chunked, and namespaced independently.
public struct SchemataEmbeddedPlacement: Codable, Sendable, Hashable {
    public let chunkID: String
    public let selectorToken: SchemataSelectorToken
    /// The lowerer's own view of this chunk's build inputs — see
    /// `SchemataProgram.sourceEmbeddingID`'s doc comment for why this is not
    /// yet a full, cache-ready artifact identity.
    public let sourceEmbeddingID: String
    public let lowererID: String
    public let lowererVersion: Int
    public let projectIdentity: String
    public let target: String
    public let module: String
    public let product: String
    /// Every Mach-O image expected to carry this mutation once this
    /// specific target is built. Superseded by ADR-0006 Stage 2's real
    /// build-time proof (`SchemataBuildReceipt`/`CompilationUnitReceipt`,
    /// resolved by `SchemataBuildable.resolveSchemataBuildReceipt` and
    /// checked by `MutationVerdictVerifier.verifySchemataChain`) — not
    /// populated by any production caller.
    public let expectedImages: [String]

    public init(
        chunkID: String,
        selectorToken: SchemataSelectorToken,
        sourceEmbeddingID: String,
        lowererID: String,
        lowererVersion: Int,
        projectIdentity: String,
        target: String,
        module: String,
        product: String,
        expectedImages: [String]
    ) {
        self.chunkID = chunkID
        self.selectorToken = selectorToken
        self.sourceEmbeddingID = sourceEmbeddingID
        self.lowererID = lowererID
        self.lowererVersion = lowererVersion
        self.projectIdentity = projectIdentity
        self.target = target
        self.module = module
        self.product = product
        self.expectedImages = expectedImages
    }
}

/// A `SchemataLowerer`'s own identity — its ID, version, the runtime ABI its
/// generated call sites depend on, and which operators it can embed.
/// Required by the protocol (not left as ad hoc static properties on each
/// conforming type) so a future lowerer registry can reject a duplicate
/// lowerer ID, an ambiguous double-registration for the same operator, or a
/// runtime ABI mismatch without downcasting to a concrete type first.
public struct SchemataLowererDescriptor: Codable, Sendable, Hashable {
    public let lowererID: String
    public let lowererVersion: Int
    public let runtimeABIVersion: Int
    public let supportedOperatorIDs: Set<String>

    public init(lowererID: String, lowererVersion: Int, runtimeABIVersion: Int, supportedOperatorIDs: Set<String>) {
        self.lowererID = lowererID
        self.lowererVersion = lowererVersion
        self.runtimeABIVersion = runtimeABIVersion
        self.supportedOperatorIDs = supportedOperatorIDs
    }
}

/// How a candidate would have to be rewritten to embed it in a schema binary.
///
/// See ADR-0003. There is deliberately no universal lowering: an `if`
/// expression is only legal Swift in variable-initialization, `return`, and
/// direct-assignment position, so a candidate sitting in a function argument
/// or an arbitrary subexpression cannot use that shape at all. `if` expression
/// branches are also independently type-checked against a shared expected
/// type, while `?:` uses bidirectional inference — using the wrong lowering
/// shape for a site can silently change what the *inactive* schema
/// type-checks to versus the original, which is exactly the correctness gap
/// this whole design exists to close. Classifying the shape a candidate needs
/// before anything is embedded is what makes that provable per-site instead
/// of assumed.
public enum SchemataLoweringKind: String, Codable, Sendable, Hashable {
    /// `true <-> false` and similar single-token literal swaps: no
    /// expression-position constraint, since the replacement is another
    /// literal of the same type, not a differently-shaped expression.
    case literalSelection
    /// A `?:`-shaped site, narrow enough that both arms can be proven
    /// type-invariant with and without the mutation active.
    case expressionTernary
    /// A whole statement is swapped for another statement (or removed) —
    /// legal anywhere a statement is legal, unlike an expression-position
    /// lowering.
    case statementBranch
    /// The mutation only ever appears in `return`'s operand position.
    case returnExpression
    /// The mutation only ever appears as a `let`/`var`'s initializer
    /// expression.
    case declarationInitializer
}

/// Why a candidate cannot be lowered into a schema at all, and so stays on
/// the isolated backend regardless of `execution.strategy`.
public enum SchemataUnsupportedReason: Codable, Sendable, Hashable {
    /// Inside a `@ViewBuilder`-style result-builder body, every statement is
    /// rewritten through builder methods the lowering can't safely reproduce
    /// — same hazard `ElseClauseDeletionOperator`'s exclusion already
    /// documents for isolated mode, just also disqualifying schemata.
    case resultBuilderBody
    /// The semantic-fingerprint check (result type, selected overload,
    /// `async`/`throws`, actor isolation, ownership) could not prove the
    /// active and inactive schema type-check identically at this site.
    case typeVarianceUnproven
    /// The site is only ever evaluated once, at process/module startup —
    /// requires the startup-mutant policy (a fresh process, full test
    /// target, no per-test attribution), not ordinary runtime selection.
    case processStartRequired
    /// This operator has no lowering implementation yet at all.
    case operatorNotYetLowered(operatorID: String)
    /// Analyzed fine alone, but conflicts with another candidate in the same
    /// chunk (shared rewrite envelope, AST ancestry, or inferred-type
    /// dependency) in a way the chunk planner could not resolve into
    /// separate layers.
    case structuralConflict(reason: String)
    /// The current backend/platform combination (e.g. a UI test target, an
    /// app extension, an XPC service) cannot receive runtime selection —
    /// see ADR-0003's UI-test section.
    case platformUnsupported(reason: String)
    /// A lowering that needs to read an operand more than once (e.g.
    /// `RelationalOperatorReplacementSchemataLowerer`'s `lhs`/`rhs`) could
    /// not prove that operand safe to evaluate a second time — a function
    /// call, subscript, or anything else whose evaluation could have a
    /// side effect or a different result the second time.
    case unsupportedOperand(reason: String)
    /// The site sits in an `async`/`await` or `throws`/`try` expression
    /// context this lowering does not yet reason about — evaluation order,
    /// suspension points, and error propagation are exactly the properties
    /// a naive lowering risks changing.
    case asyncOrThrowingExpression
    /// The site involves an ownership-sensitive binding (`inout`,
    /// `borrowing`, `consuming`) this lowering does not yet reason about.
    case ownershipSensitiveExpression
}

/// The outcome of asking whether one candidate could be embedded in a
/// schema, in isolation — the first pass, before a chunk's `SchemataLowerer`
/// commits to an actual embedding. See `SchemataLowerer` in `SwiftFrontend`.
public enum SchemataEligibility: Codable, Sendable, Hashable {
    /// Safe to lower. `rewriteEnvelope` is the exact byte range the lowering
    /// would rewrite (which can be wider than the candidate's own mutated
    /// range, once the lowering wraps it in a selector). `conflictKeys` is
    /// compared against every other eligible candidate's, in the same file
    /// or elsewhere in the chunk, to detect a structural conflict beyond
    /// simple byte-range overlap — see `SchemataUnsupportedReason
    /// .structuralConflict`.
    case eligible(loweringKind: SchemataLoweringKind, rewriteEnvelope: ByteRange, conflictKeys: Set<String>)
    case isolatedOnly(reason: SchemataUnsupportedReason)

    public var isEligible: Bool {
        switch self {
        case .eligible: true
        case .isolatedOnly: false
        }
    }
}
