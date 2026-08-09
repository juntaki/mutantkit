import Foundation
import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Why `BoolLiteralSchemataLowerer.lower(_:sources:)` refused to embed a
/// chunk, instead of silently producing a schema that does not match the
/// plan it was asked to build. `lower` is the last line of defense against a
/// chunk-planner bug (duplicate/overlapping assignment, a malformed chunk) —
/// it must fail closed on any of these, the same way a corrupt or hand-
/// edited plan already fails `MutationPlan.verify` rather than being
/// silently trusted.
public enum SchemataLoweringError: Error, Equatable, CustomStringConvertible {
    /// A point in the chunk belongs to an operator this lowerer does not
    /// handle — the chunk planner is responsible for only ever routing a
    /// chunk to a lowerer that can embed every point in it.
    case unsupportedOperator(operatorID: String)
    /// A point named a file that never appeared in `sources`.
    case missingSource(file: String)
    /// The point's anchor no longer matches the source it is about to be
    /// spliced into — the same discipline `SourceAnchorVerifier` already
    /// enforces for isolated-mode application, applied before any embedding
    /// commits to bytes.
    case anchorRejected(mutationID: MutationID, diagnosis: String)
    /// The chunk planner assigned the same `MutationID` to a chunk twice.
    case duplicateMutationID(MutationID)
    /// `sources` named the same file twice — which copy is authoritative is
    /// ambiguous, so neither is trusted.
    case duplicateSourcePath(String)
    /// Two points in the same file claim overlapping (or identical) byte
    /// ranges — splicing one would corrupt the other's anchor. Covers exact
    /// duplicates as a special case of overlap.
    case overlappingRewriteEnvelopes(file: String, first: MutationID, second: MutationID)
    /// A chunk with no points is not a build the chunk planner should ever
    /// have produced.
    case emptyChunk
    /// More points than a dense `UInt32` selector-token space (with `0`
    /// reserved) can address.
    case tooManyMutations(count: Int)

    public var description: String {
        switch self {
        case let .unsupportedOperator(operatorID):
            "lowerer cannot embed operator \(operatorID)"
        case let .missingSource(file):
            "no source file supplied for \(file)"
        case let .anchorRejected(mutationID, diagnosis):
            "\(mutationID.rawValue): \(diagnosis)"
        case let .duplicateMutationID(mutationID):
            "mutation \(mutationID.rawValue) appears more than once in the chunk"
        case let .duplicateSourcePath(file):
            "source file \(file) was supplied more than once"
        case let .overlappingRewriteEnvelopes(file, first, second):
            "\(first.rawValue) and \(second.rawValue) claim overlapping byte ranges in \(file)"
        case .emptyChunk:
            "chunk has no points to embed"
        case let .tooManyMutations(count):
            "chunk has \(count) points, more than a UInt32 selector space (minus the reserved sentinel) can address"
        }
    }
}

/// Embeds `swift.core.bool-literal-inversion` points into a schema binary.
///
/// A boolean literal has the simplest possible lowering shape
/// (`.literalSelection`, see `SchemataLoweringKind`): the replacement is
/// another literal of the exact same type as the original, so wrapping it in
/// a ternary selector introduces no expression-position constraint and no
/// bidirectional-inference hazard — unlike `.expressionTernary` sites, both
/// arms here are trivially and identically typed regardless of which arm the
/// runtime selects. This is why bool-literal-inversion is the first operator
/// lowered: it proves the embed → verify → activate pipeline without the
/// operator itself introducing a second source of risk.
///
/// Source-generation and compilation only, per the roadmap's S1 scope — no
/// runtime selection exists yet. `__mutantkitIsActiveV3` resolves to
/// whatever declaration is linked against the lowered source; S2 provides
/// the real, C-backed one (`mutantkit_protocol_v3.c`).
public struct BoolLiteralSchemataLowerer: SchemataLowerer {
    public static let lowererID = "swift.core.bool-literal-inversion.schemata"
    public static let lowererVersion = 1
    /// Bumped from `1` to `2` for the v3 runtime protocol (ADR-0006 Stage
    /// 2): the generated call site's shape changed entirely (a per-
    /// compilation-unit descriptor registered once, passed into every call,
    /// versus v2's bare `(namespace, localIndex)` pair with no descriptor
    /// at all) — folded into `sourceEmbeddingID` so a cached embedding
    /// built under the old ABI is never reused as if it were built under
    /// this one, the same way `lowererVersion` invalidates one built under
    /// an older lowering.
    public static let runtimeABIVersion = 2
    /// The self-contained declarations that make `mutantkit_register_unit_v3`/
    /// `mutantkit_is_active_v3` visible to the Swift compiler —
    /// `@_silgen_name`, not `import MutantKitSchemataRuntimeC`. This is
    /// deliberate: it decouples "the Swift compiler can see a declaration"
    /// from "a linker can find the symbol," which `import` conflates.
    /// SwiftPM (S2) can still satisfy the second half through its own
    /// dependency graph — a target depending on the
    /// `MutantKitSchemataRuntime` product links its object code in
    /// regardless of whether any Swift file literally imports it. Xcode
    /// (S3) has no equivalent module graph at all; the same declaration
    /// there is satisfied by linking a prebuilt static library via
    /// `OTHER_LDFLAGS`/`LIBRARY_SEARCH_PATHS` build-setting overrides alone,
    /// with no `.pbxproj` edit and no header/module map needed either. One
    /// lowering, portable to both backends.
    ///
    /// Prepended to exactly one *existing* file per chunk — never written
    /// into a newly-created file. An earlier draft generated a dedicated
    /// `.generated.swift` file for this declaration; that works for SwiftPM
    /// (any file under a target's source directory is compiled automatically)
    /// and for an xcodegen-generated Xcode project using directory-based
    /// `sources:` inclusion, but not for a real, pre-existing Xcode project,
    /// whose `.pbxproj` lists specific files in its Compile Sources build
    /// phase — writing a new file to disk does not add it there, and S3's
    /// entire premise is "no `.pbxproj` edit". Prepending into a file that is
    /// already part of `sources` (and therefore already registered in
    /// whatever build system owns the target) has no such dependency.
    ///
    /// A top-level Swift declaration is visible to every file in the same
    /// module without an import, so this only needs to happen once per
    /// chunk — an earlier, even older draft prepended it to every touched
    /// file, which broke as soon as a chunk spanned more than one file
    /// ("invalid redeclaration"). The chosen file is the lexicographically
    /// least `relativePath` in `sources` — deterministic, and stable across
    /// every chunk of the same target, since `SchemataChunkPlanner` always
    /// passes the *full* target file set to `lower(_:sources:)`, not just
    /// the subset a given chunk happens to touch.
    public static let sharedDeclarationPreamble = """
    @_silgen_name("mutantkit_register_unit_v3")
    @usableFromInline
    func __mutantkitRegisterUnitV3(
        _ sourceEmbeddingHex: UnsafePointer<CChar>,
        _ compilationUnitHex: UnsafePointer<CChar>
    ) -> OpaquePointer?

    @_silgen_name("mutantkit_is_active_v3")
    @usableFromInline
    func __mutantkitIsActiveV3(
        _ descriptor: OpaquePointer?,
        _ namespaceValue: UInt64,
        _ localIndex: UInt32
    ) -> Bool

    """

    /// Registers this file's own compilation-unit identity, once, at
    /// process startup (ADR-0006 Finding 2) — prepended to *every* file
    /// that carries at least one embedded mutation, unlike
    /// `sharedDeclarationPreamble`'s single-file placement, since each
    /// file's `mutantkit_register_unit_v3` call must be made from within
    /// that file for `dladdr` on its own caller's return address to
    /// resolve to that file's own compiled image. `suffix` disambiguates
    /// the generated `private let` across files in the same module — not
    /// strictly required for correctness (a top-level `private` in Swift
    /// already scopes to its declaring file alone, so the same literal name
    /// in two files would not collide), but keeps a generated symbol name
    /// traceable to the compilation unit that declared it, which matters
    /// once a crash or diagnostic ever needs to reference it by name.
    ///
    /// `nonisolated(unsafe)`: an executable target's top-level code can
    /// default to main-actor isolation (default actor isolation, on by
    /// default for `swift-tools-version: 6.0`+ executables) — a plain
    /// top-level `let` would then only be referenceable from main-actor
    /// context, but every mutated call site (inside an arbitrary function,
    /// possibly on a background thread/actor) needs to read it directly.
    /// Safe here specifically because the value is written exactly once,
    /// by an immediately-invoked closure, before any call site can possibly
    /// read it (Swift initializes top-level `let`s before `main` runs) —
    /// never mutated afterward, so there is no actual data race to guard
    /// against, only the type system's inability to see that on its own.
    static func descriptorPreamble(suffix: String, sourceEmbeddingID: String, compilationUnitID: String) -> String {
        """
        @usableFromInline
        nonisolated(unsafe) let __mutantkitUnitDescriptor_\(suffix): OpaquePointer? = {
            "\(sourceEmbeddingID)".withCString { source in
                "\(compilationUnitID)".withCString { unit in
                    __mutantkitRegisterUnitV3(source, unit)
                }
            }
        }()

        """
    }

    public let descriptor = SchemataLowererDescriptor(
        lowererID: lowererID,
        lowererVersion: lowererVersion,
        runtimeABIVersion: runtimeABIVersion,
        supportedOperatorIDs: [BoolLiteralInversionOperator.descriptor.id]
    )

    public init() {}

    public func analyze(_ point: MutationPoint, source: Data) -> SchemataEligibility {
        guard point.operatorID == BoolLiteralInversionOperator.descriptor.id else {
            return .isolatedOnly(reason: .operatorNotYetLowered(operatorID: point.operatorID))
        }

        let verification = SourceAnchorVerifier.verify(point, against: source, depth: .full)
        guard verification.isValid else {
            return .isolatedOnly(reason: .structuralConflict(reason: verification.diagnosis))
        }
        guard let node = SourceAnchorVerifier.matchedNode(for: point, in: source) else {
            return .isolatedOnly(reason: .structuralConflict(reason: "no syntax node resolved at the anchor"))
        }
        // A result builder rewrites every statement in its body through
        // builder methods invisible to the parser — wrapping a literal in a
        // runtime selector there is exactly the kind of rewrite a builder
        // does not expect, the same hazard `ElseClauseDeletionOperator`
        // already excludes for its own, differently-shaped rewrite.
        guard !OperatorExclusions.isInsideResultBuilderBody(node) else {
            return .isolatedOnly(reason: .resultBuilderBody)
        }
        // A `static`/module-scope `let` initializer's memoization was
        // reasoned about here in an earlier draft (S6) as a hazard — but
        // that reasoning assumed a many-mutants-per-process execution model
        // this codebase never actually adopted (see ADR-0003's correction
        // addendum). Under the real model — one requested token, fixed for
        // an entire fresh process's lifetime, set before the process even
        // launches — a memoized-once value is computed exactly once *with
        // that process's single token already active*, indistinguishable
        // from how isolated mode's own one-mutation-per-binary model already
        // works. There is nothing left to exclude here.

        return .eligible(loweringKind: .literalSelection, rewriteEnvelope: point.utf8Range, conflictKeys: [])
    }

    /// One file's own compilation-unit identity — computed upfront, before
    /// any splicing, since (unlike the chunk-level `sourceEmbeddingID`
    /// derived below) `CompilationUnitID.derive` depends only on project/
    /// target/module/path/lowerer identity, never on generated content, so
    /// there is no ordering hazard in knowing it before the file's own
    /// call-site text is generated.
    private struct FileUnit {
        let path: String
        let compilationUnitID: CompilationUnitID
        var suffix: String { String(compilationUnitID.rawValue.prefix(12)) }
    }

    /// One file's pass-1 splice result — its own descriptor identity
    /// alongside the spliced (preamble-free) content and entries, so pass 2
    /// never has to recompute `unit` from scratch (and risk it drifting
    /// from what the call sites in `content` actually reference).
    private struct SplicedFile {
        let content: String
        let entries: [SchemataPlanEntry]
        let unit: FileUnit
    }

    public func lower(_ chunk: SchemataChunk, sources: [SchemataSourceFile]) throws -> SchemataProgram {
        let indexedPointsByFile = try Self.validateAndAssignTokens(chunk, sources: sources)
        // Deterministic across every sibling chunk of the same target,
        // since `sources` is always that target's *full* file set — see
        // `sharedDeclarationPreamble`'s doc comment.
        guard let declarationFilePath = sources.map(\.relativePath).min() else {
            throw SchemataLoweringError.emptyChunk
        }

        // Pass 1: splice every file's mutations with no preamble text at
        // all yet — the call sites reference their own file's descriptor
        // variable by name (via `FileUnit.suffix`, known upfront), but the
        // chunk-level `sourceEmbeddingID` computed right after this pass
        // must describe the mutation content itself, never a hash that
        // would have to include its own literal.
        var splicedByFile: [String: SplicedFile] = [:]
        for source in sources {
            guard let filePoints = indexedPointsByFile[source.relativePath], !filePoints.isEmpty else { continue }
            let unit = FileUnit(
                path: source.relativePath,
                compilationUnitID: CompilationUnitID.derive(
                    projectIdentity: chunk.projectIdentity, target: chunk.target, module: chunk.module,
                    sourcePath: source.relativePath, lowererID: Self.lowererID, lowererVersion: Self.lowererVersion
                )
            )
            let (content, entries) = try Self.splice(source, filePoints: filePoints, chunk: chunk, unit: unit)
            splicedByFile[source.relativePath] = SplicedFile(content: content, entries: entries, unit: unit)
        }

        let allEntries = splicedByFile.values.flatMap(\.entries)
        Self.assertInvariants(entries: allEntries, chunk: chunk)

        let sourceEmbeddingID = Self.deriveSourceEmbeddingID(
            chunk: chunk,
            splicedContents: sources.map { ($0.relativePath, splicedByFile[$0.relativePath]?.content ?? $0.contents) },
            entries: allEntries
        )

        // Pass 2: assemble each file's final content — shared declarations
        // (exactly one file), this file's own descriptor registration (every
        // file with mutations, now that `sourceEmbeddingID` is known), then
        // the spliced body.
        var loweredSources: [SchemataSourceFile] = []
        var finalEntries: [SchemataPlanEntry] = []
        for source in sources {
            let spliced = splicedByFile[source.relativePath]
            var preamble = ""
            if source.relativePath == declarationFilePath {
                preamble += Self.sharedDeclarationPreamble
            }
            if let spliced {
                preamble += Self.descriptorPreamble(
                    suffix: spliced.unit.suffix, sourceEmbeddingID: sourceEmbeddingID,
                    compilationUnitID: spliced.unit.compilationUnitID.rawValue
                )
            }

            let body = spliced?.content ?? source.contents
            let content = preamble.isEmpty ? body : preamble + body
            loweredSources.append(
                SchemataSourceFile(
                    relativePath: source.relativePath, contents: content,
                    prependedLineCount: preamble.count { $0 == "\n" }
                )
            )
            if let spliced {
                finalEntries.append(contentsOf: spliced.entries.map { $0.withSourceEmbeddingID(sourceEmbeddingID) })
            }
        }

        return SchemataProgram(
            chunkID: chunk.chunkID, sourceEmbeddingID: sourceEmbeddingID, loweredSources: loweredSources, entries: finalEntries
        )
    }

    /// Every check `lower(_:sources:)` runs before committing to any byte,
    /// as the last line of defense against a chunk-planner bug: the chunk
    /// is non-empty and small enough for a dense `UInt32` token space, every
    /// point belongs to this lowerer's own operator, no `MutationID` or
    /// source path repeats, every touched file was actually supplied, and
    /// no two points in the same file claim overlapping byte ranges.
    /// Returns points grouped by file, each carrying the dense, namespace-
    /// qualified selector token it will be embedded under.
    private static func validateAndAssignTokens(
        _ chunk: SchemataChunk,
        sources: [SchemataSourceFile]
    ) throws -> [String: [(point: MutationPoint, token: SchemataSelectorToken)]] {
        guard !chunk.points.isEmpty else { throw SchemataLoweringError.emptyChunk }
        guard chunk.points.count < UInt32.max else {
            throw SchemataLoweringError.tooManyMutations(count: chunk.points.count)
        }
        for point in chunk.points where point.operatorID != BoolLiteralInversionOperator.descriptor.id {
            throw SchemataLoweringError.unsupportedOperator(operatorID: point.operatorID)
        }

        var seenMutationIDs: Set<MutationID> = []
        for point in chunk.points {
            guard seenMutationIDs.insert(point.id).inserted else {
                throw SchemataLoweringError.duplicateMutationID(point.id)
            }
        }

        var seenSourcePaths: Set<String> = []
        for source in sources {
            guard seenSourcePaths.insert(source.relativePath).inserted else {
                throw SchemataLoweringError.duplicateSourcePath(source.relativePath)
            }
        }

        // Dense, deterministic per-chunk local indices — 1-based, `0`
        // reserved as `SchemataSelectorToken`'s inactive sentinel — sorted
        // by `MutationID` so two independently-produced lowerings of the
        // same chunk assign identical tokens regardless of discovery or
        // chunking order. Carried alongside each point from here on (never
        // re-looked-up by ID), so there is no dictionary-miss case to
        // silently paper over.
        let indexedPoints = chunk.points.sorted { $0.id < $1.id }.enumerated()
            .map { (point: $1, token: SchemataSelectorToken(namespace: chunk.namespace, localIndex: UInt32($0 + 1))) }
        let indexedPointsByFile = Dictionary(grouping: indexedPoints, by: { $0.point.file })

        for (file, filePoints) in indexedPointsByFile {
            guard sources.contains(where: { $0.relativePath == file }) else {
                throw SchemataLoweringError.missingSource(file: file)
            }
            if let (first, second) = Self.firstOverlap(among: filePoints.map(\.point)) {
                throw SchemataLoweringError.overlappingRewriteEnvelopes(file: file, first: first, second: second)
            }
        }

        return indexedPointsByFile
    }

    /// Splices one file's mutations only — verifies every anchor against
    /// the file's original bytes, splices in descending byte-offset order
    /// (so a later splice never shifts an as-yet-unverified anchor), and
    /// returns the spliced (preamble-free) body plus its `SchemataPlanEntry`s
    /// — each `.embedded` placement's `sourceEmbeddingID` still a
    /// placeholder, filled in once the whole chunk's embedding identity is
    /// known. Every generated call site references `unit`'s own descriptor
    /// variable by name (`lower(_:sources:)`'s pass 2 is what actually
    /// prepends the declaration that defines it).
    private static func splice(
        _ source: SchemataSourceFile,
        filePoints: [(point: MutationPoint, token: SchemataSelectorToken)],
        chunk: SchemataChunk,
        unit: FileUnit
    ) throws -> (content: String, entries: [SchemataPlanEntry]) {
        let originalData = Data(source.contents.utf8)
        for (point, _) in filePoints {
            let verification = SourceAnchorVerifier.verify(point, against: originalData, depth: .full)
            guard verification.isValid else {
                throw SchemataLoweringError.anchorRejected(mutationID: point.id, diagnosis: verification.diagnosis)
            }
        }

        var bytes = [UInt8](originalData)
        for (point, token) in filePoints.sorted(by: { $0.point.utf8Range.start > $1.point.utf8Range.start }) {
            let replacement = "(__mutantkitIsActiveV3(__mutantkitUnitDescriptor_\(unit.suffix), " +
                "\(token.namespace), \(token.localIndex)) ? \(point.replacementText) : \(point.originalText))"
            bytes.replaceSubrange(point.utf8Range.range, with: Array(replacement.utf8))
        }

        let splicedContent = String(decoding: bytes, as: UTF8.self)
        let entries = filePoints.map { point, token in
            SchemataPlanEntry(
                mutationID: point.id,
                // A lowerer only ever produces single-placement entries —
                // one target per `lower(_:sources:)` call, since `chunk`
                // itself always describes one target's own build.
                // `SchemataChunkPlanner.plan` merges a mutation's several
                // single-placement entries (once per target its file
                // belongs to) into one multi-placement entry via
                // `SchemataPlanEntry.merged(_:)` before persisting the
                // final `SchemataPlan`. `sourceEmbeddingID` is a
                // placeholder here — not knowable until every file in the
                // chunk has been lowered — `lower(_:sources:)` replaces it
                // via `withSourceEmbeddingID` before returning.
                placement: .embedded(placements: [
                    SchemataEmbeddedPlacement(
                        chunkID: chunk.chunkID, selectorToken: token, sourceEmbeddingID: "",
                        lowererID: lowererID, lowererVersion: lowererVersion,
                        projectIdentity: chunk.projectIdentity, target: chunk.target,
                        module: chunk.module, product: chunk.product, expectedImages: []
                    )
                ]),
                conflictGroup: nil,
                projectIdentity: chunk.projectIdentity,
                target: chunk.target,
                module: chunk.module,
                product: chunk.product
            )
        }
        return (splicedContent, entries)
    }

    /// Last line of defense: every point produced exactly one entry, and no
    /// two entries share an identity. A failure here means this type's own
    /// logic has a bug, not the chunk planner's — but the same fail-closed
    /// discipline applies regardless of which side a defect originates on.
    private static func assertInvariants(entries: [SchemataPlanEntry], chunk: SchemataChunk) {
        guard entries.count == chunk.points.count else {
            preconditionFailure("lower() produced \(entries.count) entries for \(chunk.points.count) points")
        }
        guard Set(entries.map(\.mutationID)).count == entries.count else {
            preconditionFailure("lower() produced duplicate mutationIDs")
        }
        guard Set(entries.map(\.selectorToken)).count == entries.count else {
            preconditionFailure("lower() produced duplicate selector tokens")
        }
    }

    /// The first pair (in ascending byte-offset order) of overlapping — or
    /// identical — rewrite envelopes among `points`, `nil` if none overlap.
    /// A running-max-end sweep, not a merely-adjacent-pair check: three
    /// points where the first fully contains the third, but the second
    /// (sorted between them) touches neither, still needs the first/third
    /// pair caught even though they are not adjacent after sorting.
    private static func firstOverlap(among points: [MutationPoint]) -> (MutationID, MutationID)? {
        let sorted = points.sorted { $0.utf8Range.start < $1.utf8Range.start }
        guard var runningMaxEnd = sorted.first?.utf8Range.end, var runningMaxPoint = sorted.first else { return nil }
        for point in sorted.dropFirst() {
            if point.utf8Range.start < runningMaxEnd {
                return (runningMaxPoint.id, point.id)
            }
            if point.utf8Range.end > runningMaxEnd {
                runningMaxEnd = point.utf8Range.end
                runningMaxPoint = point
            }
        }
        return nil
    }

    /// An explicit, ordered, delimited preimage — same discipline
    /// `SchemataPlan`'s own `schemataPlanID` derivation uses, including the
    /// same full-SHA-256 (never truncated) choice: this is a trust-boundary
    /// identity a build cache keys on, not a human-facing label, so a
    /// collision must not silently reuse the wrong cached embedding. Covers
    /// everything available at lowering time that actually affects this
    /// chunk's build output: the runtime ABI and lowerer identity/version
    /// the generated call sites depend on, the chunk's own
    /// target/module/product, every file's *spliced* content, and the
    /// token each embedded mutation was assigned. Deliberately hashes the
    /// spliced-but-preamble-free body, not `loweredSources`' final content
    /// (which for a file with mutations already contains this very ID as a
    /// literal, once `lower(_:sources:)`'s pass 2 prepends it) — hashing
    /// the final content would make this a hash of its own embedded value.
    /// A build orchestrator threading in platform/toolchain/build-argument
    /// inputs (the same role `SchemataPlan.toolchainHash`/
    /// `buildArgumentsHash` already play at the plan level) must extend
    /// this further before using it as an actual build cache key — this
    /// alone covers what the lowerer itself can see, which is why it is
    /// called `sourceEmbeddingID`, not an "artifact ID".
    private static func deriveSourceEmbeddingID(
        chunk: SchemataChunk,
        splicedContents: [(path: String, content: String)],
        entries: [SchemataPlanEntry]
    ) -> String {
        let separator = "\u{1F}"
        let header = [
            String(runtimeABIVersion), lowererID, String(lowererVersion),
            chunk.target, chunk.module, chunk.product
        ]
        let sourceComponents = splicedContents.sorted { $0.path < $1.path }.map { path, content in
            [path, ContentHash.of(Data(content.utf8))].joined(separator: separator)
        }
        let tokenComponents = entries.sorted { $0.mutationID < $1.mutationID }.map { entry in
            [
                entry.mutationID.rawValue,
                entry.selectorToken.map { "\($0.namespace):\($0.localIndex)" } ?? ""
            ].joined(separator: separator)
        }
        // Pure 64-character hex, not `ContentHash.of`'s `"sha256:"`-prefixed
        // display form: this value is embedded as a literal `mutantkit_
        // register_unit_v3` argument (via `descriptorPreamble`), and the v3
        // runtime's `mutantkit_v3_decode_hex` requires exactly
        // `MUTANTKIT_V3_DIGEST_SIZE * 2` (64) hex characters — a 71-
        // character prefixed string fails that length check silently,
        // making every registration on this chunk fail closed to "never
        // active" with no visible error.
        return SHA256Digest.of((header + sourceComponents + tokenComponents).joined(separator: separator)).rawValue
    }
}
