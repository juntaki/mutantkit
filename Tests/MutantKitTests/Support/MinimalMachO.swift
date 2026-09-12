import Foundation

/// Hand-assembled, minimal-but-valid little-endian arm64 Mach-O object: a
/// `mach_header_64`, one `__TEXT` segment with a regular `__text` section and
/// an `S_SYMBOL_STUBS` section (one stub slot), `LC_SYMTAB`, `LC_DYSYMTAB`,
/// and a matching symbol/string/indirect-symbol table.
///
/// Shared by `MachOCodeHashTests` and `TestProductHasherTests` — both need a
/// real, allow-listed-section-bearing Mach-O to hash, and neither needs it to
/// be a real compiled artifact (`MachOCodeHash`/`TestProductHasher` read only
/// the load commands and section bytes this type controls directly). A
/// checked-in binary fixture (`Tests/MutantKitTests/Fixtures/macho-test-binary`,
/// removed when this type was written) could not prove
/// `differentIndirectSymbolBindingChangesTheHash`'s "identical __text,
/// different binding" premise on demand the way this can, and reviewing a
/// binary blob byte-for-byte is not something a diff can meaningfully show —
/// every byte this fixture produces is visible, and reproducible, in the
/// Swift source below instead.
enum MinimalMachO {
    struct Built {
        let data: Data
        let textSectionBytes: Data
        /// Absolute file offset of `textSectionBytes` within `data` — lets a
        /// caller flip a specific byte inside `__text` by computed position
        /// rather than a hardcoded magic offset that silently stops meaning
        /// what it says the moment this layout changes.
        let textOffset: Int
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
    /// (including the stub's own 4 bytes in `__stubs`) is identical across
    /// every call, so any hash difference between two `Built` values can
    /// only come from the indirect-symbol-table entry itself.
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

        return Built(data: data, textSectionBytes: textBytes, textOffset: textOffset)
    }
}

extension Data {
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
