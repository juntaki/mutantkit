import Foundation
import MutationModel

/// What went wrong reading a Mach-O binary for its build-receipt identity.
///
/// Every case is a refusal, never a guess: `SchemataBuildReceipt` (ADR-0006
/// Stage 2) exists so a mutation's proof chain can require an exact,
/// unambiguous per-image identity. A parser that silently accepted a
/// truncated file or picked one of two conflicting `LC_UUID` commands would
/// hand the verifier a value that looks trustworthy but is not.
public enum MachOInspectionError: Error, CustomStringConvertible, Equatable, Sendable {
    case unreadableFile(String)
    case unrecognizedMagic
    case unsupportedByteOrder
    case truncated
    case invalidLoadCommandSize
    case missingUUID
    case duplicateUUID
    case malformedFatHeader
    case tooManyFatArchitectures(Int)

    public var description: String {
        switch self {
        case let .unreadableFile(reason):
            "could not read the file: \(reason)"
        case .unrecognizedMagic:
            "not a Mach-O (or fat/universal) file this extractor recognizes"
        case .unsupportedByteOrder:
            "byte-swapped (opposite-endian) Mach-O is not supported"
        case .truncated:
            "a load command, section, or fat architecture entry extends past the end of its slice"
        case .invalidLoadCommandSize:
            "a load command's cmdsize is smaller than its own header requires"
        case .missingUUID:
            "no LC_UUID load command was found in a Mach-O slice"
        case .duplicateUUID:
            "more than one LC_UUID load command was found in the same Mach-O slice"
        case .malformedFatHeader:
            "a fat (universal) header's architecture table is malformed"
        case let .tooManyFatArchitectures(count):
            "a fat header claims \(count) architectures, more than this extractor will parse"
        }
    }
}

/// A CPU type/subtype pair, rendered as the conventional architecture name
/// (`arm64`, `x86_64`) when recognized. Never collapsed into a single
/// "the" architecture for a universal binary — see `InspectedMachOImage`.
public struct ArchitectureIdentity: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let cpuType: Int32
    public let cpuSubtype: Int32

    public init(cpuType: Int32, cpuSubtype: Int32) {
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
    }

    private static let arm64: Int32 = 0x0100_000C
    private static let x8664: Int32 = 0x0100_0007

    public var description: String {
        switch cpuType {
        case Self.arm64: "arm64"
        case Self.x8664: "x86_64"
        default: "cpu_\(String(UInt32(bitPattern: cpuType), radix: 16))_sub_\(String(UInt32(bitPattern: cpuSubtype), radix: 16))"
        }
    }
}

/// One architecture slice's identity within a (possibly universal) Mach-O
/// image — its own `LC_UUID`, never averaged or picked as "the" UUID for
/// the whole file. A universal binary's arm64 and x86_64 slices routinely
/// carry different UUIDs; collapsing them to one early would make it
/// impossible to tell which slice a runtime event's `imageUUID` actually
/// came from.
public struct MachOSliceReceipt: Sendable, Equatable {
    public let architecture: ArchitectureIdentity
    public let imageUUID: ImageUUID

    public init(architecture: ArchitectureIdentity, imageUUID: ImageUUID) {
        self.architecture = architecture
        self.imageUUID = imageUUID
    }
}

/// The result of inspecting one built Mach-O file — thin or universal.
///
/// `contentHash` is a whole-file hash (unlike `MachOCodeHash`'s
/// semantic-section hash, which deliberately excludes `LC_UUID` and other
/// path-dependent bytes so it can compare a mutant against its baseline):
/// this type exists to *identify* a specific built artifact for a build
/// receipt, not to detect whether a mutation reached it.
public struct InspectedMachOImage: Sendable, Equatable {
    public let contentHash: SHA256Digest
    public let slices: [MachOSliceReceipt]

    public init(contentHash: SHA256Digest, slices: [MachOSliceReceipt]) {
        self.contentHash = contentHash
        self.slices = slices
    }
}

/// Reads a built Mach-O file's per-architecture `LC_UUID` identity.
/// Injectable so a future non-Apple-toolchain build path (or a test) can
/// substitute a different inspector without `SchemataBuildReceipt`
/// construction caring which one produced its receipts.
public protocol BuiltImageInspecting: Sendable {
    func inspectImage(at url: URL) throws -> InspectedMachOImage
}

/// A minimal Mach-O/fat parser: mach_header_64 and LC_UUID only. No
/// symbol table, no relocations, no code signature — this extractor exists
/// to answer exactly one question (what UUID does each architecture slice
/// of this file carry) and reads only what answering it requires.
///
/// 32-bit and byte-swapped (opposite-endian) Mach-O are out of scope: no
/// current Apple toolchain produces either for a build this tool runs
/// against, and pretending to support them without a way to test them
/// would be worse than refusing them outright (`unsupportedByteOrder`).
public struct MachOReceiptExtractor: BuiltImageInspecting {
    public init() {}

    public func inspectImage(at url: URL) throws -> InspectedMachOImage {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw MachOInspectionError.unreadableFile(error.localizedDescription)
        }
        return try Self.inspectImage(data: data)
    }

    static func inspectImage(data: Data) throws -> InspectedMachOImage {
        guard let nativeMagic = data.readUInt32(at: 0, bigEndian: false) else {
            throw MachOInspectionError.unreadableFile("file is shorter than a Mach-O magic number")
        }

        let slices: [MachOSliceReceipt]
        switch nativeMagic {
        case machHeader64Magic:
            slices = [try parseThinSlice(in: data, sliceRange: 0 ..< data.count)]
        case machHeader64CigamMagic:
            throw MachOInspectionError.unsupportedByteOrder
        default:
            guard let bigEndianMagic = data.readUInt32(at: 0, bigEndian: true),
                  bigEndianMagic == fatMagic || bigEndianMagic == fatMagic64
            else {
                throw MachOInspectionError.unrecognizedMagic
            }
            slices = try parseFatSlices(in: data, is64: bigEndianMagic == fatMagic64)
        }

        return InspectedMachOImage(contentHash: SHA256Digest.of(data), slices: slices)
    }

    // MARK: - Constants

    private static let machHeader64Magic: UInt32 = 0xFEED_FACF
    private static let machHeader64CigamMagic: UInt32 = 0xCFFA_EDFE
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let loadCommandUUID: UInt32 = 0x1B
    /// A malformed architecture count must not turn into an unbounded loop
    /// over a hostile or corrupt file; no real universal binary comes
    /// close to this many slices.
    private static let maxFatArchitectures = 64

    // MARK: - Fat (universal) header

    private static func parseFatSlices(in data: Data, is64: Bool) throws -> [MachOSliceReceipt] {
        guard let count = data.readUInt32(at: 4, bigEndian: true), count > 0 else {
            throw MachOInspectionError.malformedFatHeader
        }
        guard count < maxFatArchitectures else {
            throw MachOInspectionError.tooManyFatArchitectures(Int(count))
        }

        let archEntrySize = is64 ? 32 : 20
        var slices: [MachOSliceReceipt] = []

        for index in 0 ..< Int(count) {
            let base = 8 + index * archEntrySize
            guard data.hasBytes(at: base, count: archEntrySize) else {
                throw MachOInspectionError.truncated
            }

            let offset: Int
            let size: Int
            if is64 {
                guard let offsetValue = data.readUInt64(at: base + 8, bigEndian: true),
                      let sizeValue = data.readUInt64(at: base + 16, bigEndian: true)
                else { throw MachOInspectionError.malformedFatHeader }
                offset = Int(offsetValue)
                size = Int(sizeValue)
            } else {
                guard let offsetValue = data.readUInt32(at: base + 8, bigEndian: true),
                      let sizeValue = data.readUInt32(at: base + 12, bigEndian: true)
                else { throw MachOInspectionError.malformedFatHeader }
                offset = Int(offsetValue)
                size = Int(sizeValue)
            }

            guard offset >= 0, size >= 0, offset + size <= data.count else {
                throw MachOInspectionError.truncated
            }

            slices.append(try parseThinSlice(in: data, sliceRange: offset ..< (offset + size)))
        }

        return slices
    }

    // MARK: - One Mach-O slice

    private static func parseThinSlice(in data: Data, sliceRange: Range<Int>) throws -> MachOSliceReceipt {
        let sliceOffset = sliceRange.lowerBound
        guard let magic = data.readUInt32(at: sliceOffset, bigEndian: false), magic == machHeader64Magic else {
            throw MachOInspectionError.unrecognizedMagic
        }
        guard let cpuType = data.readInt32(at: sliceOffset + 4),
              let cpuSubtype = data.readInt32(at: sliceOffset + 8),
              let commandCount = data.readUInt32(at: sliceOffset + 16, bigEndian: false)
        else {
            throw MachOInspectionError.truncated
        }

        // mach_header_64 is 32 bytes; load commands follow it.
        var cursor = sliceOffset + 32
        var uuid: ImageUUID?

        for _ in 0 ..< commandCount {
            guard let command = data.readUInt32(at: cursor, bigEndian: false),
                  let commandSize = data.readUInt32(at: cursor + 4, bigEndian: false)
            else {
                throw MachOInspectionError.truncated
            }
            guard commandSize >= 8 else {
                throw MachOInspectionError.invalidLoadCommandSize
            }
            guard cursor + Int(commandSize) <= sliceRange.upperBound else {
                throw MachOInspectionError.truncated
            }

            if command == loadCommandUUID {
                guard commandSize >= 24 else { throw MachOInspectionError.invalidLoadCommandSize }
                guard let uuidBytes = data.readBytes(at: cursor + 8, count: 16) else {
                    throw MachOInspectionError.truncated
                }
                let hex = uuidBytes.map { String(format: "%02x", $0) }.joined()
                guard let parsed = ImageUUID(rawValue: hex) else {
                    // 16 bytes rendered as 32 lowercase hex characters always
                    // validates; unreachable, but a parse failure here must
                    // still refuse rather than fabricate an identity.
                    throw MachOInspectionError.truncated
                }
                guard uuid == nil else { throw MachOInspectionError.duplicateUUID }
                uuid = parsed
            }

            cursor += Int(commandSize)
        }

        guard let resolvedUUID = uuid else { throw MachOInspectionError.missingUUID }

        return MachOSliceReceipt(
            architecture: ArchitectureIdentity(cpuType: cpuType, cpuSubtype: cpuSubtype),
            imageUUID: resolvedUUID
        )
    }
}

// MARK: - Bounds-checked reads

/// Reads for untrusted binary layout — every accessor returns `nil`/throws
/// rather than trapping. A truncated or hostile file must degrade to a
/// refusal, never crash a run that is already hours in (the same discipline
/// `MachOCodeHash`'s own reader extension applies).
private extension Data {
    func hasBytes(at offset: Int, count: Int) -> Bool {
        offset >= 0 && offset + count <= self.count
    }

    func readUInt32(at offset: Int, bigEndian: Bool) -> UInt32? {
        guard hasBytes(at: offset, count: 4) else { return nil }
        let bytes = subdata(in: offset ..< offset + 4)
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return bigEndian ? value.bigEndian : value.littleEndian
    }

    func readInt32(at offset: Int) -> Int32? {
        guard let value = readUInt32(at: offset, bigEndian: false) else { return nil }
        return Int32(bitPattern: value)
    }

    func readUInt64(at offset: Int, bigEndian: Bool) -> UInt64? {
        guard hasBytes(at: offset, count: 8) else { return nil }
        let bytes = subdata(in: offset ..< offset + 8)
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        return bigEndian ? value.bigEndian : value.littleEndian
    }

    func readBytes(at offset: Int, count: Int) -> [UInt8]? {
        guard hasBytes(at: offset, count: count) else { return nil }
        return Array(subdata(in: offset ..< offset + count))
    }
}
