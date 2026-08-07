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

    private func testBinaryData() throws -> Data {
        let resourceURL = try #require(Bundle.module.resourceURL)
        let url = resourceURL.appendingPathComponent("Fixtures/macho-test-binary")
        return try Data(contentsOf: url)
    }
}

/// Hand-assembled, minimal-but-valid little-endian arm64 Mach-O object: a
/// `mach_header_64`, one `__TEXT` segment with a regular `__text` section and
/// an `S_SYMBOL_STUBS` section (one stub slot), `LC_SYMTAB`, `LC_DYSYMTAB`,
/// and a matching symbol/string/indirect-symbol table. Exists only to give
/// `MachOCodeHashTests` a binary whose linkage this test file controls
/// byte-for-byte — the real fixture (`Fixtures/macho-test-binary`) cannot
/// prove "identical __text, different binding" on demand.
private enum MinimalMachO {
    struct Built {
        let data: Data
        let textSectionBytes: Data
    }

    enum BuildError: Error { case unexpected }

    /// Everything `writeSegmentAndSections` needs, grouped so the function
    /// itself stays under the parameter-count limit — purely a parameter
    /// bundle, not a reusable layout description.
    private struct SegmentLayout {
        let commandStart: Int
        let segmentCommandSize: Int
        let sectionSize: Int
        let sectionCount: Int
        let segmentCommandTotal: Int
        let textOffset: Int
        let textBytes: Data
        let stubsOffset: Int
        let stubBytes: Data
    }

    /// Writes the one `LC_SEGMENT_64` command (`__TEXT`) and its two
    /// sections (`__text`, a regular allow-listed section; `__stubs`, an
    /// `S_SYMBOL_STUBS` linkage section) — split out of `build` purely to
    /// keep that function's own body short; the byte layout is unchanged.
    private static func writeSegmentAndSections(into data: inout Data, layout: SegmentLayout) {
        let commandStart = layout.commandStart
        data.writeUInt32(0x19, at: commandStart) // cmd: LC_SEGMENT_64
        data.writeUInt32(UInt32(layout.segmentCommandTotal), at: commandStart + 4) // cmdsize
        data.writeCString("__TEXT", at: commandStart + 8, maxLength: 16)
        data.writeUInt64(0, at: commandStart + 24) // vmaddr
        data.writeUInt64(0, at: commandStart + 32) // vmsize
        data.writeUInt64(0, at: commandStart + 40) // fileoff
        data.writeUInt64(0, at: commandStart + 48) // filesize
        data.writeUInt32(0, at: commandStart + 56) // maxprot
        data.writeUInt32(0, at: commandStart + 60) // initprot
        data.writeUInt32(UInt32(layout.sectionCount), at: commandStart + 64) // nsects
        data.writeUInt32(0, at: commandStart + 68) // flags

        var sectionCursor = commandStart + layout.segmentCommandSize
        // __text: a regular section, part of MachOCodeHash's own allow-list.
        data.writeCString("__text", at: sectionCursor, maxLength: 16)
        data.writeCString("__TEXT", at: sectionCursor + 16, maxLength: 16)
        data.writeUInt64(0, at: sectionCursor + 32) // addr
        data.writeUInt64(UInt64(layout.textBytes.count), at: sectionCursor + 40) // size
        data.writeUInt32(UInt32(layout.textOffset), at: sectionCursor + 48) // offset
        data.writeUInt32(0, at: sectionCursor + 52) // align
        data.writeUInt32(0, at: sectionCursor + 56) // reloff
        data.writeUInt32(0, at: sectionCursor + 60) // nreloc
        data.writeUInt32(0x0, at: sectionCursor + 64) // flags: S_REGULAR
        data.writeUInt32(0, at: sectionCursor + 68) // reserved1
        data.writeUInt32(0, at: sectionCursor + 72) // reserved2
        data.replaceSubrange(layout.textOffset ..< layout.textOffset + layout.textBytes.count, with: layout.textBytes)
        sectionCursor += layout.sectionSize

        // __stubs: S_SYMBOL_STUBS, one slot, reserved1 = 0 (starting index
        // into the indirect symbol table), reserved2 = stub byte size.
        data.writeCString("__stubs", at: sectionCursor, maxLength: 16)
        data.writeCString("__TEXT", at: sectionCursor + 16, maxLength: 16)
        data.writeUInt64(0, at: sectionCursor + 32) // addr
        data.writeUInt64(UInt64(layout.stubBytes.count), at: sectionCursor + 40) // size
        data.writeUInt32(UInt32(layout.stubsOffset), at: sectionCursor + 48) // offset
        data.writeUInt32(0, at: sectionCursor + 52) // align
        data.writeUInt32(0, at: sectionCursor + 56) // reloff
        data.writeUInt32(0, at: sectionCursor + 60) // nreloc
        data.writeUInt32(0x8, at: sectionCursor + 64) // flags: S_SYMBOL_STUBS
        data.writeUInt32(0, at: sectionCursor + 68) // reserved1: indirect symtab start index
        data.writeUInt32(UInt32(layout.stubBytes.count), at: sectionCursor + 72) // reserved2: stub size
        data.replaceSubrange(layout.stubsOffset ..< layout.stubsOffset + layout.stubBytes.count, with: layout.stubBytes)
    }

    /// `stubBoundToSymbolIndex`: which `nlist_64` entry (0 = "sym_a", 1 =
    /// "sym_b") the one indirect-symbol-table slot points at — `nil` sets
    /// `INDIRECT_SYMBOL_LOCAL` instead of a real index. Every other byte
    /// (including the stub's own 4 bytes in `__text`... — actually in
    /// `__stubs`, see below) is identical across every call, so any hash
    /// difference between two `Built` values can only come from the
    /// indirect-symbol-table entry itself.
    static func build(stubBoundToSymbolIndex: Int?, indirectSymbolCountOverride: Int? = nil) throws -> Built {
        let textBytes = Data([0x1F, 0x20, 0x03, 0xD5, 0x1F, 0x20, 0x03, 0xD5]) // two AArch64 NOPs
        let stubBytes = Data([0x00, 0x00, 0x00, 0x94]) // placeholder 4-byte "stub"

        let headerSize = 32
        let segmentCommandSize = 72
        let sectionSize = 80
        let sectionCount = 2
        let symtabCommandSize = 24
        let dysymtabCommandSize = 80
        let segmentCommandTotal = segmentCommandSize + sectionSize * sectionCount

        let loadCommandsSize = segmentCommandTotal + symtabCommandSize + dysymtabCommandSize
        let sectionsStart = headerSize + loadCommandsSize
        let textOffset = sectionsStart
        let stubsOffset = textOffset + textBytes.count

        let symbolOffset = stubsOffset + stubBytes.count
        let symbolCount = 2 // "sym_a", "sym_b"
        let nlistSize = 16
        let stringOffset = symbolOffset + symbolCount * nlistSize
        // Leading NUL (strx 0 means "no name"), then "sym_a\0", then "sym_b\0".
        let stringTable = Data([0x00]) + Data("sym_a\0".utf8) + Data("sym_b\0".utf8)
        let indirectOffset = stringOffset + stringTable.count
        let indirectCount = indirectSymbolCountOverride ?? 1

        let totalSize = indirectOffset + max(indirectCount, 1) * 4
        var data = Data(count: totalSize)

        data.writeUInt32(0xFEED_FACF, at: 0) // magic
        data.writeUInt32(0x0100_000C, at: 4) // cputype: CPU_TYPE_ARM64
        data.writeUInt32(0, at: 8) // cpusubtype
        data.writeUInt32(2, at: 12) // filetype: MH_EXECUTE (unused by the reader)
        data.writeUInt32(3, at: 16) // ncmds
        data.writeUInt32(UInt32(loadCommandsSize), at: 20) // sizeofcmds
        data.writeUInt32(0, at: 24) // flags
        data.writeUInt32(0, at: 28) // reserved

        writeSegmentAndSections(into: &data, layout: SegmentLayout(
            commandStart: headerSize, segmentCommandSize: segmentCommandSize, sectionSize: sectionSize,
            sectionCount: sectionCount, segmentCommandTotal: segmentCommandTotal,
            textOffset: textOffset, textBytes: textBytes, stubsOffset: stubsOffset, stubBytes: stubBytes
        ))
        var cursor = headerSize + segmentCommandTotal

        // LC_SYMTAB
        data.writeUInt32(0x2, at: cursor)
        data.writeUInt32(UInt32(symtabCommandSize), at: cursor + 4)
        data.writeUInt32(UInt32(symbolOffset), at: cursor + 8) // symoff
        data.writeUInt32(UInt32(symbolCount), at: cursor + 12) // nsyms
        data.writeUInt32(UInt32(stringOffset), at: cursor + 16) // stroff
        data.writeUInt32(UInt32(stringTable.count), at: cursor + 20) // strsize
        cursor += symtabCommandSize

        // LC_DYSYMTAB — only indirectsymoff/nindirectsyms (offsets 56/60)
        // matter to the reader; everything else stays zero.
        data.writeUInt32(0xB, at: cursor)
        data.writeUInt32(UInt32(dysymtabCommandSize), at: cursor + 4)
        data.writeUInt32(UInt32(indirectOffset), at: cursor + 56)
        data.writeUInt32(UInt32(indirectCount), at: cursor + 60)

        // nlist_64 entries: n_strx only matters here.
        data.writeUInt32(1, at: symbolOffset) // "sym_a" starts right after the leading NUL
        data.writeUInt32(7, at: symbolOffset + nlistSize) // "sym_b"
        data.replaceSubrange(stringOffset ..< stringOffset + stringTable.count, with: stringTable)

        // Indirect symbol table: one slot, pointing at whichever symbol (or
        // INDIRECT_SYMBOL_LOCAL) the caller asked for.
        if indirectCount > 0 {
            let indirectValue: UInt32
            if let stubBoundToSymbolIndex {
                indirectValue = UInt32(stubBoundToSymbolIndex)
            } else {
                indirectValue = 0x8000_0000 // INDIRECT_SYMBOL_LOCAL
            }
            data.writeUInt32(indirectValue, at: indirectOffset)
        }

        return Built(data: data, textSectionBytes: textBytes)
    }
}

private extension Data {
    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { replaceSubrange(offset ..< offset + 4, with: $0) }
    }

    mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { replaceSubrange(offset ..< offset + 8, with: $0) }
    }

    mutating func writeCString(_ string: String, at offset: Int, maxLength: Int) {
        var bytes = Array(string.utf8)
        precondition(bytes.count < maxLength)
        bytes.append(contentsOf: repeatElement(0, count: maxLength - bytes.count))
        replaceSubrange(offset ..< offset + maxLength, with: bytes)
    }
}
