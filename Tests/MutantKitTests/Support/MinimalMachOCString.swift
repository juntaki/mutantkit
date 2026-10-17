import Foundation

/// Where `MachOCodeHash` tests pretend a build happened when they do not care.
let machOTestWorkspace = URL(fileURLWithPath: "/private/tmp/mk-ws-0000")

/// Hand-assembled Mach-O with an allow-listed `__TEXT,__text` and a `__TEXT,__cstring`
/// holding exactly the strings given, in order. No symbol tables: it carries no linkage
/// sections, so only the section bytes decide the hash.
enum MinimalMachOCString {
    static func build(strings: [String]) -> Data {
        let text = Data([0x1F, 0x20, 0x03, 0xD5])
        var cstring = Data()
        for string in strings {
            cstring.append(Data(string.utf8))
            cstring.append(0)
        }
        let headerSize = 32
        let sectionCount = 2
        let commandSize = 72 + 80 * sectionCount
        let textOffset = headerSize + commandSize
        let cstringOffset = textOffset + text.count
        var data = Data(count: cstringOffset + cstring.count)

        data.writeUInt32(0xFEED_FACF, at: 0)
        data.writeUInt32(0x0100_000C, at: 4)
        data.writeUInt32(1, at: 16) // ncmds
        data.writeUInt32(UInt32(commandSize), at: 20)

        data.writeUInt32(0x19, at: headerSize)
        data.writeUInt32(UInt32(commandSize), at: headerSize + 4)
        data.writeCString("__TEXT", at: headerSize + 8, maxLength: 16)
        data.writeUInt32(UInt32(sectionCount), at: headerSize + 64)

        func section(_ index: Int, name: String, offset: Int, size: Int) {
            let base = headerSize + 72 + index * 80
            data.writeCString(name, at: base, maxLength: 16)
            data.writeCString("__TEXT", at: base + 16, maxLength: 16)
            data.writeUInt64(UInt64(size), at: base + 40)
            data.writeUInt32(UInt32(offset), at: base + 48)
        }
        section(0, name: "__text", offset: textOffset, size: text.count)
        section(1, name: "__cstring", offset: cstringOffset, size: cstring.count)
        data.replaceSubrange(textOffset ..< textOffset + text.count, with: text)
        data.replaceSubrange(cstringOffset ..< cstringOffset + cstring.count, with: cstring)
        return data
    }
}
