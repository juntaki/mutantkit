import Foundation
import MutationExecution
import Testing

/// Direct unit tests for `CoverageProfileCache`: a stored attribution
/// survives a load against the same key, does not leak across keys, and is
/// invalidated by `removeAll`. The runner-level behaviour — a hit skips
/// `measurePerTestCoverage`, a miss measures and stores — is covered by
/// `MutationRunnerCoverageCacheTests`.
@Suite("Coverage profile cache")
struct CoverageProfileCacheTests {
    private let root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("coverage-cache-tests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func sample(covering target: String) -> PerTestCoverageMap {
        PerTestCoverageMap(
            coveringTests: [
                "Sources/Foo.swift": [10: [TestIdentifier(target: target, qualifiedName: "FooTests/testFoo")]]
            ],
            source: "test"
        )
    }

    @Test("A stored map round-trips through the same key")
    func storeAndLoadRoundTrip() async {
        let cache = CoverageProfileCache(root: root)
        let key = CoverageProfileCache.Key(contextDigest: "digest-A")
        let map = sample(covering: "ATests")

        await cache.store(map, for: key)
        let loaded = await cache.load(key)

        #expect(loaded == map)
    }

    @Test("A load against a different key returns nil")
    func differentKeyMisses() async {
        let cache = CoverageProfileCache(root: root)
        await cache.store(sample(covering: "ATests"), for: .init(contextDigest: "digest-A"))

        let loaded = await cache.load(.init(contextDigest: "digest-B"))

        #expect(loaded == nil)
    }

    @Test("removeAll empties the cache")
    func removeAllEmpties() async {
        let cache = CoverageProfileCache(root: root)
        let key = CoverageProfileCache.Key(contextDigest: "digest-A")
        await cache.store(sample(covering: "ATests"), for: key)

        await cache.removeAll()
        let loaded = await cache.load(key)

        #expect(loaded == nil)
    }

    @Test("A load against an empty cache returns nil without throwing")
    func emptyCacheReturnsNil() async {
        let cache = CoverageProfileCache(root: root)

        let loaded = await cache.load(.init(contextDigest: "never-stored"))

        #expect(loaded == nil)
    }

    @Test("A stored map with multiple files and lines round-trips exactly")
    func nestedStructureRoundTrips() async {
        let cache = CoverageProfileCache(root: root)
        let key = CoverageProfileCache.Key(contextDigest: "nested")
        let map = PerTestCoverageMap(
            coveringTests: [
                "Sources/A.swift": [
                    1: [TestIdentifier(target: "T", qualifiedName: "C/test1")],
                    42: [
                        TestIdentifier(target: "T", qualifiedName: "C/test2"),
                        TestIdentifier(target: "T", qualifiedName: "C/test3")
                    ]
                ],
                "Sources/B.swift": [10: [TestIdentifier(target: "T", qualifiedName: "C/test4")]]
            ],
            source: "xcodebuild-xccov-per-test"
        )

        await cache.store(map, for: key)
        let loaded = await cache.load(key)

        #expect(loaded == map)
    }

    @Test("A corrupted cache file yields nil, not a throw — the caller recomputes")
    func corruptedFileReturnsNil() async throws {
        let cache = CoverageProfileCache(root: root)
        let key = CoverageProfileCache.Key(contextDigest: "corrupt")
        // Write garbage where a JSON record is expected. The cache must
        // treat this exactly like a miss — decodeIfPresent already handles
        // it, but this test pins the fail-closed contract explicitly: a
        // bad file never propagates as a thrown error, because a thrown
        // error would force every establishBaseline caller to add error
        // handling for a condition whose only safe response is "recompute
        // from scratch", which is exactly what nil already means.
        let stored = sample(covering: "ATests")
        await cache.store(stored, for: key)
        // Overwrite the stored file with garbage in place — same path the
        // cache would use, discovered through the public store API.
        await cache.store(stored, for: key)
        let anyFile = try #require(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first
        )
        try Data("not valid JSON".utf8).write(to: anyFile)

        let loaded = await cache.load(key)

        #expect(loaded == nil)
    }
}
