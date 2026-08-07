import MutationModel

/// A shared work queue for `MutationRunner`'s incremental-build workers.
///
/// Plain array-slicing would divide the plan evenly by *count*, not by cost —
/// a worker that draws several slow mutants in a row would sit idle while a
/// worker that drew fast ones finishes early. Pulling from one shared queue
/// keeps every worker busy until the plan itself runs out, the same load
/// balancing the non-incremental path already gets for free from
/// `withThrowingTaskGroup`'s "one in, one out" refill.
///
/// When a worker identifies itself (`next(forWorker:)`), the queue also
/// biases its pick toward the same source file that worker last touched.
/// Each persistent sandbox keeps Swift's incremental compiler warm on one
/// file's module graph; handing the same worker another mutant in that file
/// is a one-file delta, while handing it a different file is a full re-entry
/// into that file's module graph. Two workers asking at the same time still
/// get different files — the bias only chooses *which* of the remaining
/// mutants this worker takes next, never blocks one from being taken.
public actor MutationQueue {
    // Stored reversed so `next()` can pop from the end — O(1) — instead of
    // `removeFirst()`'s O(n), which would make draining a large plan
    // quadratic.
    private var remaining: [MutationPoint]

    /// The last file each worker touched, so the next pull can prefer a
    /// mutant in the same file. Cleared implicitly when the worker's file
    /// has no remaining mutants — the next pull falls back to the
    /// highest-indexed remaining point and re-seeds the entry.
    private var workerLastFile: [String: String] = [:]

    public init(_ points: [MutationPoint]) {
        remaining = points.reversed()
    }

    /// Pops and returns the next point, preferring one from the same file
    /// this worker last touched when one is still available. The preference
    /// is a tie-breaker among remaining mutants, not a reservation: any
    /// mutant this worker does not take is still available to the next one.
    ///
    /// Falls back to the last remaining point (the front of the original
    /// plan, cheapest to pop) when no same-file mutant is left, and re-seeds
    /// `workerLastFile` from whatever was actually returned so the next call
    /// is biased correctly.
    public func next(forWorker workerID: String) -> MutationPoint? {
        if let preferred = workerLastFile[workerID],
           let index = remaining.lastIndex(where: { $0.file == preferred }) {
            let point = remaining.remove(at: index)
            workerLastFile[workerID] = point.file
            return point
        }
        let point = remaining.popLast()
        if let point {
            workerLastFile[workerID] = point.file
        }
        return point
    }

    /// Pops and returns the next point with no affinity — the drain path a
    /// worker uses when it never got its sandbox open and is reporting every
    /// remaining mutant as `.infrastructureFailure`. There is no locality to
    /// exploit in that path: the worker's sandbox never compiled anything,
    /// so the order it drains in is irrelevant to throughput.
    public func next() -> MutationPoint? {
        remaining.popLast()
    }
}
