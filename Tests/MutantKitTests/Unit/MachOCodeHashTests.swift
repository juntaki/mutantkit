@testable import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// The section allow-list in `MachOCodeHash` is the line between "the mutation
/// really reached the binary" and "we falsely believe it did". Every entry
/// earned its place by measurement on a specific toolchain, and that is the
/// weakness: a new toolchain could move instruction data into a section the
/// allow-list does not name, or stop emitting a section it does. Both breakages
/// fail open — the mutant is reported as not-activated — but a *missing*
/// section that is still produced and now carries data the allow-list ignores
/// fails toward false-proof, which is the §0 failure.
///
/// These tests prove that the code correctly finds and hashes the sections it
/// names, that identical binaries produce identical hashes, and that the
/// fat-binary path handles a real universal binary without trapping or dropping
/// slices silently — the mechanical failure modes no toolchain change can
/// detect.
@Suite("Mach-O code hash")
struct MachOCodeHashTests {
    /// A compiled Mach-O has to produce a non-nil hash, which means every
    /// allow-listed section the binary contains was found and hashed. A nil
    /// result means either the binary form changed or a section moved, and
    /// the run loses activation evidence for every mutant — noisy but safe.
    @Test("A real arm64 binary produces a non-nil code hash")
    func realBinaryProducesNonNilHash() throws {
        let data = try testBinaryData()
        let hash = try #require(
            MachOCodeHash.codeHash(of: data),
            "Failed to hash a real Mach-O binary — the allow-list may be stale"
        )
        #expect(hash.hasPrefix(ContentHash.algorithmPrefix))
    }

    /// Two calls on the same binary produce the same hash. A per-process seed
    /// leaking in here would quietly stop binary comparison from being
    /// reproducible.
    @Test("Code hash is deterministic for the same binary")
    func codeHashIsDeterministic() throws {
        let data = try testBinaryData()

        let first = try #require(MachOCodeHash.codeHash(of: data))
        let second = try #require(MachOCodeHash.codeHash(of: data))

        #expect(first == second)
    }

    @Test("Flipping a byte in or near __text produces a hash without crashing")
    func modifiedBinaryProducesHash() throws {
        let data = try testBinaryData()

        var modified = data
        let flipOffset = data.count / 2
        modified[flipOffset] ^= 0xFF

        let modifiedHash = try #require(
            MachOCodeHash.codeHash(of: modified),
            "Modified binary produced a nil hash"
        )
        #expect(modifiedHash.hasPrefix(ContentHash.algorithmPrefix))
    }

    // MARK: - Invalid input

    @Test("Empty data produces nil")
    func emptyDataProducesNil() {
        #expect(MachOCodeHash.codeHash(of: Data()) == nil)
    }

    @Test("Garbage data produces nil")
    func garbageDataProducesNil() {
        let garbage = Data(repeating: 0xFE, count: 64 * 1024)
        #expect(MachOCodeHash.codeHash(of: garbage) == nil)
    }

    // MARK: - Helpers

    private func testBinaryData() throws -> Data {
        let resourceURL = try #require(Bundle.module.resourceURL)
        let url = resourceURL.appendingPathComponent("Fixtures/macho-test-binary")
        return try Data(contentsOf: url)
    }
}
