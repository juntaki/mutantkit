import MutationExecution
import MutationModel
import SwiftFrontend
import Testing

/// Unit tests for `MutationQueue`'s worker-affinity scheduling: when a
/// worker identifies itself, it is preferentially handed another mutant in
/// the same source file, because its persistent sandbox's incremental
/// compiler has already parsed that file's module graph once. The
/// non-affinity `next()` drain path is also covered, since that is what
/// an incremental worker uses to report every remaining mutant as
/// `.infrastructureFailure` when its own sandbox never opened.
@Suite("Mutation queue: worker affinity")
struct MutationQueueAffinityTests {
    private func point(_ file: String, _ line: Int) -> MutationPoint {
        MutationPoint(
            id: MutationID(rawValue: "mut_\(file)_\(line)"),
            file: file,
            enclosingDeclaration: DeclarationIdentity(path: ["Test/test"]),
            operatorID: "op",
            operatorVersion: 1,
            occurrenceIndex: 0,
            utf8Range: ByteRange(0 ..< 1),
            originalText: "x",
            replacementText: "y",
            prefixTokenFingerprint: "pre",
            suffixTokenFingerprint: "post",
            sourceFileHash: "hash",
            expectedSyntaxKind: "kind",
            confidence: .high,
            executionMode: .isolated,
            line: line,
            column: 1
        )
    }

    @Test("A single worker exhausts one file before moving to the next")
    func singleWorkerClustersByFile() async {
        // Interleaved plan — what a planner naturally produces, since it
        // walks files in order and discovers multiple mutants per file.
        let plan = [
            point("A.swift", 1), point("A.swift", 2),
            point("B.swift", 1), point("B.swift", 2)
        ]
        let queue = MutationQueue(plan)

        var pulled: [String] = []
        while let p = await queue.next(forWorker: "solo") { pulled.append(p.file) }

        #expect(pulled.count == 4)
        // Worker seeds A.swift on its first pull, so A.swift mutants cluster
        // before the worker switches to B.swift — exactly one file switch.
        let switches = zip(pulled, pulled.dropFirst()).filter { $0 != $1 }.count
        #expect(switches == 1, "affinity should cluster same-file mutants; got \(switches) switches in \(pulled)")
        #expect(pulled.prefix(2).allSatisfy { $0 == "A.swift" })
        #expect(pulled.suffix(2).allSatisfy { $0 == "B.swift" })
    }

    @Test("Two workers pulling alternately settle on different files")
    func twoWorkersDivergeOnInterleavedPlan() async {
        // Interleaved: [A/1, B/1, A/2, B/2]. Reversed internally, popLast
        // yields original order, so worker-0's first pull is A/1 and
        // worker-1's first pull is B/1 — they seed different files.
        let plan = [
            point("A.swift", 1), point("B.swift", 1),
            point("A.swift", 2), point("B.swift", 2)
        ]
        let queue = MutationQueue(plan)

        // Strict alternation: worker-0, worker-1, worker-0, worker-1.
        let first0 = await queue.next(forWorker: "worker-0")
        let first1 = await queue.next(forWorker: "worker-1")
        let second0 = await queue.next(forWorker: "worker-0")
        let second1 = await queue.next(forWorker: "worker-1")

        #expect(first0?.file == "A.swift")
        #expect(first1?.file == "B.swift")
        // Affinity: worker-0 gets A/2 (same file), worker-1 gets B/2 (same file).
        #expect(second0?.file == "A.swift")
        #expect(second1?.file == "B.swift")

        let exhausted = await queue.next(forWorker: "worker-0")
        #expect(exhausted == nil)
    }

    @Test("A worker whose file is exhausted falls back to whatever remains")
    func fallsBackWhenFileExhausted() async {
        let plan = [
            point("A.swift", 1), point("A.swift", 2),
            point("B.swift", 1), point("B.swift", 2)
        ]
        let queue = MutationQueue(plan)

        var pulled: [String] = []
        while let p = await queue.next(forWorker: "solo") { pulled.append(p.file) }

        #expect(pulled.count == 4)
        // A.swift mutants cluster first, then B.swift.
        #expect(pulled.prefix(2).allSatisfy { $0 == "A.swift" })
        #expect(pulled.suffix(2).allSatisfy { $0 == "B.swift" })
    }

    @Test("The no-affinity drain path returns every remaining mutant in plan order")
    func drainPathIsAffinityBlind() async {
        let plan = [
            point("A.swift", 1), point("B.swift", 1), point("A.swift", 2), point("B.swift", 2)
        ]
        let queue = MutationQueue(plan)

        // The drain path does not identify itself, so there is no
        // workerLastFile entry and the order is whatever popLast() yields
        // from the reversed-internal array — which is the original plan
        // order, not reversed.
        var drained: [String] = []
        while let p = await queue.next() { drained.append(p.file) }

        #expect(drained.count == 4)
        #expect(drained == ["A.swift", "B.swift", "A.swift", "B.swift"])
    }

    @Test("An empty queue returns nil from both paths")
    func emptyQueueReturnsNil() async {
        let queue = MutationQueue([])

        let affinity = await queue.next(forWorker: "worker-0")
        let drain = await queue.next()

        #expect(affinity == nil)
        #expect(drain == nil)
    }

    @Test("No mutant is lost or duplicated across affinity and drain pulls")
    func noLostOrDuplicatedMutants() async {
        let plan = [
            point("A.swift", 1), point("B.swift", 1), point("C.swift", 1),
            point("A.swift", 2), point("B.swift", 2), point("C.swift", 2)
        ]
        let queue = MutationQueue(plan)

        var ids: Set<String> = []
        // Half through the affinity path, half through drain.
        for _ in 0 ..< 3 {
            if let p = await queue.next(forWorker: "worker-0") { ids.insert(p.id.rawValue) }
        }
        while let p = await queue.next() { ids.insert(p.id.rawValue) }

        #expect(ids.count == plan.count)
    }

    @Test("Concurrent Tasks pulling from the same queue never lose or duplicate a mutant")
    func concurrentTasksNeverLoseOrDuplicate() async throws {
        // A larger plan than the other tests, with enough mutants across
        // enough files to give four concurrent Tasks real contention.
        // The actor serialises every next()/next(forWorker:) call, so the
        // contract to pin here is end-to-end exactly-once — every mutant
        // is returned exactly once across all workers, regardless of
        // interleaving — rather than any particular ordering, which the
        // scheduler is free to reorder.
        var plan: [MutationPoint] = []
        for file in 0 ..< 8 {
            for line in 1 ... 10 {
                plan.append(point("File\(file).swift", line))
            }
        }
        let queue = MutationQueue(plan)

        await withTaskGroup(of: [String].self) { group in
            for workerIndex in 0 ..< 4 {
                group.addTask {
                    var ids: [String] = []
                    let id = "task-worker-\(workerIndex)"
                    while let p = await queue.next(forWorker: id) {
                        ids.append(p.id.rawValue)
                    }
                    return ids
                }
            }
            var allReturned: Set<String> = []
            for await workerIDs in group {
                for id in workerIDs {
                    #expect(!allReturned.contains(id), "mutant \(id) was returned to two workers")
                    allReturned.insert(id)
                }
            }
            #expect(allReturned.count == plan.count, "every planned mutant must be returned exactly once")
        }
    }
}
