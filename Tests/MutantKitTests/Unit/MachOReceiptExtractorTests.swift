@testable import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// `MachOReceiptExtractor` is the build-time half of ADR-0006 Stage 2's
/// proof chain: a `SchemataBuildReceipt` can only claim a real per-image
/// `LC_UUID` if this parser refuses everything it cannot prove -- a
/// truncated file, a missing UUID, two conflicting UUIDs in one slice --
/// rather than guessing or picking a winner.
///
/// Hand-crafted Mach-O bytes cover every negative case precisely (a real
/// compiler never produces a duplicate `LC_UUID`, say, so the only way to
/// exercise that path is to construct it directly). A real `swiftc`-built
/// binary at the bottom of this file, cross-checked against `dwarfdump`'s
/// own reading of the same file, closes the gap hand-crafted bytes leave
/// open: proof that the byte layout this parser assumes matches what the
/// actual toolchain on this machine produces.
@Suite("Mach-O receipt extractor")
struct MachOReceiptExtractorTests {
    // MARK: - mach_header_64 layout constants (LC_UUID = 0x1b)

    private static let cpuTypeARM64: Int32 = 0x0100_000C
    private static let cpuTypeX8664: Int32 = 0x0100_0007

    private func machHeader64(cpuType: Int32, cpuSubtype: Int32, ncmds: UInt32, sizeofcmds: UInt32) -> Data {
        var data = Data()
        data.appendLE(UInt32(0xFEED_FACF)) // magic
        data.appendLE(UInt32(bitPattern: cpuType))
        data.appendLE(UInt32(bitPattern: cpuSubtype))
        data.appendLE(UInt32(2)) // filetype: MH_EXECUTE
        data.appendLE(ncmds)
        data.appendLE(sizeofcmds)
        data.appendLE(UInt32(0)) // flags
        data.appendLE(UInt32(0)) // reserved
        return data
    }

    private func uuidLoadCommand(_ uuid: [UInt8]) -> Data {
        precondition(uuid.count == 16)
        var data = Data()
        data.appendLE(UInt32(0x1B)) // LC_UUID
        data.appendLE(UInt32(24)) // cmdsize
        data.append(contentsOf: uuid)
        return data
    }

    private func genericLoadCommand(cmd: UInt32, cmdsize: UInt32) -> Data {
        var data = Data()
        data.appendLE(cmd)
        data.appendLE(cmdsize)
        data.append(Data(repeating: 0, count: max(0, Int(cmdsize) - 8)))
        return data
    }

    private func validThinSlice(uuid: [UInt8] = Array(0 ..< 16), cpuType: Int32 = cpuTypeARM64) -> Data {
        let uuidCommand = uuidLoadCommand(uuid)
        var data = machHeader64(cpuType: cpuType, cpuSubtype: 0, ncmds: 1, sizeofcmds: UInt32(uuidCommand.count))
        data.append(uuidCommand)
        return data
    }

    // MARK: - Thin, valid

    @Test("a thin arm64 slice with one LC_UUID is read correctly")
    func thinARM64Succeeds() throws {
        let uuid: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]
        let data = validThinSlice(uuid: uuid, cpuType: Self.cpuTypeARM64)

        let image = try MachOReceiptExtractor.inspectImage(data: data)

        #expect(image.slices.count == 1)
        #expect(image.slices[0].architecture.description == "arm64")
        #expect(image.slices[0].imageUUID.rawValue == "0102030405060708090a0b0c0d0e0f10")
    }

    @Test("a thin x86_64 slice with one LC_UUID is read correctly")
    func thinX86_64Succeeds() throws {
        let data = validThinSlice(cpuType: Self.cpuTypeX8664)

        let image = try MachOReceiptExtractor.inspectImage(data: data)

        #expect(image.slices.count == 1)
        #expect(image.slices[0].architecture.description == "x86_64")
    }

    @Test("contentHash is deterministic and differs when the bytes differ")
    func contentHashDiffersWithBytes() throws {
        let a = try MachOReceiptExtractor.inspectImage(data: validThinSlice(uuid: Array(0 ..< 16)))
        let b = try MachOReceiptExtractor.inspectImage(data: validThinSlice(uuid: Array(1 ..< 17)))
        #expect(a.contentHash != b.contentHash)
    }

    // MARK: - Universal (fat), valid

    @Test("a universal binary with two architectures reports two independent UUIDs")
    func universalBinaryReportsBothSlices() throws {
        let armUUID: [UInt8] = Array(repeating: 0xAA, count: 16)
        let x86UUID: [UInt8] = Array(repeating: 0xBB, count: 16)
        let armSlice = validThinSlice(uuid: armUUID, cpuType: Self.cpuTypeARM64)
        let x86Slice = validThinSlice(uuid: x86UUID, cpuType: Self.cpuTypeX8664)

        // fat_header (8 bytes, big-endian) + two fat_arch (20 bytes each,
        // big-endian): cputype, cpusubtype, offset, size, align.
        var data = Data()
        data.appendBE(UInt32(0xCAFE_BABE)) // FAT_MAGIC
        data.appendBE(UInt32(2)) // nfat_arch

        let armOffset = 8 + 2 * 20
        let x86Offset = armOffset + armSlice.count

        data.appendBE(UInt32(bitPattern: Self.cpuTypeARM64))
        data.appendBE(UInt32(0))
        data.appendBE(UInt32(armOffset))
        data.appendBE(UInt32(armSlice.count))
        data.appendBE(UInt32(0)) // align

        data.appendBE(UInt32(bitPattern: Self.cpuTypeX8664))
        data.appendBE(UInt32(0))
        data.appendBE(UInt32(x86Offset))
        data.appendBE(UInt32(x86Slice.count))
        data.appendBE(UInt32(0)) // align

        data.append(armSlice)
        data.append(x86Slice)

        let image = try MachOReceiptExtractor.inspectImage(data: data)

        #expect(image.slices.count == 2)
        let uuidsByArch = Dictionary(uniqueKeysWithValues: image.slices.map { ($0.architecture.description, $0.imageUUID.rawValue) })
        #expect(uuidsByArch["arm64"] == armUUID.map { String(format: "%02x", $0) }.joined())
        #expect(uuidsByArch["x86_64"] == x86UUID.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - Negative: magic / byte order

    @Test("an unrecognized magic number is refused")
    func unrecognizedMagicIsRefused() {
        let data = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(throws: MachOInspectionError.unrecognizedMagic) {
            _ = try MachOReceiptExtractor.inspectImage(data: data)
        }
    }

    @Test("a byte-swapped (opposite-endian) thin Mach-O is refused, not misparsed")
    func byteSwappedMachOIsRefused() {
        var data = Data()
        data.appendLE(UInt32(0xCFFA_EDFE)) // MH_CIGAM_64
        data.append(Data(repeating: 0, count: 28))
        #expect(throws: MachOInspectionError.unsupportedByteOrder) {
            _ = try MachOReceiptExtractor.inspectImage(data: data)
        }
    }

    // MARK: - Negative: truncation

    @Test("a file shorter than the magic number is refused")
    func emptyFileIsRefused() {
        #expect(throws: MachOInspectionError.self) {
            _ = try MachOReceiptExtractor.inspectImage(data: Data())
        }
    }

    @Test("a header claiming more load commands than the file contains is truncated")
    func truncatedLoadCommandsAreRefused() {
        // ncmds says 1, but no load command bytes follow the header at all.
        let data = machHeader64(cpuType: Self.cpuTypeARM64, cpuSubtype: 0, ncmds: 1, sizeofcmds: 24)
        #expect(throws: MachOInspectionError.truncated) {
            _ = try MachOReceiptExtractor.inspectImage(data: data)
        }
    }

    @Test("a load command whose cmdsize extends past the slice end is truncated")
    func loadCommandOverrunIsTruncated() {
        var data = machHeader64(cpuType: Self.cpuTypeARM64, cpuSubtype: 0, ncmds: 1, sizeofcmds: 1000)
        // Claims cmdsize 1000 but only 8 bytes of command data actually follow.
        data.appendLE(UInt32(0x1B))
        data.appendLE(UInt32(1000))
        #expect(throws: MachOInspectionError.truncated) {
            _ = try MachOReceiptExtractor.inspectImage(data: data)
        }
    }

    // MARK: - Negative: invalid cmdsize

    @Test("a load command with cmdsize smaller than its own 8-byte header is refused")
    func tooSmallCmdsizeIsRefused() {
        var data = machHeader64(cpuType: Self.cpuTypeARM64, cpuSubtype: 0, ncmds: 1, sizeofcmds: 4)
        data.appendLE(UInt32(0x1B))
        data.appendLE(UInt32(4)) // smaller than the 8-byte cmd+cmdsize header itself
        #expect(throws: MachOInspectionError.invalidLoadCommandSize) {
            _ = try MachOReceiptExtractor.inspectImage(data: data)
        }
    }

    @Test("an LC_UUID command with cmdsize too small to hold a UUID is refused")
    func lcUUIDWithTooSmallCmdsizeIsRefused() {
        var data = machHeader64(cpuType: Self.cpuTypeARM64, cpuSubtype: 0, ncmds: 1, sizeofcmds: 16)
        data.appendLE(UInt32(0x1B)) // LC_UUID
        data.appendLE(UInt32(16)) // too small to hold cmd+cmdsize+16-byte uuid (needs 24)
        data.append(Data(repeating: 0, count: 8))
        #expect(throws: MachOInspectionError.invalidLoadCommandSize) {
            _ = try MachOReceiptExtractor.inspectImage(data: data)
        }
    }

    // MARK: - Negative: missing / duplicate UUID

    @Test("a slice with no LC_UUID command is refused")
    func missingUUIDIsRefused() {
        let other = genericLoadCommand(cmd: 0x20, cmdsize: 16)
        var data = machHeader64(cpuType: Self.cpuTypeARM64, cpuSubtype: 0, ncmds: 1, sizeofcmds: UInt32(other.count))
        data.append(other)
        #expect(throws: MachOInspectionError.missingUUID) {
            _ = try MachOReceiptExtractor.inspectImage(data: data)
        }
    }

    @Test("a slice with two LC_UUID commands is refused, not resolved by picking one")
    func duplicateUUIDIsRefused() {
        let first = uuidLoadCommand(Array(repeating: 0xAA, count: 16))
        let second = uuidLoadCommand(Array(repeating: 0xBB, count: 16))
        var data = machHeader64(cpuType: Self.cpuTypeARM64, cpuSubtype: 0, ncmds: 2, sizeofcmds: UInt32(first.count + second.count))
        data.append(first)
        data.append(second)
        #expect(throws: MachOInspectionError.duplicateUUID) {
            _ = try MachOReceiptExtractor.inspectImage(data: data)
        }
    }

    // MARK: - Negative: fat header

    @Test("a fat header claiming zero architectures is refused")
    func fatHeaderWithZeroArchitecturesIsRefused() {
        var data = Data()
        data.appendBE(UInt32(0xCAFE_BABE))
        data.appendBE(UInt32(0))
        #expect(throws: MachOInspectionError.malformedFatHeader) {
            _ = try MachOReceiptExtractor.inspectImage(data: data)
        }
    }

    @Test("a fat architecture entry whose slice range extends past the file is truncated")
    func fatArchitectureOverrunIsTruncated() {
        var data = Data()
        data.appendBE(UInt32(0xCAFE_BABE))
        data.appendBE(UInt32(1))
        data.appendBE(UInt32(bitPattern: Self.cpuTypeARM64))
        data.appendBE(UInt32(0))
        data.appendBE(UInt32(1000)) // offset far past the (tiny) file
        data.appendBE(UInt32(100))
        data.appendBE(UInt32(0))
        #expect(throws: MachOInspectionError.truncated) {
            _ = try MachOReceiptExtractor.inspectImage(data: data)
        }
    }

    // MARK: - Real fixture: an actual swiftc-built binary

    /// Hand-crafted bytes prove the parser's error handling; they cannot
    /// prove the parser's happy-path byte-offset assumptions match what a
    /// real toolchain actually emits. This compiles a trivial program with
    /// the `swiftc` on this machine and cross-checks the parsed UUID
    /// against `dwarfdump --uuid`'s own independent reading of the same
    /// file -- two different tools agreeing on the same bytes is the
    /// closest this test can get to ground truth.
    @Test("a real swiftc-built binary's LC_UUID matches dwarfdump's own reading")
    func realBuiltBinaryUUIDMatchesDwarfdump() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macho-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("main.swift")
        try Data("print(\"hi\")\n".utf8).write(to: sourceURL)
        let binaryURL = root.appendingPathComponent("fixture")

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        compile.arguments = ["swiftc", sourceURL.path, "-o", binaryURL.path]
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0, "swiftc must be available to build the real fixture")

        let image = try MachOReceiptExtractor().inspectImage(at: binaryURL)
        #expect(!image.slices.isEmpty)

        let dwarfdump = Process()
        dwarfdump.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        dwarfdump.arguments = ["dwarfdump", "--uuid", binaryURL.path]
        let pipe = Pipe()
        dwarfdump.standardOutput = pipe
        try dwarfdump.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        dwarfdump.waitUntilExit()
        try #require(dwarfdump.terminationStatus == 0, "dwarfdump must be available to cross-check the fixture")

        // dwarfdump prints one "UUID: <hyphenated> (<arch>) path" line per slice.
        let dwarfdumpUUIDs = Set(
            output.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("UUID: ") else { return nil }
                let hyphenated = line.dropFirst("UUID: ".count).split(separator: " ").first.map(String.init) ?? ""
                return hyphenated.replacingOccurrences(of: "-", with: "").lowercased()
            }
        )
        let parsedUUIDs = Set(image.slices.map(\.imageUUID.rawValue))

        #expect(!dwarfdumpUUIDs.isEmpty)
        #expect(parsedUUIDs == dwarfdumpUUIDs)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
