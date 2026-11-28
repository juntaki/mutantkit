import MutationModel

/// Collapses points that propose the identical source edit — same file, byte
/// range and replacement text — into one, before the budget is spent.
///
/// Two operators can legitimately reach the same call (a generic
/// `SideEffectCallRemoval` and the specialized `ContinuationResumeRemoval`
/// both delete `cont.resume()`). Executing both would run one textual edit
/// twice and count it twice in the budget and the score.
///
/// Ownership is deterministic: within a group the point with the smallest
/// `(operatorID, id)` is canonical (lexicographic operator ID, so
/// `apple.concurrency.continuation-resume-removal` currently owns the edit
/// over `swift.core.side-effect-call-removal`; that is an ordering, not a
/// specialization rule). Per-operator counts shift accordingly when both are
/// enabled. Every other
/// point moves to the skipped ledger as `.duplicateEdit`, and its detail names
/// the canonical mutation and every contributing operator, so provenance is
/// kept without a new field on `MutationPoint`.
///
/// IDs are never recomputed: the pass runs after identity assignment, so every
/// surviving point keeps its v1 `MutationID`. A generic operator is not
/// excluded from a site the specialized one declined; only exact equality of
/// the edit collapses, so no eligibility is widened or narrowed.
enum ExactEditDeduplication {
    private struct EditKey: Hashable {
        let file: String
        let start: Int
        let end: Int
        let replacement: String
    }

    static func apply(
        to points: [MutationPoint],
        _ skipped: [SkippedMutation]
    ) -> ([MutationPoint], [SkippedMutation]) {
        let groups = Dictionary(grouping: points.indices) { index in
            let point = points[index]
            return EditKey(
                file: point.file, start: point.utf8Range.start, end: point.utf8Range.end,
                replacement: point.replacementText
            )
        }
        guard groups.values.contains(where: { $0.count > 1 }) else { return (points, skipped) }

        var dropped: Set<Int> = []
        var records: [SkippedMutation] = []
        for group in groups.values where group.count > 1 {
            let ordered = group.sorted {
                (points[$0].operatorID, points[$0].id, $0) < (points[$1].operatorID, points[$1].id, $1)
            }
            let canonical = points[ordered[0]]
            let operators = ordered.map { points[$0].operatorID }.joined(separator: ", ")
            for index in ordered.dropFirst() {
                let point = points[index]
                dropped.insert(index)
                records.append(SkippedMutation(
                    id: point.id,
                    file: point.file,
                    reason: .duplicateEdit,
                    detail: """
                    \(point.displayLocation): identical edit to \(canonical.id) \
                    (\(canonical.operatorID)); contributing operators: \(operators).
                    """,
                    operatorID: point.operatorID
                ))
            }
        }
        let kept = points.indices.filter { !dropped.contains($0) }.map { points[$0] }
        return (kept, skipped + records.sorted { $0.id < $1.id })
    }
}
