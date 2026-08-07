import Foundation
import MutationModel

/// Hashes the executable code *and* linkage semantics inside a Mach-O binary.
///
/// Hashing the file bytes would be simpler and wrong. Two builds of *identical*
/// source produce different binaries: the linker's `LC_UUID` is derived from
/// content that includes absolute paths, `__TEXT,__cstring` carries the `#file`
/// strings, and the coverage and profiling sections (`__LLVM_COV`,
/// `__DATA,__llvm_prf_*`) embed source paths outright. Every mutant is built in
/// its own sandbox directory, so all of those differ for every mutant no matter
/// what the mutation did. A whole-file hash therefore reports every mutant as
/// having reached the binary — including the phantoms
/// `ActivationEvidence.buildProductIdenticalToBaseline` exists to catch — which
/// is a false proof of activation, and worse than no proof at all.
///
/// So this hashes a measured allow-list of *semantic* sections — the compiled
/// instructions and the constant data — and nothing else: no UUID, no coverage
/// tables, no profiling counters. It changes when the program changes, and a
/// comment-only edit leaves it untouched, which is the question activation
/// evidence actually asks. See `hashedSections` for how each entry was chosen.
///
/// Section bytes alone are not enough (issue #3, real bug, real CI evidence):
/// a mutation lowered through a Swift `Comparable`-protocol default
/// implementation (e.g. `canApplyCoupon`'s `subtotal >= 20` mutated to
/// `subtotal > 20`, where `Decimal`'s `>=`/`>` are both non-witness default
/// implementations calling `<`) compiles to the *same* stub-call instruction
/// bytes at the *same* offset in `__TEXT,__text` for both the original and the
/// mutant — the call site itself never changes. What differs is which real
/// symbol that stub is bound to (`Comparable.>=` vs `Comparable.>`), which
/// lives in the indirect symbol table (`LC_DYSYMTAB`) and the string table
/// (`LC_SYMTAB`), not in any of the four allow-listed sections. A hash of
/// section bytes alone reported that mutant's build product as byte-identical
/// to the baseline's — a false "mutation never reached the binary" — even
/// though the compiler genuinely recompiled the mutated source and the test
/// genuinely failed for the right reason. `linkageHash` closes that gap by
/// additionally hashing, for every `S_SYMBOL_STUBS`/`S_LAZY_SYMBOL_POINTERS`/
/// `S_NON_LAZY_SYMBOL_POINTERS` section, which real symbol name each slot in
/// it resolves to via the indirect symbol table — the same resolution `otool
/// -tV` itself performs to print "symbol stub for: ...".
///
/// Two limits are worth stating plainly, because a hash is a claim:
///
/// 1. This is path-independent only across paths of the **same length**. A path
///    of a different length shifts the constants that instructions address,
///    changing these bytes even when the source is identical. `WorkspaceManager`
///    guarantees equal-length sandbox paths, and this hash means nothing without
///    that guarantee — the two are one mechanism split across two types.
/// 2. A mutation confined to a string literal lands in `__cstring`, which is
///    excluded because it carries `#file` paths. Such a mutant reads as unproven
///    rather than activated.
///
/// The remaining failure points the safe way: toward under-claiming activation
/// rather than asserting it. That is the correct direction for evidence to be
/// wrong in — an unproven mutant is excluded and counted, while a falsely proven
/// one silently enters the score. `linkageHash` keeps that direction: a binding
/// form it cannot parse (a malformed indirect symbol table, an out-of-range
/// index, a string table read past `strsize`) fails the whole hash to `nil`
/// rather than silently reporting "no linkage" — a binary this code cannot
/// fully account for must never be treated as identical to another by omission.
/// Modern chained-fixup binding (`LC_DYLD_CHAINED_FIXUPS`) is not parsed by
/// this pass; its mere *presence* alongside a working, fully-resolvable
/// indirect symbol table is not itself treated as a failure — the classic
/// mechanism is what issue #3's real binaries used for the stub calls that
/// mattered here, confirmed by direct disassembly (`otool -tV` resolved real
/// symbol names for the differing call), and continuing to hash it is strictly
/// more informative than not. A future binary whose *relevant* binding lives
/// only in a chained-fixups stream and nowhere in the indirect symbol table
/// would still under-report (fail toward "no linkage difference found"), which
/// is the same safe direction this type has always failed in.
enum MachOCodeHash {
    // On-disk magics, as read little-endian on the host.
    private static let machO64: UInt32 = 0xFEED_FACF
    /// Fat headers are big-endian on disk, so the host reads them byte-swapped.
    private static let fatBigEndian: UInt32 = 0xBEBA_FECA
    private static let fat64BigEndian: UInt32 = 0xBFBA_FECA

    private static let segmentCommand64: UInt32 = 0x19
    private static let symtabCommand: UInt32 = 0x2
    private static let dysymtabCommand: UInt32 = 0xB

    private static let sectionTypeMask: UInt32 = 0xFF
    private static let sectionNonLazySymbolPointers: UInt32 = 0x6
    private static let sectionLazySymbolPointers: UInt32 = 0x7
    private static let sectionSymbolStubs: UInt32 = 0x8

    private static let indirectSymbolLocal: UInt32 = 0x8000_0000
    private static let indirectSymbolAbs: UInt32 = 0x4000_0000

    /// This hash's own format version, folded into every preimage below.
    ///
    /// v1 hashed section bytes alone. v2 adds `linkageHash`. The two must
    /// never compare equal by accident: a `productHash` computed before this
    /// change and one computed after must always compare unequal (a safe
    /// cache miss / re-verification) rather than a silent, meaningless
    /// "match" between two different notions of "identical". Bump this again
    /// if what gets hashed changes again.
    private static let formatVersion = "v2"

    /// The sections whose bytes carry the program's meaning.
    ///
    /// An allow-list, and every entry earned its place by measurement rather than
    /// by looking plausible. Two properties were checked on this toolchain for
    /// each one:
    ///
    /// - **It notices a mutation.** `__text` alone does not. A mutation to a
    ///   stored initializer — `static var enabled = true` flipped to `false` —
    ///   lands *only* in `__DATA,__data`, leaving every other section, `__text`
    ///   included, byte-identical. Hashing code alone reported that mutant as
    ///   never having reached the binary, which was false and, because it fails
    ///   closed, cost the whole run its score.
    /// - **It ignores the build path.** Identical sources built at two
    ///   equal-length paths produce identical bytes in all four. Sections that do
    ///   not have that property are excluded and must stay excluded: `__LLVM_COV`
    ///   and `__DATA,__llvm_prf_*` embed source paths outright, and `LC_UUID` is
    ///   derived from content that includes them. Hashing those would make every
    ///   mutant differ from the baseline for reasons unrelated to the mutation —
    ///   a false proof of activation, which is worse than no proof.
    ///
    /// The path-independence holds only at *equal-length* paths; `WorkspaceManager`
    /// is what guarantees that, and this hash is meaningless without it.
    private static let hashedSections: [(segment: String, section: String)] = [
        ("__TEXT", "__text"), // compiled instructions
        ("__TEXT", "__const"), // immutable constants
        ("__DATA", "__data"), // initial values of mutable globals
        ("__DATA_CONST", "__const") // immutable constants needing relocation
    ]

    /// Hash of every architecture's semantic sections plus their linkage
    /// semantics, or `nil` if the file is not a Mach-O this can read.
    ///
    /// `nil` rather than a fallback: a caller that receives a hash must be able to
    /// trust what it means, and quietly substituting a whole-file hash would hand
    /// back a value with the opposite property.
    static func codeHash(ofBinaryAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return codeHash(of: data)
    }

    static func codeHash(of data: Data) -> String? {
        guard let magic = data.readUInt32(at: 0, bigEndian: false) else { return nil }

        switch magic {
        case machO64:
            guard let identity = semanticIdentity(in: data, sliceOffset: 0) else { return nil }
            return "\(formatVersion):\(identity)"

        case fatBigEndian, fat64BigEndian:
            return fatCodeHash(of: data, is64: magic == fat64BigEndian)

        default:
            // 32-bit or big-endian Mach-O: no current Apple platform produces one
            // for a test bundle, so it is reported as unreadable rather than parsed
            // speculatively.
            return nil
        }
    }

    /// Hashes each slice of a universal binary.
    ///
    /// Simulator bundles are routinely fat (arm64 + x86_64). Hashing only the first
    /// slice would miss a mutation whose codegen differs per architecture.
    private static func fatCodeHash(of data: Data, is64: Bool) -> String? {
        guard let count = data.readUInt32(at: 4, bigEndian: true) else { return nil }
        // A malformed header must not turn into a huge loop.
        guard count > 0, count < 64 else { return nil }

        let archSize = is64 ? 32 : 20
        var slices: [(cpu: UInt32, identity: String)] = []

        for index in 0 ..< Int(count) {
            let base = 8 + index * archSize
            guard let cpu = data.readUInt32(at: base, bigEndian: true) else { return nil }

            let offset: Int
            if is64 {
                guard let value = data.readUInt64(at: base + 8, bigEndian: true) else { return nil }
                offset = Int(value)
            } else {
                guard let value = data.readUInt32(at: base + 8, bigEndian: true) else { return nil }
                offset = Int(value)
            }

            guard let identity = semanticIdentity(in: data, sliceOffset: offset) else { return nil }
            slices.append((cpu, identity))
        }

        guard !slices.isEmpty else { return nil }
        // Sorted by CPU type so that lipo ordering cannot change the hash.
        let preimage = slices.sorted { $0.cpu < $1.cpu }
            .map { "\($0.cpu):\($0.identity)" }
            .joined(separator: "\n")
        return "\(formatVersion):\(ContentHash.of(preimage))"
    }

    /// One `S_SYMBOL_STUBS`/`S_LAZY_SYMBOL_POINTERS`/`S_NON_LAZY_SYMBOL_POINTERS`
    /// section's location in the indirect symbol table, collected while
    /// walking load commands so it can be resolved once `LC_SYMTAB`/
    /// `LC_DYSYMTAB` (which may appear before or after it) are both known.
    private struct LinkageSection {
        let segment: String
        let section: String
        /// Starting index into the indirect symbol table (`section_64.reserved1`).
        let indirectSymbolIndex: Int
        /// Number of indirect-symbol-table slots this section occupies.
        let slotCount: Int
    }

    /// `LC_SYMTAB`'s fields, only the ones the indirect-symbol resolver needs.
    private struct SymbolTableLocation {
        let symbolOffset: Int
        let symbolCount: Int
        let stringOffset: Int
        let stringSize: Int
    }

    /// `LC_DYSYMTAB`'s indirect symbol table location, only the two fields
    /// this reader needs out of its many.
    private struct IndirectSymbolTableLocation {
        let offset: Int
        let count: Int
    }

    /// One `LC_SEGMENT_64`'s worth of contribution to the identity: which
    /// allow-listed sections it carries (name -> content hash) and which
    /// symbol-stub/lazy-pointer/non-lazy-pointer sections it declares.
    /// Splits `semanticIdentity`'s per-segment work into its own function so
    /// that function's own branch count stays reviewable.
    private static func symbolTableLocation(in data: Data, commandCursor: Int) -> SymbolTableLocation? {
        guard let symoff = data.readUInt32(at: commandCursor + 8, bigEndian: false),
              let nsyms = data.readUInt32(at: commandCursor + 12, bigEndian: false),
              let stroff = data.readUInt32(at: commandCursor + 16, bigEndian: false),
              let strsize = data.readUInt32(at: commandCursor + 20, bigEndian: false)
        else { return nil }
        return SymbolTableLocation(
            symbolOffset: Int(symoff), symbolCount: Int(nsyms), stringOffset: Int(stroff), stringSize: Int(strsize)
        )
    }

    private static func indirectSymbolTableLocation(in data: Data, commandCursor: Int) -> IndirectSymbolTableLocation? {
        guard let indirectOffset = data.readUInt32(at: commandCursor + 56, bigEndian: false),
              let indirectCount = data.readUInt32(at: commandCursor + 60, bigEndian: false)
        else { return nil }
        return IndirectSymbolTableLocation(offset: Int(indirectOffset), count: Int(indirectCount))
    }

    private static func segmentContribution(
        in data: Data, sliceOffset: Int, commandCursor: Int
    ) -> (sections: [String: String], linkageSections: [LinkageSection])? {
        guard let segmentName = data.readCString(at: commandCursor + 8, maxLength: 16),
              let sectionCount = data.readUInt32(at: commandCursor + 64, bigEndian: false)
        else { return nil }

        var sections: [String: String] = [:]
        var linkageSections: [LinkageSection] = []

        // segment_command_64 is 72 bytes; section_64 entries follow it.
        var sectionCursor = commandCursor + 72
        for _ in 0 ..< sectionCount {
            defer { sectionCursor += 80 }

            guard let sectionName = data.readCString(at: sectionCursor, maxLength: 16),
                  let size = data.readUInt64(at: sectionCursor + 40, bigEndian: false),
                  let offset = data.readUInt32(at: sectionCursor + 48, bigEndian: false),
                  let flags = data.readUInt32(at: sectionCursor + 64, bigEndian: false),
                  let reserved1 = data.readUInt32(at: sectionCursor + 68, bigEndian: false),
                  let reserved2 = data.readUInt32(at: sectionCursor + 72, bigEndian: false)
            else { return nil }

            if hashedSections.contains(where: { $0.segment == segmentName && $0.section == sectionName }) {
                let start = sliceOffset + Int(offset)
                let end = start + Int(size)
                guard start >= 0, end <= data.count, start <= end else { return nil }
                sections["\(segmentName),\(sectionName)"] = ContentHash.of(data.subdata(in: start ..< end))
            }

            do {
                if let linkageSection = try linkageSection(
                    segment: segmentName, section: sectionName, flags: flags,
                    size: size, reserved1: reserved1, reserved2: reserved2
                ) {
                    linkageSections.append(linkageSection)
                }
            } catch {
                // Declares a stub/lazy/non-lazy-pointer section whose own
                // size fields are internally inconsistent — malformed, not
                // "no linkage here".
                return nil
            }
        }

        return (sections, linkageSections)
    }

    private enum LinkageSectionError: Error { case malformed }

    /// `nil` when this section is not one of the three linkage kinds at all
    /// (an ordinary section); throws when it declares one of those kinds but
    /// its own size/stub-size fields are internally inconsistent.
    private static func linkageSection(
        segment: String, section: String, flags: UInt32, size: UInt64, reserved1: UInt32, reserved2: UInt32
    ) throws -> LinkageSection? {
        switch flags & sectionTypeMask {
        case sectionSymbolStubs:
            // reserved2 is the byte size of one stub; a section that
            // declares this type but a zero stub size is malformed, not "no
            // stubs".
            guard reserved2 > 0, size % UInt64(reserved2) == 0 else { throw LinkageSectionError.malformed }
            return LinkageSection(
                segment: segment, section: section,
                indirectSymbolIndex: Int(reserved1), slotCount: Int(size / UInt64(reserved2))
            )
        case sectionLazySymbolPointers, sectionNonLazySymbolPointers:
            // Pointer-sized (8 bytes on every current Apple 64-bit ABI)
            // slots; a size not a multiple of that is malformed.
            guard size % 8 == 0 else { throw LinkageSectionError.malformed }
            return LinkageSection(
                segment: segment, section: section,
                indirectSymbolIndex: Int(reserved1), slotCount: Int(size / 8)
            )
        default:
            return nil
        }
    }

    /// Hashes every allow-listed section's bytes, plus every symbol-stub/lazy-
    /// pointer/non-lazy-pointer section's resolved binding, in one Mach-O
    /// slice — combined into a single opaque identity string.
    ///
    /// Returns `nil` when the slice is unreadable, contains none of the
    /// allow-listed sections, or contains a linkage section this code cannot
    /// fully resolve (a malformed indirect symbol table, an out-of-range
    /// symbol index, a string-table read past `strsize`) — never a partial or
    /// substitute identity, which a caller could not distinguish from a real
    /// one over genuinely absent content. See the type's own doc comment for
    /// why an unresolvable linkage section fails the whole hash rather than
    /// being skipped.
    private static func semanticIdentity(in data: Data, sliceOffset: Int) -> String? {
        guard let magic = data.readUInt32(at: sliceOffset, bigEndian: false), magic == machO64 else {
            return nil
        }
        guard let commandCount = data.readUInt32(at: sliceOffset + 16, bigEndian: false) else {
            return nil
        }
        guard let walked = walkLoadCommands(in: data, sliceOffset: sliceOffset, commandCount: commandCount)
        else { return nil }
        guard !walked.sections.isEmpty else { return nil }

        let linkageRecords: [String]
        if walked.linkageSections.isEmpty {
            linkageRecords = []
        } else {
            // A binary that declares stub/lazy/non-lazy-pointer sections but
            // carries no symtab/dysymtab to resolve them against is
            // malformed, not "no linkage" — fails the whole identity per
            // this type's own fail-closed contract.
            guard let symtab = walked.symtab, let dysymtab = walked.dysymtab else { return nil }
            guard let resolved = resolvedLinkageRecords(
                sections: walked.linkageSections, symtab: symtab, dysymtab: dysymtab, data: data
            ) else { return nil }
            linkageRecords = resolved
        }

        // Sorted by name so load-command order cannot change the hash.
        let sectionsPreimage = walked.sections.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let linkagePreimage = linkageRecords.sorted().joined(separator: "\n")

        return ContentHash.of("sections\n\(sectionsPreimage)\nlinkage\n\(linkagePreimage)")
    }

    private struct LoadCommandWalkResult {
        var sections: [String: String] = [:]
        var linkageSections: [LinkageSection] = []
        var symtab: SymbolTableLocation?
        var dysymtab: IndirectSymbolTableLocation?
    }

    /// Walks every load command in one Mach-O slice, dispatching each kind
    /// this reader cares about to its own already-tested function. `nil` on
    /// any command this pass could not read — never a partial result.
    private static func walkLoadCommands(in data: Data, sliceOffset: Int, commandCount: UInt32) -> LoadCommandWalkResult? {
        var result = LoadCommandWalkResult()
        // mach_header_64 is 32 bytes; the load commands follow it.
        var cursor = sliceOffset + 32

        for _ in 0 ..< commandCount {
            guard let command = data.readUInt32(at: cursor, bigEndian: false),
                  let commandSize = data.readUInt32(at: cursor + 4, bigEndian: false),
                  commandSize >= 8
            else { return nil }

            switch command {
            case segmentCommand64:
                guard let contribution = segmentContribution(in: data, sliceOffset: sliceOffset, commandCursor: cursor)
                else { return nil }
                result.sections.merge(contribution.sections) { _, new in new }
                result.linkageSections.append(contentsOf: contribution.linkageSections)

            case symtabCommand:
                guard let location = symbolTableLocation(in: data, commandCursor: cursor) else { return nil }
                result.symtab = location

            case dysymtabCommand:
                guard let location = indirectSymbolTableLocation(in: data, commandCursor: cursor) else { return nil }
                result.dysymtab = location

            default:
                break
            }

            cursor += Int(commandSize)
        }

        return result
    }

    /// Resolves every linkage section's slots to the real symbol name (or a
    /// canonical `<local>`/`<absolute>` marker) each one binds to, via the
    /// indirect symbol table and, for a normal symbol index, the symbol and
    /// string tables `LC_SYMTAB` describes.
    ///
    /// `nil` on any malformed reference — an indirect-symbol-table index past
    /// `nindirectsyms`, a symbol index past `nsyms`, or a string-table read
    /// past `stroff + strsize` — never a partial result silently missing the
    /// slots that failed to resolve.
    private static func resolvedLinkageRecords(
        sections: [LinkageSection],
        symtab: SymbolTableLocation,
        dysymtab: IndirectSymbolTableLocation,
        data: Data
    ) -> [String]? {
        var records: [String] = []
        records.reserveCapacity(sections.reduce(0) { $0 + $1.slotCount })

        for section in sections {
            for slot in 0 ..< section.slotCount {
                let indirectIndex = section.indirectSymbolIndex + slot
                guard indirectIndex >= 0, indirectIndex < dysymtab.count else { return nil }
                guard let raw = data.readUInt32(
                    at: dysymtab.offset + indirectIndex * 4, bigEndian: false
                ) else { return nil }

                let symbolName: String
                if raw & indirectSymbolLocal != 0, raw & indirectSymbolAbs != 0 {
                    symbolName = "<local+absolute>"
                } else if raw & indirectSymbolLocal != 0 {
                    symbolName = "<local>"
                } else if raw & indirectSymbolAbs != 0 {
                    symbolName = "<absolute>"
                } else {
                    let symbolIndex = Int(raw)
                    guard symbolIndex >= 0, symbolIndex < symtab.symbolCount else { return nil }
                    // nlist_64: n_strx(4) is the entry's first field.
                    guard let strx = data.readUInt32(
                        at: symtab.symbolOffset + symbolIndex * 16, bigEndian: false
                    ) else { return nil }
                    let stringStart = symtab.stringOffset + Int(strx)
                    guard strx > 0, stringStart >= symtab.stringOffset,
                          stringStart < symtab.stringOffset + symtab.stringSize
                    else { return nil }
                    guard let name = data.readNulTerminatedString(
                        at: stringStart, limit: symtab.stringOffset + symtab.stringSize
                    ) else { return nil }
                    symbolName = name
                }

                records.append("\(section.segment),\(section.section)[\(slot)]=\(symbolName)")
            }
        }

        return records
    }
}

// MARK: - Bounds-checked reads

/// Reads for untrusted binary layout.
///
/// Every accessor returns `nil` rather than trapping: a truncated or hostile file
/// must degrade to "cannot hash this", never crash a run that is already hours in.
private extension Data {
    func readUInt32(at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let bytes = subdata(in: offset ..< offset + 4)
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return bigEndian ? value.bigEndian : value.littleEndian
    }

    func readUInt64(at offset: Int, bigEndian: Bool) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        let bytes = subdata(in: offset ..< offset + 8)
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        return bigEndian ? value.bigEndian : value.littleEndian
    }

    /// Reads a fixed-width, possibly unterminated name field.
    func readCString(at offset: Int, maxLength: Int) -> String? {
        guard offset >= 0, offset + maxLength <= count else { return nil }
        let bytes = subdata(in: offset ..< offset + maxLength)
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// Reads a NUL-terminated string starting at `offset`, never reading at
    /// or past `limit` — the string table's own declared bound. `nil` when
    /// no NUL byte appears before `limit`, which means the reference itself
    /// is malformed rather than merely long.
    func readNulTerminatedString(at offset: Int, limit: Int) -> String? {
        guard offset >= 0, limit <= count, offset < limit else { return nil }
        guard let nulIndex = self[offset ..< limit].firstIndex(of: 0) else { return nil }
        return String(decoding: self[offset ..< nulIndex], as: UTF8.self)
    }
}
