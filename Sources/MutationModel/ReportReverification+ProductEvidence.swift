import Foundation

/// Report-only checks that tie a result's recorded hashes and diff to the
/// plan's point and to the report's own baseline. They compare stored facts
/// with each other; none of them judges a verdict.
extension ReportReverifier {
    /// Outcomes whose evidence records an isolated build product.
    private static func recordsBuildProduct(_ outcome: MutationOutcome) -> Bool {
        switch outcome {
        case .killedByAssertion, .killedByCrash, .survived:
            true
        default:
            false
        }
    }

    /// The recorded build-product hash must be the one the activation proof
    /// names, and that proof must be about this report's baseline. A product
    /// equal to the baseline's is a phantom (the identical-product guard) and
    /// can never stand behind a kill or a survivor.
    static func buildProductFindings(_ result: MutationResult, baselineHash: String?) -> [Finding] {
        guard recordsBuildProduct(result.outcome),
              case let .isolated(activation)? = result.evidence?.applicationEvidence,
              case let .buildProductDiffersFromBaseline(mutantHash, activationBaseline) = activation,
              activation.provesActivation
        else { return [] }
        let id = result.id.rawValue
        let name = "evidence.buildProduct"
        guard let recorded = result.evidence?.buildProductHash else {
            return [Finding(
                name: name, status: .notVerifiable, mutationID: id,
                reason: "no build product hash is recorded to compare with its activation proof"
            )]
        }
        if recorded != mutantHash {
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "its recorded build product hash is not the one its activation proof names"
            )]
        }
        guard let baselineHash else {
            return [Finding(
                name: name, status: .notVerifiable, mutationID: id,
                reason: "the report records no baseline build product hash to compare it with"
            )]
        }
        if recorded == baselineHash {
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "\(result.outcome.rawValue) but its build product is identical to the baseline's"
            )]
        }
        if activationBaseline != baselineHash {
            return [Finding(
                name: name, status: .fail, mutationID: id,
                reason: "its activation proof compares against a different baseline build product than the report's"
            )]
        }
        return [Finding(name: name, status: .pass, mutationID: id, reason: "")]
    }

    /// The stored diff must be the edit the point describes: its file, and
    /// the original and replacement text on its removed and added lines.
    static func sourceDiffFindings(_ result: MutationResult) -> [Finding] {
        guard requiresSourceApplication(result.outcome), let evidence = result.evidence, evidence.provesSourceApplication else {
            return []
        }
        let id = result.id.rawValue
        let name = "evidence.sourceDiff"
        let point = result.point
        let lines = evidence.sourceDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func firstLine(_ text: String) -> String? {
            text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        }
        guard lines.contains("--- a/\(point.file)"), lines.contains("+++ b/\(point.file)") else {
            return [Finding(name: name, status: .fail, mutationID: id, reason: "its diff is not for the point's file")]
        }
        if let original = firstLine(point.originalText),
           !lines.contains(where: { $0.hasPrefix("-") && $0 != "--- a/\(point.file)" && $0.contains(original) }) {
            return [Finding(name: name, status: .fail, mutationID: id, reason: "its diff does not remove the point's original text")]
        }
        if let replacement = firstLine(point.replacementText),
           !lines.contains(where: { $0.hasPrefix("+") && $0 != "+++ b/\(point.file)" && $0.contains(replacement) }) {
            return [Finding(name: name, status: .fail, mutationID: id, reason: "its diff does not add the point's replacement text")]
        }
        return [Finding(name: name, status: .pass, mutationID: id, reason: "")]
    }
}
