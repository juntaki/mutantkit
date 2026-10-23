@testable import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// The fat-binary path hashes every slice, keyed by the slice's CPU type read
/// from the big-endian `fat_arch` table. These tests build a universal binary
/// by hand so the expected hash is derived independently of the code under
/// test, and pin both the CPU type and the lipo-order independence.
@Suite("Mach-O code hash: universal binaries")
struct MachOCodeHashFatBinaryTests {
    private static let arm64: UInt32 = 0x0100_000C
    private static let intel64: UInt32 = 0x0100_0007

    private struct Slice {
        let cpu: UInt32
        let data: Data
    }

    /// `fat_header` followed by one 20-byte `fat_arch` per slice; every field is big-endian.
    private static func fat(_ slices: [Slice]) -> Data {
        let tableEnd = 8 + slices.count * 20
        var offsets: [Int] = []
        var next = (tableEnd + 0xFFF) & ~0xFFF
        for slice in slices {
            offsets.append(next)
            next = (next + slice.data.count + 0xFFF) & ~0xFFF
        }

        var data = Data()
        func append(_ value: UInt32) {
            data.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
        append(0xCAFE_BABE)
        append(UInt32(slices.count))
        for (index, slice) in slices.enumerated() {
            append(slice.cpu)
            append(0) // cpusubtype
            append(UInt32(offsets[index]))
            append(UInt32(slice.data.count))
            append(14) // align (2^14)
        }
        for (index, slice) in slices.enumerated() {
            data.append(Data(count: offsets[index] - data.count))
            data.append(slice.data)
        }
        return data
    }

    private func thinIdentity(_ data: Data) throws -> String {
        let hash = try #require(MachOCodeHash.codeHash(of: data, workspaceRoot: machOTestWorkspace))
        return String(hash.dropFirst("v3:".count))
    }

    @Test("A universal binary hashes each slice under its CPU type")
    func hashesEverySliceUnderItsCPUType() throws {
        let armSlice = try MinimalMachO.build(stubBoundToSymbolIndex: 0).data
        let x86Slice = try MinimalMachO.build(stubBoundToSymbolIndex: 1).data
        let universal = Self.fat([Slice(cpu: Self.arm64, data: armSlice), Slice(cpu: Self.intel64, data: x86Slice)])

        let hash = try #require(MachOCodeHash.codeHash(of: universal, workspaceRoot: machOTestWorkspace))

        // Sorted by CPU type: intel64 (…07) precedes arm64 (…0C).
        let preimage = "\(Self.intel64):\(try thinIdentity(x86Slice))\n\(Self.arm64):\(try thinIdentity(armSlice))"
        #expect(hash == "v3:\(ContentHash.of(preimage))")
    }

    @Test("The order the slices were lipo'd in does not change the hash")
    func sliceOrderDoesNotChangeTheHash() throws {
        let armSlice = Slice(cpu: Self.arm64, data: try MinimalMachO.build(stubBoundToSymbolIndex: 0).data)
        let x86Slice = Slice(cpu: Self.intel64, data: try MinimalMachO.build(stubBoundToSymbolIndex: 1).data)

        let one = MachOCodeHash.codeHash(of: Self.fat([armSlice, x86Slice]), workspaceRoot: machOTestWorkspace)
        let other = MachOCodeHash.codeHash(of: Self.fat([x86Slice, armSlice]), workspaceRoot: machOTestWorkspace)
        #expect(one != nil)
        #expect(one == other)
    }

    @Test("Changing one slice changes the universal hash")
    func changingOneSliceChangesTheHash() throws {
        let armSlice = Slice(cpu: Self.arm64, data: try MinimalMachO.build(stubBoundToSymbolIndex: 0).data)
        let x86A = Slice(cpu: Self.intel64, data: try MinimalMachO.build(stubBoundToSymbolIndex: 0).data)
        let x86B = Slice(cpu: Self.intel64, data: try MinimalMachO.build(stubBoundToSymbolIndex: 1).data)

        let first = MachOCodeHash.codeHash(of: Self.fat([armSlice, x86A]), workspaceRoot: machOTestWorkspace)
        let second = MachOCodeHash.codeHash(of: Self.fat([armSlice, x86B]), workspaceRoot: machOTestWorkspace)
        #expect(first != second)
    }
}
