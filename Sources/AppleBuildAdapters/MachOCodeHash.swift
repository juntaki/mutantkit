import Foundation
import MutationModel

/// Hashes the executable code inside a Mach-O binary.
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
/// one silently enters the score.
enum MachOCodeHash {
    // On-disk magics, as read little-endian on the host.
    private static let machO64: UInt32 = 0xFEED_FACF
    /// Fat headers are big-endian on disk, so the host reads them byte-swapped.
    private static let fatBigEndian: UInt32 = 0xBEBA_FECA
    private static let fat64BigEndian: UInt32 = 0xBFBA_FECA

    private static let segmentCommand64: UInt32 = 0x19

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

    /// Hash of every architecture's semantic sections, or `nil` if the file is not
    /// a Mach-O this can read.
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
            guard let sections = semanticSections(in: data, sliceOffset: 0) else { return nil }
            return sections

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
        var slices: [(cpu: UInt32, hash: String)] = []

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

            guard let sections = semanticSections(in: data, sliceOffset: offset) else { return nil }
            slices.append((cpu, sections))
        }

        guard !slices.isEmpty else { return nil }
        // Sorted by CPU type so that lipo ordering cannot change the hash.
        return ContentHash.of(
            slices.sorted { $0.cpu < $1.cpu }
                .map { "\($0.cpu):\($0.hash)" }
                .joined(separator: "\n")
        )
    }

    /// Hashes every allow-listed section in one Mach-O slice.
    ///
    /// Returns `nil` when the slice is unreadable or contains none of them — never
    /// an empty hash, which a caller could not distinguish from a real one over no
    /// content.
    ///
    /// Absent sections are skipped rather than failing: a binary legitimately need
    /// not have `__DATA,__data`. Each contributing section is named in the
    /// preimage, so "section absent" and "section present but empty" cannot hash
    /// alike.
    private static func semanticSections(in data: Data, sliceOffset: Int) -> String? {
        guard let magic = data.readUInt32(at: sliceOffset, bigEndian: false), magic == machO64 else {
            return nil
        }
        guard let commandCount = data.readUInt32(at: sliceOffset + 16, bigEndian: false) else {
            return nil
        }

        var found: [String: String] = [:]

        // mach_header_64 is 32 bytes; the load commands follow it.
        var cursor = sliceOffset + 32

        for _ in 0 ..< commandCount {
            guard let command = data.readUInt32(at: cursor, bigEndian: false),
                  let commandSize = data.readUInt32(at: cursor + 4, bigEndian: false),
                  commandSize >= 8
            else { return nil }

            if command == segmentCommand64,
               let segmentName = data.readCString(at: cursor + 8, maxLength: 16),
               let sectionCount = data.readUInt32(at: cursor + 64, bigEndian: false) {
                // segment_command_64 is 72 bytes; section_64 entries follow it.
                var sectionCursor = cursor + 72
                for _ in 0 ..< sectionCount {
                    defer { sectionCursor += 80 }

                    guard let sectionName = data.readCString(at: sectionCursor, maxLength: 16),
                          hashedSections.contains(where: { $0.segment == segmentName && $0.section == sectionName }),
                          let size = data.readUInt64(at: sectionCursor + 40, bigEndian: false),
                          let offset = data.readUInt32(at: sectionCursor + 48, bigEndian: false)
                    else { continue }

                    let start = sliceOffset + Int(offset)
                    let end = start + Int(size)
                    guard start >= 0, end <= data.count, start <= end else { return nil }

                    found["\(segmentName),\(sectionName)"] = ContentHash.of(data.subdata(in: start ..< end))
                }
            }

            cursor += Int(commandSize)
        }

        guard !found.isEmpty else { return nil }

        // Sorted by name so load-command order cannot change the hash.
        return ContentHash.of(
            found.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
        )
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
}
