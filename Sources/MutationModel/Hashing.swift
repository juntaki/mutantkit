import CryptoKit
import Foundation

/// Content hashing used for every anchor and evidence check.
///
/// Every hash the tool persists goes through here so that plan files, evidence
/// records and `verify` all agree on one spelling of "the hash of these bytes".
public enum ContentHash {
    /// Prefix makes the algorithm explicit in serialized output, so a future
    /// algorithm change is detectable rather than silently incompatible.
    public static let algorithmPrefix = "sha256:"

    public static func of(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return algorithmPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func of(_ string: String) -> String {
        of(Data(string.utf8))
    }

    public static func ofFile(at url: URL) throws -> String {
        of(try Data(contentsOf: url))
    }

    /// Truncated digest for identifiers that humans have to read and type.
    public static func shortDigest(of string: String, length: Int = 16) -> String {
        let full = of(string).dropFirst(algorithmPrefix.count)
        return String(full.prefix(length))
    }

    /// A deterministic 64-bit value derived from `string`, for identifiers a
    /// runtime has to compare cheaply at every mutated call site (see
    /// `SchemataSelectorToken.namespace`) rather than read as text. The first
    /// 16 hex digits of the SHA-256 digest always parse as a `UInt64`
    /// (16 hex digits is exactly 64 bits), so this never fails.
    public static func uint64(of string: String) -> UInt64 {
        let hex = shortDigest(of: string, length: 16)
        guard let value = UInt64(hex, radix: 16) else {
            preconditionFailure("a 16-hex-digit SHA-256 prefix must parse as UInt64")
        }
        return value
    }
}
