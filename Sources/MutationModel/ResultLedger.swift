
/// Anything a `ResultLedger` can hold — its own `mutationRef` *is* its
/// ledger key. No conforming type lets a caller supply a key independent
/// of the value being inserted, which is exactly what a plain
/// `ResultLedger<Key, Value>` (this type's first draft) allowed: a caller
/// could insert `value` under a `key` that disagreed with `value`'s own
/// `mutationRef`, silently misfiling a verdict under the wrong mutation's
/// identity. There is no scenario where that mismatch is ever correct, so
/// the type no longer expresses it.
public protocol MutationLedgerEntry: Sendable {
    var mutationRef: PlannedMutationRef { get }
}

extension VerifiedMutationRecord: MutationLedgerEntry {}
extension MultiTargetVerdict: MutationLedgerEntry {}
/// `MutationResult` (a verified projection — see its own doc comment) also
/// conforms directly: it carries the record's own `mutationRef` forward
/// from projection, so it is safe to use as a ledger entry with no
/// separate `VerifiedMutationRecord` kept alive alongside it.
extension MutationResult: MutationLedgerEntry {}

/// An insert-once collection of verified records, keyed by each entry's
/// own `mutationRef` — never a key the caller picks separately.
///
/// Replaces `[MutationResult]`/`[VerifiedMutationRecord]` arrays everywhere
/// a run accumulates a set of results (ADR-0006 Stage 1): a second insert
/// for the same key is a programming error, thrown at the point it
/// happens — not silently overwritten, not appended as a duplicate array
/// entry for `IntegrityChecker` to notice later by turning the array into
/// a `Set` and comparing sizes. That post-hoc check is deleted along with
/// this type's introduction; reconciliation against the plan (which
/// mutations exist with no result, which results exist with no plan
/// entry) is a different, still-real check `IntegrityChecker` keeps.
public struct ResultLedger<Entry: MutationLedgerEntry>: Sendable {
    public enum InsertError: Error, Equatable, CustomStringConvertible {
        case duplicateKey(String)

        public var description: String {
            switch self {
            case let .duplicateKey(key): "ResultLedger already has an entry for \(key) — a result may only be inserted once"
            }
        }
    }

    private var storage: [PlannedMutationRef: Entry] = [:]
    private var order: [PlannedMutationRef] = []

    public init() {}

    /// Inserts `entry` under `entry.mutationRef` — the only key this type
    /// ever uses. Throws `InsertError.duplicateKey` if that ref already
    /// has an entry — never overwrites, never silently accepts a second
    /// result for the same planned mutation.
    public mutating func insert(_ entry: Entry) throws {
        let ref = entry.mutationRef
        guard storage[ref] == nil else {
            throw InsertError.duplicateKey(ref.mutationID.rawValue)
        }
        storage[ref] = entry
        order.append(ref)
    }

    public func entry(for ref: PlannedMutationRef) -> Entry? { storage[ref] }
    public var count: Int { order.count }
    public var isEmpty: Bool { order.isEmpty }
    public var mutationRefs: [PlannedMutationRef] { order }
    public var mutationIDs: [MutationID] { order.map(\.mutationID) }
    /// In insertion order — callers that need a different order (e.g. by
    /// `MutationID`) sort this themselves.
    public var entries: [Entry] { order.map { storage[$0]! } }
}
