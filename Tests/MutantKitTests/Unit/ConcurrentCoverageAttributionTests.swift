import Foundation
import MutationExecution
import Testing

/// `attributeConcurrently` only changes how the per-test coverage pass is scheduled. What it reports
/// must be what `attribute` reports for the same measurements, and it must degrade to one slot, not
/// to a different answer, when the other slots cannot be set up.
@Suite("Concurrent per-test coverage attribution")
struct ConcurrentCoverageAttributionTests {
    private let tests = (0 ..< 12).map { TestIdentifier(target: "T", qualifiedName: "S\($0 / 3)/t\($0)") }

    private static func coverage(of test: TestIdentifier) -> CoverageMap {
        let index = Int(test.qualifiedName.split(separator: "t").last ?? "0") ?? 0
        return CoverageMap(executedLines: ["Sources/A.swift": [index, 100], "Sources/B.swift": []], source: "test")
    }

    @Test("It attributes exactly what the serial pass attributes")
    func matchesSerial() async throws {
        let serial = try #require(await PerTestCoverageAttribution.attribute(tests: tests, source: "test") { test, _ in
            Self.coverage(of: test)
        })
        let concurrent = try #require(await PerTestCoverageAttribution.attributeConcurrently(
            tests: tests, source: "test", workers: 4,
            groupKey: { $0.qualifiedName.split(separator: "/").first.map(String.init) ?? "" },
            prepareSlot: { _ in true },
            attempt: { test, _, _ in Self.coverage(of: test) }
        ))

        #expect(concurrent == serial)
    }

    @Test("The lines the measurements saw as measured are carried into the concurrent map too")
    func mappedLinesAreCarried() async throws {
        let map = try #require(await PerTestCoverageAttribution.attributeConcurrently(
            tests: tests, source: "test", workers: 3,
            groupKey: { $0.qualifiedName },
            prepareSlot: { _ in true },
            attempt: { test, _, _ in
                let index = Int(test.qualifiedName.split(separator: "t").last ?? "0") ?? 0
                return CoverageMap(
                    executedLines: ["Sources/A.swift": [index]], source: "test",
                    mappedLines: ["Sources/A.swift": [index, 100]]
                )
            }
        ))

        #expect(map.mappedLines["Sources/A.swift"] == Set(0 ..< 12).union([100]))
        #expect(map.testsCovering(file: "Sources/A.swift", line: 50) == nil)
    }

    @Test("A test that cannot be measured is carried as unattributed, after its retry")
    func failureIsRetriedThenCarried() async throws {
        let bad = tests[4]
        let attemptsMade = Counter()
        let map = try #require(await PerTestCoverageAttribution.attributeConcurrently(
            tests: tests, source: "test", workers: 3,
            groupKey: { $0.qualifiedName },
            prepareSlot: { _ in true },
            attempt: { test, _, _ in
                if test == bad {
                    await attemptsMade.increment()
                    return nil
                }
                return Self.coverage(of: test)
            }
        ))

        #expect(map.unattributedTests == [bad])
        #expect(await attemptsMade.value == 2)
    }

    @Test("Slots that decline to take part leave the rest to slot 0, with the same result")
    func decliningSlotsFallBackToSlotZero() async throws {
        let slotsUsed = SlotRecorder()
        let serial = try #require(await PerTestCoverageAttribution.attribute(tests: tests, source: "test") { test, _ in
            Self.coverage(of: test)
        })
        let map = try #require(await PerTestCoverageAttribution.attributeConcurrently(
            tests: tests, source: "test", workers: 4,
            groupKey: { $0.qualifiedName },
            prepareSlot: { _ in false },
            attempt: { test, _, slot in
                await slotsUsed.record(slot)
                return Self.coverage(of: test)
            }
        ))

        #expect(map == serial)
        #expect(await slotsUsed.slots == [0])
    }

    @Test("The first group runs alone on slot 0, before any other slot is prepared")
    func firstGroupRunsAloneBeforeSlotsArePrepared() async throws {
        let log = SlotRecorder()
        _ = await PerTestCoverageAttribution.attributeConcurrently(
            tests: tests, source: "test", workers: 3,
            groupKey: { $0.qualifiedName },
            prepareSlot: { slot in
                await log.record(-slot)
                return true
            },
            attempt: { test, _, slot in
                await log.record(slot)
                return Self.coverage(of: test)
            }
        )

        let order = await log.order
        #expect(order.first == 0)
        #expect(order.firstIndex(of: -1)! > 0)
        #expect(order.firstIndex(of: -2)! > 0)
    }

    @Test("Every test of a group runs on one slot, so a shared measurement is never taken twice at once")
    func groupStaysOnOneSlot() async throws {
        let slotOf = SlotRecorder()
        _ = await PerTestCoverageAttribution.attributeConcurrently(
            tests: tests, source: "test", workers: 4,
            groupKey: { $0.qualifiedName.split(separator: "/").first.map(String.init) ?? "" },
            prepareSlot: { _ in true },
            attempt: { test, _, slot in
                await slotOf.record(slot, for: test.qualifiedName.split(separator: "/").first.map(String.init) ?? "")
                return Self.coverage(of: test)
            }
        )

        for (_, slots) in await slotOf.slotsByGroup { #expect(slots.count == 1) }
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor SlotRecorder {
    private(set) var order: [Int] = []
    private(set) var slotsByGroup: [String: Set<Int>] = [:]
    var slots: Set<Int> { Set(order.filter { $0 >= 0 }) }

    func record(_ slot: Int) { order.append(slot) }
    func record(_ slot: Int, for group: String) { slotsByGroup[group, default: []].insert(slot) }
}
