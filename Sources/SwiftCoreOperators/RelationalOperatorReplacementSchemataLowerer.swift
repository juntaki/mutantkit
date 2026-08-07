import Foundation
import MutationModel
import SwiftFrontend
import SwiftSyntax

/// The exact replacement `RelationalOperatorReplacementOperator` itself
/// generates — the isolated operator's own `replacements` table is the
/// single source of truth for which operator maps to which; this type only
/// mirrors it far enough to assert the mirror never drifts (see
/// `RelationalOperatorReplacementSchemataLowererTests
/// .isolatedAndSchemataAgreeOnEveryVariant`). Never hand-written as an
/// independent table for schemata's own use.
public struct RelationalMutationVariant: Codable, Hashable, Sendable {
    public let originalOperator: String
    public let replacementOperator: String

    public init(originalOperator: String, replacementOperator: String) {
        self.originalOperator = originalOperator
        self.replacementOperator = replacementOperator
    }
}

/// Embeds `swift.core.relational-operator-replacement` points into a schema
/// binary — behind a closed scoring gate (see `SchemataLowererRegistry
/// .builtIn`'s own doc comment: this type is never listed there yet, so it
/// is never reached by `SchemataChunkPlanner` in production, only exercised
/// directly by this file's own tests). Implemented so that when the gate
/// does open, no lowering logic is left to write under time pressure.
///
/// Unlike `BoolLiteralSchemataLowerer`'s `.literalSelection` shape (replace
/// one literal with another of the identical type — no risk to operand
/// evaluation, since there are no operands), a relational comparison's
/// `lhs`/`rhs` must each be evaluated *exactly once* regardless of which
/// operator (original or replacement) ends up selected. A naive
/// `isActive(token) ? lhs <= rhs : lhs < rhs` expansion duplicates `lhs`
/// and `rhs` textually — if either has a side effect, is a function call,
/// or is otherwise not idempotent, this would double-evaluate it and
/// silently change the program's behavior even when the mutant is
/// *inactive*. This lowerer instead:
///
///   1. restricts eligibility (`analyze`) to operands syntactically
///      provable to be side-effect-free and idempotent — an identifier
///      reference, `self`, a simple (non-computed-property-risking) member
///      access chain, a literal, or a parenthesized safe expression, and
///      nothing else (no calls, subscripts, `await`, `try`, closures,
///      autoclosures, optional chaining, force-unwraps, macros, key paths,
///      or ownership-sensitive bindings — see `isSafeOperand`);
///   2. lowers to an immediately-invoked closure that binds each operand to
///      a local `let` exactly once, then selects between the two operator
///      applications against those locals — never against `lhs`/`rhs`
///      textually a second time.
public struct RelationalOperatorReplacementSchemataLowerer: SchemataLowerer {
    public static let lowererID = "swift.core.relational-operator-replacement.schemata"
    public static let lowererVersion = 1
    /// Same v3 runtime protocol `BoolLiteralSchemataLowerer` already uses —
    /// one shared runtime, not a second one invented for this operator.
    public static let runtimeABIVersion = BoolLiteralSchemataLowerer.runtimeABIVersion

    public let descriptor = SchemataLowererDescriptor(
        lowererID: lowererID, lowererVersion: lowererVersion, runtimeABIVersion: runtimeABIVersion,
        supportedOperatorIDs: [RelationalOperatorReplacementOperator.descriptor.id]
    )

    public init() {}

    // MARK: - Eligibility

    public func analyze(_ point: MutationPoint, source: Data) -> SchemataEligibility {
        guard point.operatorID == RelationalOperatorReplacementOperator.descriptor.id else {
            return .isolatedOnly(reason: .operatorNotYetLowered(operatorID: point.operatorID))
        }

        let verification = SourceAnchorVerifier.verify(point, against: source, depth: .full)
        guard verification.isValid else {
            return .isolatedOnly(reason: .structuralConflict(reason: verification.diagnosis))
        }
        guard let resolved = Self.resolveInfix(for: point, in: source) else {
            return .isolatedOnly(reason: .structuralConflict(reason: "no InfixOperatorExprSyntax parent resolved at the anchor"))
        }
        guard !OperatorExclusions.isInsideResultBuilderBody(Syntax(resolved.infix)) else {
            return .isolatedOnly(reason: .resultBuilderBody)
        }
        // `try`/`await` can wrap the *whole* comparison (`try (a < throwingB())`)
        // rather than sitting inside either operand — an operand-only check
        // would miss that shape. Checked here, at the infix level, in
        // addition to (never instead of) each operand's own check below,
        // which still catches the far more common case of a throwing/
        // awaiting call as one of the operands themselves.
        if Self.isDirectlyWrappedInTryOrAwait(resolved.infix) {
            return .isolatedOnly(reason: .asyncOrThrowingExpression)
        }
        if let reason = Self.unsafetyReason(for: resolved.infix.leftOperand) {
            return .isolatedOnly(reason: reason)
        }
        if let reason = Self.unsafetyReason(for: resolved.infix.rightOperand) {
            return .isolatedOnly(reason: reason)
        }

        let envelope = ByteRange(
            start: resolved.infix.positionAfterSkippingLeadingTrivia.utf8Offset,
            end: resolved.infix.endPositionBeforeTrailingTrivia.utf8Offset
        )
        return .eligible(loweringKind: .expressionTernary, rewriteEnvelope: envelope, conflictKeys: [])
    }

    /// Resolves `point`'s operator-token anchor to its enclosing
    /// `InfixOperatorExprSyntax` — the operator token alone (what
    /// `MutationPoint.utf8Range` anchors to) carries no operand
    /// information; the infix parent is where `leftOperand`/`rightOperand`
    /// live. Re-parses from `source` fresh — never reuses a tree from an
    /// earlier call, the same discipline `SourceAnchorVerifier` itself
    /// applies, so a stale tree can never be mistaken for a fresh one.
    private static func resolveInfix(for point: MutationPoint, in source: Data) -> (infix: InfixOperatorExprSyntax, operatorNode: Syntax)? {
        guard let operatorNode = SourceAnchorVerifier.matchedNode(for: point, in: source),
              let infix = operatorNode.parent?.as(InfixOperatorExprSyntax.self)
        else { return nil }
        return (infix, operatorNode)
    }

    /// `nil` when `operand` is safe to evaluate a second time (bind to a
    /// local exactly once and reference the local twice, never the
    /// original expression text twice) — the specific hazard this lowering
    /// exists to never introduce. Deliberately conservative: an operand
    /// kind not explicitly recognized here falls back to isolated, never
    /// assumed safe.
    private static func unsafetyReason(for operand: ExprSyntax) -> SchemataUnsupportedReason? {
        let unwrapped = Self.unwrapParentheses(operand)

        if let sequence = unwrapped.as(SequenceExprSyntax.self) {
            // A folded tree should never actually contain an un-folded
            // SequenceExprSyntax at this point (the parser output was
            // already run through `SyntaxFolding.fold` before `analyze`
            // ever sees it) — treated as unsafe rather than assumed
            // foldable, since trusting an unfolded sequence's shape here
            // would be exactly the kind of unproven assumption this
            // lowerer exists to avoid.
            return .structuralConflict(reason: "unexpected unfolded SequenceExprSyntax: \(sequence.trimmedDescription)")
        }
        if Self.isSafeLeafOperand(unwrapped) {
            return nil
        }
        if let member = unwrapped.as(MemberAccessExprSyntax.self) {
            // A member access chain is only safe if its own base is safe,
            // recursively — `a.b.c` is safe iff `a` is (a plain identifier
            // or `self`), and the access itself is a property/case
            // reference, never a call. `MemberAccessExprSyntax` alone
            // (no trailing `()`) can never be a function *call* — a call
            // is a distinct `FunctionCallExprSyntax` node wrapping it —
            // but the base could still itself be unsafe (e.g.
            // `foo().bar`), which recursion below catches.
            guard let base = member.base else {
                // An implicit-member `.foo` (base inferred from context) —
                // no operand to recurse into; the reference itself cannot
                // be a call or have a side effect.
                return nil
            }
            return Self.unsafetyReason(for: base)
        }
        return Self.unsafeOperandReason(for: unwrapped)
    }

    private static func isSafeLeafOperand(_ unwrapped: ExprSyntax) -> Bool {
        unwrapped.is(DeclReferenceExprSyntax.self) || unwrapped.is(IntegerLiteralExprSyntax.self)
            || unwrapped.is(FloatLiteralExprSyntax.self) || unwrapped.is(StringLiteralExprSyntax.self)
            || unwrapped.is(BooleanLiteralExprSyntax.self) || unwrapped.is(NilLiteralExprSyntax.self)
    }

    /// Every recognized-but-unsafe operand kind, and the conservative
    /// default reject for anything not recognized at all — split out of
    /// `unsafetyReason` purely to keep each function's branch count
    /// reviewable; the classification itself is unchanged.
    private static func unsafeOperandReason(for unwrapped: ExprSyntax) -> SchemataUnsupportedReason {
        if unwrapped.is(FunctionCallExprSyntax.self) {
            return .unsupportedOperand(reason: "function call operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(SubscriptCallExprSyntax.self) {
            return .unsupportedOperand(reason: "subscript operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(AwaitExprSyntax.self) || unwrapped.is(TryExprSyntax.self) {
            return .asyncOrThrowingExpression
        }
        if unwrapped.is(ClosureExprSyntax.self) {
            return .unsupportedOperand(reason: "closure operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(OptionalChainingExprSyntax.self) {
            return .unsupportedOperand(reason: "optional-chaining operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(ForceUnwrapExprSyntax.self) {
            return .unsupportedOperand(reason: "force-unwrap operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(MacroExpansionExprSyntax.self) {
            return .unsupportedOperand(reason: "macro-expansion operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(KeyPathExprSyntax.self) {
            return .unsupportedOperand(reason: "key-path operand: \(unwrapped.trimmedDescription)")
        }
        if unwrapped.is(InOutExprSyntax.self) {
            return .ownershipSensitiveExpression
        }
        // Anything else (ternary, array/dictionary literal, binary
        // expression, type expression, etc.) is not on the recognized-safe
        // list — conservatively rejected, never assumed safe by omission.
        return .unsupportedOperand(reason: "unrecognized operand kind \(unwrapped.kind): \(unwrapped.trimmedDescription)")
    }

    /// Whether `infix`'s own immediate parent chain (through parentheses
    /// only — never further, to avoid flagging an unrelated `try`
    /// somewhere earlier in the same statement) is a `try`/`await`
    /// expression directly wrapping this comparison.
    private static func isDirectlyWrappedInTryOrAwait(_ infix: InfixOperatorExprSyntax) -> Bool {
        var current = Syntax(infix)
        while let parent = current.parent {
            // A single-parenthesized expression `(...)` is three real
            // syntax levels, not one: `TupleExprSyntax` ->
            // `LabeledExprListSyntax` -> `LabeledExprSyntax` ->
            // `.expression`. All three are transparently skipped as "just
            // parentheses" here, the same way `unwrapParentheses` skips
            // them from the other direction (down into an operand).
            if parent.is(LabeledExprSyntax.self) || parent.is(LabeledExprListSyntax.self) {
                current = parent
                continue
            }
            if let tuple = parent.as(TupleExprSyntax.self), tuple.elements.count == 1, tuple.elements.first?.label == nil {
                current = parent
                continue
            }
            if parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) { return true }
            return false
        }
        return false
    }

    private static func unwrapParentheses(_ expr: ExprSyntax) -> ExprSyntax {
        var current = expr
        while let tuple = current.as(TupleExprSyntax.self), tuple.elements.count == 1, tuple.elements.first?.label == nil {
            current = tuple.elements.first!.expression
        }
        return current
    }
}

// MARK: - Lowering

//
// Split into its own extension (rather than continuing the struct body
// above) purely to keep `type_body_length` reviewable per declaration —
// still the same single type, same access level, no behavioral split.
extension RelationalOperatorReplacementSchemataLowerer {
    private struct FileUnit {
        let path: String
        let compilationUnitID: CompilationUnitID
        var suffix: String { String(compilationUnitID.rawValue.prefix(12)) }
    }

    private struct SplicedFile {
        let content: String
        let entries: [SchemataPlanEntry]
        let unit: FileUnit
    }

    public func lower(_ chunk: SchemataChunk, sources: [SchemataSourceFile]) throws -> SchemataProgram {
        let indexedPointsByFile = try Self.validateAndAssignTokens(chunk, sources: sources)
        guard let declarationFilePath = sources.map(\.relativePath).min() else {
            throw SchemataLoweringError.emptyChunk
        }

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

        var loweredSources: [SchemataSourceFile] = []
        var finalEntries: [SchemataPlanEntry] = []
        for source in sources {
            let spliced = splicedByFile[source.relativePath]
            var preamble = ""
            if source.relativePath == declarationFilePath {
                preamble += BoolLiteralSchemataLowerer.sharedDeclarationPreamble
            }
            if let spliced {
                preamble += BoolLiteralSchemataLowerer.descriptorPreamble(
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

    private static func validateAndAssignTokens(
        _ chunk: SchemataChunk, sources: [SchemataSourceFile]
    ) throws -> [String: [(point: MutationPoint, token: SchemataSelectorToken)]] {
        guard !chunk.points.isEmpty else { throw SchemataLoweringError.emptyChunk }
        guard chunk.points.count < UInt32.max else {
            throw SchemataLoweringError.tooManyMutations(count: chunk.points.count)
        }
        for point in chunk.points where point.operatorID != RelationalOperatorReplacementOperator.descriptor.id {
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

    /// Splices one file's mutations — unlike `BoolLiteralSchemataLowerer`,
    /// the byte range actually rewritten is the *whole infix expression*
    /// (`lhs op rhs`), not `point.utf8Range` (which anchors only to the
    /// operator token) — re-resolved fresh here, never trusted from
    /// `analyze`'s own earlier call, the same re-verification discipline
    /// `SourceAnchorVerifier` itself applies throughout this codebase.
    private static func splice(
        _ source: SchemataSourceFile, filePoints: [(point: MutationPoint, token: SchemataSelectorToken)],
        chunk: SchemataChunk, unit: FileUnit
    ) throws -> (content: String, entries: [SchemataPlanEntry]) {
        let originalData = Data(source.contents.utf8)

        var resolvedByPoint: [MutationID: (infix: InfixOperatorExprSyntax, range: ByteRange)] = [:]
        for (point, _) in filePoints {
            let verification = SourceAnchorVerifier.verify(point, against: originalData, depth: .full)
            guard verification.isValid else {
                throw SchemataLoweringError.anchorRejected(mutationID: point.id, diagnosis: verification.diagnosis)
            }
            guard let resolved = resolveInfix(for: point, in: originalData) else {
                throw SchemataLoweringError.anchorRejected(mutationID: point.id, diagnosis: "no InfixOperatorExprSyntax resolved at splice time")
            }
            let range = ByteRange(
                start: resolved.infix.positionAfterSkippingLeadingTrivia.utf8Offset,
                end: resolved.infix.endPositionBeforeTrailingTrivia.utf8Offset
            )
            resolvedByPoint[point.id] = (resolved.infix, range)
        }

        if let (first, second) = firstOverlap(among: filePoints.map { resolvedByPoint[$0.point.id]!.range }, ids: filePoints.map(\.point.id)) {
            throw SchemataLoweringError.overlappingRewriteEnvelopes(file: source.relativePath, first: first, second: second)
        }

        var bytes = [UInt8](originalData)
        for (point, token) in filePoints.sorted(by: { resolvedByPoint[$0.point.id]!.range.start > resolvedByPoint[$1.point.id]!.range.start }) {
            let (infix, range) = resolvedByPoint[point.id]!
            let lhsText = infix.leftOperand.trimmedDescription
            let rhsText = infix.rightOperand.trimmedDescription
            // Parenthesized as a whole `(...)`, not a bare `{ ... }()`: an
            // un-parenthesized immediately-invoked closure in `if`/`while`/
            // `guard` condition position parses as Swift's own trailing-
            // closure grammar instead, which fails to compile ("return
            // invalid outside of a func", "closure expression is unused")
            // — confirmed by a real compile failure in this lowerer's own
            // acceptance fixture before this was added, not assumed safe.
            //
            // `lhs`/`rhs` are bound via a local *generic* function
            // (`__mkPair<__MKPairT>(_ lhs: __MKPairT, _ rhs: __MKPairT) -> (__MKPairT, __MKPairT)`), not two
            // independent `let`s — real compile failure found via this
            // lowerer's own differential acceptance test: two independent
            // `let __mkLHS = (\(lhsText)); let __mkRHS = (\(rhsText))`
            // declarations each infer their own type in isolation, so a
            // comparison like `value >= 10` where `value: Decimal` and `10`
            // is only `Decimal` by *contextual* inference against `value`
            // loses that context — the untyped `let __mkRHS = (10)` defaults
            // to `Int`, and the mutated source no longer compiles ("`Decimal`
            // does not conform to `BinaryInteger`"). Passing both operands as
            // a single generic call forces Swift to unify `T` from the first
            // (already-concretely-typed) argument and coerce the second into
            // that same `T` — the same bidirectional inference a real binary
            // operator call itself uses — so `__mkRHS` ends up `Decimal` here
            // exactly as `10` would in the original, unmutated expression.
            // Each operand is still evaluated exactly once: function call
            // arguments evaluate once each, same guarantee as before.
            let replacement = """
            (\
            { () -> Bool in \
            func __mkPair<__MKPairT>(_ lhs: __MKPairT, _ rhs: __MKPairT) -> (__MKPairT, __MKPairT) { (lhs, rhs) }; \
            let (__mkLHS, __mkRHS) = __mkPair(\(lhsText), \(rhsText)); \
            return __mutantkitIsActiveV3(__mutantkitUnitDescriptor_\(unit.suffix), \(token.namespace), \(token.localIndex)) \
            ? (__mkLHS \(point.replacementText) __mkRHS) : (__mkLHS \(point.originalText) __mkRHS) \
            }()\
            )
            """
            bytes.replaceSubrange(range.range, with: Array(replacement.utf8))
        }

        let splicedContent = String(decoding: bytes, as: UTF8.self)
        let entries = filePoints.map { point, token in
            SchemataPlanEntry(
                mutationID: point.id,
                placement: .embedded(placements: [
                    SchemataEmbeddedPlacement(
                        chunkID: chunk.chunkID, selectorToken: token, sourceEmbeddingID: "",
                        lowererID: lowererID, lowererVersion: lowererVersion,
                        projectIdentity: chunk.projectIdentity, target: chunk.target,
                        module: chunk.module, product: chunk.product, expectedImages: []
                    )
                ]),
                conflictGroup: nil,
                projectIdentity: chunk.projectIdentity, target: chunk.target, module: chunk.module, product: chunk.product
            )
        }
        return (splicedContent, entries)
    }

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

    private static func firstOverlap(among points: [MutationPoint]) -> (MutationID, MutationID)? {
        firstOverlap(among: points.map(\.utf8Range), ids: points.map(\.id))
    }

    private static func firstOverlap(among ranges: [ByteRange], ids: [MutationID]) -> (MutationID, MutationID)? {
        let paired = zip(ranges, ids).sorted { $0.0.start < $1.0.start }
        guard var runningMaxEnd = paired.first?.0.end, var runningMaxID = paired.first?.1 else { return nil }
        for (range, id) in paired.dropFirst() {
            if range.start < runningMaxEnd {
                return (runningMaxID, id)
            }
            if range.end > runningMaxEnd {
                runningMaxEnd = range.end
                runningMaxID = id
            }
        }
        return nil
    }

    private static func deriveSourceEmbeddingID(
        chunk: SchemataChunk, splicedContents: [(path: String, content: String)], entries: [SchemataPlanEntry]
    ) -> String {
        let separator = "\u{1F}"
        let header = [String(runtimeABIVersion), lowererID, String(lowererVersion), chunk.target, chunk.module, chunk.product]
        let sourceComponents = splicedContents.sorted { $0.path < $1.path }.map { path, content in
            [path, ContentHash.of(Data(content.utf8))].joined(separator: separator)
        }
        let tokenComponents = entries.sorted { $0.mutationID < $1.mutationID }.map { entry in
            [entry.mutationID.rawValue, entry.selectorToken.map { "\($0.namespace):\($0.localIndex)" } ?? ""].joined(separator: separator)
        }
        return SHA256Digest.of((header + sourceComponents + tokenComponents).joined(separator: separator)).rawValue
    }
}
