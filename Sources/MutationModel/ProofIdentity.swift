import CryptoKit
import Foundation

/// A strong identity type backed by fixed-length lowercase hex — never a raw
/// `String` at a proof-chain boundary. `RawValue == String` (for
/// `RawRepresentable`'s sake) is validated on construction: nothing between
/// this type's initializer and its use ever holds an unvalidated value, so a
/// verifier comparing two of these is comparing two things that have already
/// proven they are the right shape, not hoping a caller upheld it.
public protocol HexIdentity: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    /// The exact character count every valid value must have — 64 for a
    /// SHA-256 digest, 32 for a Mach-O `LC_UUID` rendered without hyphens.
    static var hexLength: Int { get }
}

extension HexIdentity {
    /// Shared validation every conforming type's `init?(rawValue:)` defers
    /// to, so "what counts as valid hex" is defined exactly once.
    static func isValidHex(_ value: String) -> Bool {
        guard value.utf8.count == hexLength else { return false }
        return value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}

/// A single-value string, not `{"rawValue": "..."}` — every proof-chain
/// record that carries one of these (a build receipt, a runtime event) reads
/// as plain hex in `report.json`, matching how `MutationID` already encodes.
/// Critically, this routes decode through the validating `init?(rawValue:)`
/// rather than the plain memberwise synthesis a bare `Codable` conformance
/// would otherwise get — a malformed or wrong-length hex string in a
/// hand-edited cache/checkpoint file must fail to decode, not silently
/// become a value nothing upstream validated.
public extension HexIdentity {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "not a valid \(Self.self): \(raw)")
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A SHA-256 digest, rendered as 64 lowercase hex characters — no
/// `sha256:` prefix (unlike `ContentHash.of`'s display string), because this
/// type is a proof-chain identity compared for equality, never displayed
/// with its algorithm name attached.
public struct SHA256Digest: HexIdentity {
    public static let hexLength = 64

    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValidHex(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static func of(_ data: Data) -> SHA256Digest {
        let digest = CryptoKit.SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard let value = SHA256Digest(rawValue: hex) else {
            preconditionFailure("a SHA-256 digest formatted as 64 lowercase hex characters must always validate")
        }
        return value
    }

    public static func of(_ string: String) -> SHA256Digest {
        of(Data(string.utf8))
    }

    public static func ofFile(at url: URL) throws -> SHA256Digest {
        of(try Data(contentsOf: url))
    }
}

/// A Mach-O `LC_UUID` load command's UUID, rendered as 32 lowercase hex
/// characters with no hyphens — the canonical internal form. Display code
/// (a CLI diagnostic, say) is free to hyphenate for a human to read; nothing
/// that compares two `ImageUUID`s ever sees a hyphenated form, so a
/// formatting difference between "how `otool -l` prints it" and "how this
/// tool parsed it" can never masquerade as two different images.
public struct ImageUUID: HexIdentity {
    public static let hexLength = 32

    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValidHex(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(uuid: UUID) {
        let hex = uuid.uuid16Bytes.map { String(format: "%02x", $0) }.joined()
        guard let value = ImageUUID(rawValue: hex) else {
            preconditionFailure("a UUID's 16 bytes rendered as 32 lowercase hex characters must always validate")
        }
        self = value
    }
}

private extension UUID {
    var uuid16Bytes: [UInt8] {
        let u = uuid
        return [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15
        ]
    }
}

/// Identifies one compilation unit a schemata build embeds a mutation into —
/// the thing a generated call site's compilation-unit descriptor proves it
/// was compiled as part of, independent of which Mach-O image ends up
/// linking it. A `SHA256Digest`, not a bare string, so the proof chain's
/// equality checks are all the same "is this a validated 64-hex-character
/// digest" shape, never a raw path or name compared by coincidence.
public struct CompilationUnitID: HexIdentity {
    public static let hexLength = 64

    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValidHex(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Derives a `CompilationUnitID` from every input that determines which
    /// compilation unit a generated call site belongs to. An explicit,
    /// ordered, delimited string (mirroring `MutationID.compute`'s own
    /// reasoning) keeps the hash inputs auditable: a reader can reconstruct
    /// the preimage by hand rather than trust an opaque combination.
    public static func derive(
        projectIdentity: String, target: String, module: String, sourcePath: String,
        lowererID: String, lowererVersion: Int
    ) -> CompilationUnitID {
        let separator = "\u{1F}"
        let canonical = [projectIdentity, target, module, sourcePath, lowererID, String(lowererVersion)]
            .joined(separator: separator)
        return SHA256Digest.of(canonical).asCompilationUnitID
    }
}

private extension SHA256Digest {
    var asCompilationUnitID: CompilationUnitID {
        guard let value = CompilationUnitID(rawValue: rawValue) else {
            preconditionFailure("SHA256Digest and CompilationUnitID share the same 64-lowercase-hex shape")
        }
        return value
    }
}

/// Identifies one schemata run's attempt to activate and hit a specific
/// mutation — fresh per attempt, including per confirmation retest (ADR-0006
/// Finding 3's proposed fix requires this: a confirmation reusing the
/// original run's ID would let a stale transcript pass as new evidence).
/// Not a `HexIdentity`: a `RunID` is generated, never parsed from untrusted
/// hex input, so it carries a `UUID` directly rather than a validated hex
/// string.
public struct RunID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
