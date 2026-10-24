import Foundation
import MutationModel
import SwiftFrontend
import SwiftSyntax

/// Embeds `swift.core.nil-coalescing-fallback` points (`a ?? b` → `b`) into a
/// schema binary.
///
/// The operator anchors its `MutationPoint` to the whole folded
/// `InfixOperatorExprSyntax`, with `replacementText` the fallback `b` and
/// `originalText` the whole expression: the same single-node, verbatim-text
/// shape `TernaryBranchSwapSchemataLowerer` has, lowered to
/// `(selector ? (b) : (a ?? b))`.
///
/// Unlike the operand-duplicating lowerers there is nothing to prove about
/// evaluation: the mutated arm evaluates only `b`, exactly what the isolated
/// mutant does (`a` is dropped with the `??`), and the original arm evaluates
/// `a ?? b` untouched, so each runs once, in its original order, whatever `a`
/// and `b` are. Only `b`'s *text* is duplicated, which costs compile time and
/// nothing else. What stays isolated is therefore limited to places where the
/// rewrite is not a plain expression substitution: result-builder bodies,
/// loop conditions, a `try`/`await` that covers the whole expression, and a
/// `try`/`await` inside either operand.
public struct NilCoalescingFallbackSchemataLowerer: SchemataLowerer {
    public static let lowererID = "swift.core.nil-coalescing-fallback.schemata"
    public static let lowererVersion = 1
    public static let runtimeABIVersion = BoolLiteralSchemataLowerer.runtimeABIVersion

    public let descriptor = SchemataLowererDescriptor(
        lowererID: lowererID, lowererVersion: lowererVersion, runtimeABIVersion: runtimeABIVersion,
        supportedOperatorIDs: [NilCoalescingFallbackOperator.descriptor.id]
    )

    public init() {}

    // MARK: - Eligibility

    public func analyze(_ point: MutationPoint, source: Data) -> SchemataEligibility {
        guard point.operatorID == NilCoalescingFallbackOperator.descriptor.id else {
            return .isolatedOnly(reason: .operatorNotYetLowered(operatorID: point.operatorID))
        }

        let verification = SourceAnchorVerifier.verify(point, against: source, depth: .full)
        guard verification.isValid else {
            return .isolatedOnly(reason: .structuralConflict(reason: verification.diagnosis))
        }
        guard let node = SourceAnchorVerifier.matchedNode(for: point, in: source),
              let infix = node.as(InfixOperatorExprSyntax.self)
        else {
            return .isolatedOnly(reason: .structuralConflict(reason: "no InfixOperatorExprSyntax resolved at the anchor"))
        }
        guard !OperatorExclusions.isInsideResultBuilderBody(Syntax(infix)) else {
            return .isolatedOnly(reason: .resultBuilderBody)
        }
        guard !OperatorExclusions.isInsideLoopConditionExpressionTree(Syntax(infix)) else {
            return .isolatedOnly(reason: .controlFlowConstant)
        }
        if Self.isDirectlyWrappedInTryOrAwait(infix) || Self.containsTryOrAwait(infix) {
            return .isolatedOnly(reason: .asyncOrThrowingExpression)
        }

        return .eligible(loweringKind: .expressionTernary, rewriteEnvelope: point.utf8Range, conflictKeys: [])
    }

    private static func containsTryOrAwait(_ infix: InfixOperatorExprSyntax) -> Bool {
        final class Finder: SyntaxVisitor {
            var found = false
            override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }

            override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
                found = true
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(infix)
        return finder.found
    }

    private static func isDirectlyWrappedInTryOrAwait(_ infix: InfixOperatorExprSyntax) -> Bool {
        var current = Syntax(infix)
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
}

// MARK: - Lowering

extension NilCoalescingFallbackSchemataLowerer {
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
        for point in chunk.points where point.operatorID != NilCoalescingFallbackOperator.descriptor.id {
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
