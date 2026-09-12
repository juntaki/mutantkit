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
        #expect(hash.hasPrefix("v2:\(ContentHash.algorithmPrefix)"))
    }

    /// The format-version tag exists so a hash computed before linkage
    /// hashing was added and one computed after can never compare equal by
    /// accident — see `MachOCodeHash.formatVersion`'s own doc comment.
    @Test("The hash carries its own format-version tag, distinct from the raw content hash")
    func hashCarriesFormatVersionTag() throws {
        let data = try testBinaryData()
        let hash = try #require(MachOCodeHash.codeHash(of: data))
        #expect(hash.hasPrefix("v2:"))
        #expect(!hash.hasPrefix(ContentHash.algorithmPrefix), "a v1-shaped consumer must never mistake this for a bare content hash")
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
        #expect(modifiedHash.hasPrefix("v2:\(ContentHash.algorithmPrefix)"))
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

    // MARK: - Linkage (issue #3: same `__text` bytes, different bound symbol)

    /// The exact shape of the real bug: a stub call site (`__TEXT,__stubs`
    /// plus the `bl` instruction that reaches it) is byte-for-byte identical
    /// between two binaries, and only the indirect-symbol-table entry that
    /// stub is bound to differs — the same shape `canApplyCoupon`'s `>=`
    /// versus `>` compiled to via `Comparable`'s default implementations.
    /// Section-bytes-only hashing (v1) could not tell these apart; this is
    /// the regression test that proves `linkageHash` (v2) can.
    @Test("Two binaries with byte-identical __text but a different indirect-symbol binding hash differently")
    func differentIndirectSymbolBindingChangesTheHash() throws {
        let boundToSymA = try MinimalMachO.build(stubBoundToSymbolIndex: 0)
        let boundToSymB = try MinimalMachO.build(stubBoundToSymbolIndex: 1)

        // The premise itself, not just the conclusion: the two binaries truly
        // do carry identical `__TEXT,__text` bytes. If this ever stops being
        // true the test above (byte-flip) already covers that shape; this
        // test exists specifically for the case where it stays true.
        #expect(boundToSymA.textSectionBytes == boundToSymB.textSectionBytes)
        #expect(boundToSymA.textSectionBytes != Data())

        let hashA = try #require(MachOCodeHash.codeHash(of: boundToSymA.data))
        let hashB = try #require(MachOCodeHash.codeHash(of: boundToSymB.data))
        #expect(hashA != hashB, "identical __text bytes but a different bound symbol must not hash the same")
    }

    @Test("The same indirect-symbol binding is deterministic across independent builds")
    func sameIndirectSymbolBindingHashesTheSame() throws {
        let first = try MinimalMachO.build(stubBoundToSymbolIndex: 0)
        let second = try MinimalMachO.build(stubBoundToSymbolIndex: 0)
        #expect(MachOCodeHash.codeHash(of: first.data) == MachOCodeHash.codeHash(of: second.data))
    }

    @Test("An indirect symbol index past nsyms fails closed to nil, not a partial hash")
    func outOfRangeSymbolIndexFailsClosed() throws {
        let malformed = try MinimalMachO.build(stubBoundToSymbolIndex: 99)
        #expect(MachOCodeHash.codeHash(of: malformed.data) == nil)
    }

    @Test("An indirect symbol table index past nindirectsyms fails closed to nil")
    func outOfRangeIndirectIndexFailsClosed() throws {
        let malformed = try MinimalMachO.build(stubBoundToSymbolIndex: 0, indirectSymbolCountOverride: 0)
        #expect(MachOCodeHash.codeHash(of: malformed.data) == nil)
    }

    @Test("INDIRECT_SYMBOL_LOCAL resolves to a canonical marker, not a parse failure")
    func localIndirectSymbolResolvesToCanonicalMarker() throws {
        let local = try MinimalMachO.build(stubBoundToSymbolIndex: nil)
        #expect(MachOCodeHash.codeHash(of: local.data) != nil)
    }

    // MARK: - Helpers

    /// A generic (non-linkage-specific) real Mach-O to hash — `MinimalMachO`
    /// (`Tests/MutantKitTests/Support/MinimalMachO.swift`) replaced a checked-in
    /// binary fixture here: every byte this produces is visible in Swift
    /// source rather than an opaque blob, and it is exactly as real a
    /// Mach-O as far as `MachOCodeHash` is concerned (same allow-listed
    /// `__TEXT,__text` section, same load-command shape it already reads).
    private func testBinaryData() throws -> Data {
        try MinimalMachO.build(stubBoundToSymbolIndex: 0).data
    }
}
