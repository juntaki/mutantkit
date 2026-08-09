import Foundation
import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Embeds `swift.core.unary-not-removal` points into a schema binary —
/// behind a closed scoring gate (see `SchemataLowererRegistry.builtIn`'s own
/// doc comment: this type is never listed there yet, so it is never reached
/// by `SchemataChunkPlanner` in production, only exercised directly by this
/// file's own tests).
///
/// Structurally simpler than `RelationalOperatorReplacementSchemataLowerer`/
/// `LogicalConnectorReplacementSchemataLowerer`: `!x` -> `x` has one operand,
/// not two, and — unlike those two infix lowerers, whose `MutationPoint`
/// anchors only the operator token and needs re-resolving to the enclosing
/// `InfixOperatorExprSyntax` to find the real rewrite envelope —
/// `UnaryNotRemovalOperator` anchors its `MutationPoint` to the *whole*
/// `PrefixOperatorExprSyntax` (`!x`) already, exactly the same shape
/// `BoolLiteralSchemataLowerer` has for its own single-node literal anchor.
/// `point.utf8Range` is already the correct rewrite envelope; no parent
/// lookup needed. `point.originalText`/`point.replacementText` are used
/// verbatim in the lowered ternary, same as `BoolLiteralSchemataLowerer`
/// does, rather than reconstructed from an operand pair.
///
/// Still needs the one thing `BoolLiteralSchemataLowerer` never had to
/// worry about: an operand. `x` appears twice in the lowered source text
/// (once per ternary branch: `x` and `!x`), so `analyze` restricts
/// eligibility to operands syntactically provable to be side-effect-free
/// and idempotent — same conservative operand-safety analysis ROR's and
/// logical-connector's lowerers already apply, since only one of the two
/// textual copies ever actually evaluates at runtime (Swift's `?:` only
/// evaluates its selected branch) but a re-evaluation hazard would exist if
/// that were ever untrue.
public struct UnaryNotRemovalSchemataLowerer: SchemataLowerer {
    public static let lowererID = "swift.core.unary-not-removal.schemata"
    public static let lowererVersion = 1
    /// Same v3 runtime protocol every other lowerer uses.
    public static let runtimeABIVersion = BoolLiteralSchemataLowerer.runtimeABIVersion

    public let descriptor = SchemataLowererDescriptor(
        lowererID: lowererID, lowererVersion: lowererVersion, runtimeABIVersion: runtimeABIVersion,
        supportedOperatorIDs: [UnaryNotRemovalOperator.descriptor.id]
    )

    public init() {}

    // MARK: - Eligibility

    public func analyze(_ point: MutationPoint, source: Data) -> SchemataEligibility {
        guard point.operatorID == UnaryNotRemovalOperator.descriptor.id else {
            return .isolatedOnly(reason: .operatorNotYetLowered(operatorID: point.operatorID))
        }

        let verification = SourceAnchorVerifier.verify(point, against: source, depth: .full)
        guard verification.isValid else {
            return .isolatedOnly(reason: .structuralConflict(reason: verification.diagnosis))
        }
        guard let node = SourceAnchorVerifier.matchedNode(for: point, in: source),
              let prefix = node.as(PrefixOperatorExprSyntax.self)
        else {
            return .isolatedOnly(reason: .structuralConflict(reason: "no PrefixOperatorExprSyntax resolved at the anchor"))
        }
        guard !OperatorExclusions.isInsideResultBuilderBody(Syntax(prefix)) else {
            return .isolatedOnly(reason: .resultBuilderBody)
        }
        if Self.isDirectlyWrappedInTryOrAwait(prefix) {
            return .isolatedOnly(reason: .asyncOrThrowingExpression)
        }
        if let reason = Self.unsafetyReason(for: prefix.expression) {
            return .isolatedOnly(reason: reason)
        }

        return .eligible(loweringKind: .expressionTernary, rewriteEnvelope: point.utf8Range, conflictKeys: [])
    }

    /// `nil` when `operand` is safe to reference twice in lowered source
    /// text. Same recognized-safe set ROR's/logical-connector's lowerers
    /// use: an identifier, `self`, a literal, a safe member-access chain
    /// (recursively), or a parenthesized wrapping of one of those — anything
    /// else falls back to isolated, never assumed safe by omission.
    private static func unsafetyReason(for operand: ExprSyntax) -> SchemataUnsupportedReason? {
        let unwrapped = Self.unwrapParentheses(operand)

        if let sequence = unwrapped.as(SequenceExprSyntax.self) {
            return .structuralConflict(reason: "unexpected unfolded SequenceExprSyntax: \(sequence.trimmedDescription)")
        }
        if Self.isSafeLeafOperand(unwrapped) {
            return nil
        }
        if let member = unwrapped.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return nil }
            return Self.unsafetyReason(for: base)
        }
        // A nested `!` (`!(!flag)`) is itself a distinct, independently-
        // discovered mutation site — safe to reference twice in *this*
        // site's lowered text only if its own operand is, which recursion
        // proves the same way member-access bases are proven above.
        if let nestedPrefix = unwrapped.as(PrefixOperatorExprSyntax.self) {
            return Self.unsafetyReason(for: nestedPrefix.expression)
        }
        return Self.unsafeOperandReason(for: unwrapped)
    }

    private static func isSafeLeafOperand(_ unwrapped: ExprSyntax) -> Bool {
        unwrapped.is(DeclReferenceExprSyntax.self) || unwrapped.is(IntegerLiteralExprSyntax.self)
            || unwrapped.is(FloatLiteralExprSyntax.self) || unwrapped.is(StringLiteralExprSyntax.self)
            || unwrapped.is(BooleanLiteralExprSyntax.self) || unwrapped.is(NilLiteralExprSyntax.self)
    }

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
        return .unsupportedOperand(reason: "unrecognized operand kind \(unwrapped.kind): \(unwrapped.trimmedDescription)")
    }

    private static func isDirectlyWrappedInTryOrAwait(_ prefix: PrefixOperatorExprSyntax) -> Bool {
        var current = Syntax(prefix)
        while let parent = current.parent {
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
// Split into its own extension purely to keep `type_body_length`
// reviewable per declaration — same discipline as the other lowerers.
extension UnaryNotRemovalSchemataLowerer {
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
        for point in chunk.points where point.operatorID != UnaryNotRemovalOperator.descriptor.id {
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

    private static func splice(
        _ source: SchemataSourceFile, filePoints: [(point: MutationPoint, token: SchemataSelectorToken)],
        chunk: SchemataChunk, unit: FileUnit
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
            // Both branches are provably Bool regardless of which the
            // selector picks — same reasoning `BoolLiteralSchemataLowerer`
            // relies on, extended here to a removed-negation expression
            // rather than a literal token.
            let replacement = "(__mutantkitIsActiveV3(__mutantkitUnitDescriptor_\(unit.suffix), " +
                "\(token.namespace), \(token.localIndex)) ? (\(point.replacementText)) : (\(point.originalText)))"
            bytes.replaceSubrange(point.utf8Range.range, with: Array(replacement.utf8))
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
