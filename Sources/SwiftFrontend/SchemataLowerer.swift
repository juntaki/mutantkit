import Foundation
import MutationModel

/// Turns eligible `MutationPoint`s into an embedded schema — a whole chunk
/// at a time, never one point in isolation. See ADR-0003 (P0-3): nested
/// mutations, mutations sharing an expression tree, byte-offset drift from
/// an earlier edit in the same file, and cross-operator semantic conflicts
/// are all invisible to a lowerer that only ever sees one point at a time —
/// the same reason `MutationDiscovery` produces a whole plan rather than one
/// candidate per call.
///
/// Operates on `MutationPoint`, not the live-tree `MutationCandidate`: per
/// ADR-0002 ("the plan is the source of truth"), lowering — like
/// application — works from the plan's self-contained byte-range/content
/// anchors, never a `Syntax` node kept alive past discovery. `analyze` takes
/// the point's source alongside it rather than a live tree: a point alone
/// (byte range + text) cannot answer "is this literal in a context a
/// selector-wrapped rewrite would break" — a result-builder body, say — so
/// analysis re-derives that fact from a fresh parse, the same discipline
/// `SourceAnchorVerifier` already uses rather than trusting a node kept
/// alive from discovery.
public protocol SchemataLowerer: Sendable {
    /// This lowerer's own identity — required on the protocol, not left as
    /// ad hoc static properties on each conforming type, so a future
    /// registry can reject a duplicate lowerer ID, an ambiguous double
    /// registration for one operator, or a runtime ABI mismatch without
    /// downcasting to a concrete type first.
    var descriptor: SchemataLowererDescriptor { get }

    /// Whether and how a single point could be lowered, in isolation — the
    /// first pass, used to build the conflict graph before
    /// `lower(_:sources:)` ever commits to an actual chunk. A point this
    /// reports `.eligible` for can still end up `.isolatedOnly` once
    /// chunked, if it conflicts with another eligible point the planner
    /// could not separate into a different chunk.
    ///
    /// `source` is the file named by `point.file`, as it stood at discovery
    /// time (`point.sourceFileHash` identifies it) — analysis re-parses this
    /// to answer questions the point's own byte-range/text fields cannot.
    func analyze(_ point: MutationPoint, source: Data) -> SchemataEligibility

    /// Performs the lowering for every eligible point in `chunk` at once,
    /// against the full set of source files the chunk spans — letting the
    /// lowerer see conflicts and interactions a point-at-a-time API cannot.
    func lower(_ chunk: SchemataChunk, sources: [SchemataSourceFile]) throws -> SchemataProgram
}

/// One schema build's worth of mutation points — already partitioned by the
/// chunk planner (target/module/product/conflict-layer/locality; see
/// ADR-0003) into a set small enough to build as one compile unit.
public struct SchemataChunk: Sendable {
    public let chunkID: String
    public let points: [MutationPoint]
    /// Which build-system project this chunk's target belongs to — e.g. a
    /// resolved `.xcodeproj` path, or a SwiftPM package identity. Carried
    /// alongside `target`/`module`/`product` because those alone are not a
    /// stable identity: two different projects can trivially have
    /// identically-named targets. See `SchemataTargetInfo.projectIdentity`,
    /// which this is threaded from.
    public let projectIdentity: String
    public let target: String
    public let module: String
    public let product: String
    /// The selector namespace every mutation this chunk embeds shares —
    /// derived deterministically from `chunkID`, never assigned by the
    /// caller, so two independently-constructed `SchemataChunk` values for
    /// the identical `chunkID` always agree. See
    /// `SchemataSelectorToken.namespace`.
    public var namespace: UInt64 { ContentHash.uint64(of: chunkID) }

    public init(
        chunkID: String, points: [MutationPoint], projectIdentity: String, target: String, module: String, product: String
    ) {
        self.chunkID = chunkID
        self.points = points
        self.projectIdentity = projectIdentity
        self.target = target
        self.module = module
        self.product = product
    }
}

/// One source file as `SchemataLowerer.lower(_:sources:)` sees it — plain
/// text, not a parsed tree, since the lowerer re-parses (or otherwise
/// rewrites) whatever files a chunk's candidates span, and a chunk can span
/// more than the file any single candidate came from.
public struct SchemataSourceFile: Sendable {
    public let relativePath: String
    public let contents: String
    /// How many whole lines were prepended ahead of this file's own
    /// original content — `0` for every file `SchemataLowerer.lower(_:sources:)`
    /// did not need to add a declaration to (which is most of them; see
    /// `BoolLiteralSchemataLowerer.runtimePreamble`'s doc comment for why
    /// exactly one file per chunk carries it). A caller mapping a line
    /// number the *built* artifact reports (a coverage tool, a compiler
    /// diagnostic, a crash symbolication) back to this file's original
    /// source computes `originalLine = builtLine - prependedLineCount` —
    /// every other file in the same chunk needs no further adjustment
    /// beyond that (for `BoolLiteralSchemataLowerer`'s own splice, which
    /// never spans or introduces a newline; a future lowerer whose splice
    /// could would need to report its own additional shift, which this
    /// field does not yet attempt to model).
    public let prependedLineCount: Int

    public init(relativePath: String, contents: String, prependedLineCount: Int = 0) {
        self.relativePath = relativePath
        self.contents = contents
        self.prependedLineCount = prependedLineCount
    }
}

/// The result of lowering one chunk: the rewritten sources to actually
/// build, plus the `SchemataPlanEntry` records describing where each
/// embedded candidate landed.
public struct SchemataProgram: Sendable {
    public let chunkID: String
    /// Content-addressed identity of this chunk's build inputs, as the
    /// lowerer itself can see them — runtime ABI, lowerer identity/version,
    /// target/module/product, lowered source content, and the token map.
    /// Deliberately *not* called an "artifact ID": a build orchestrator must
    /// still fold in toolchain/platform/SDK/build-argument/linker inputs
    /// (the role `SchemataPlan.toolchainHash`/`buildArgumentsHash` already
    /// play at the plan level) before this identifies an actual, cache-ready
    /// build artifact — see `SchemataPlanEntry.sourceEmbeddingID`.
    public let sourceEmbeddingID: String
    public let loweredSources: [SchemataSourceFile]
    public let entries: [SchemataPlanEntry]

    public init(
        chunkID: String,
        sourceEmbeddingID: String,
        loweredSources: [SchemataSourceFile],
        entries: [SchemataPlanEntry]
    ) {
        self.chunkID = chunkID
        self.sourceEmbeddingID = sourceEmbeddingID
        self.loweredSources = loweredSources
        self.entries = entries
    }
}
