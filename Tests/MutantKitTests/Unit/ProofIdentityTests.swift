import Foundation
import MutationModel
import Testing

/// `SHA256Digest`/`ImageUUID`/`CompilationUnitID` are the strong types every
/// later stage-2 layer (Mach-O receipts, the v3 binary protocol, the
/// verifier's unique-chain check) compares for equality. If a malformed
/// string could construct one of these, every later "identity fields all
/// agree" check would be comparing values that were never actually proven
/// to be the right shape.
@Suite("Proof identity: hex-validated strong types")
struct ProofIdentityTests {
    // MARK: - SHA256Digest

    @Test("a real SHA-256 digest round-trips through rawValue")
    func sha256DigestRoundTrips() throws {
        let digest = SHA256Digest.of("hello")
        #expect(digest.rawValue.count == 64)
        let reparsed = try #require(SHA256Digest(rawValue: digest.rawValue))
        #expect(reparsed == digest)
    }

    @Test("SHA256Digest rejects the wrong length")
    func sha256DigestRejectsWrongLength() {
        #expect(SHA256Digest(rawValue: String(repeating: "a", count: 63)) == nil)
        #expect(SHA256Digest(rawValue: String(repeating: "a", count: 65)) == nil)
        #expect(SHA256Digest(rawValue: "") == nil)
    }

    @Test("SHA256Digest rejects uppercase hex")
    func sha256DigestRejectsUppercase() {
        let upper = SHA256Digest.of("hello").rawValue.uppercased()
        #expect(SHA256Digest(rawValue: upper) == nil)
    }

    @Test("SHA256Digest rejects non-hex characters")
    func sha256DigestRejectsNonHex() {
        var value = String(repeating: "a", count: 63)
        value.append("g")
        #expect(SHA256Digest(rawValue: value) == nil)
    }

    @Test("of(_:) is deterministic")
    func sha256DigestIsDeterministic() {
        #expect(SHA256Digest.of("same input") == SHA256Digest.of("same input"))
        #expect(SHA256Digest.of("input A") != SHA256Digest.of("input B"))
    }

    // MARK: - ImageUUID

    @Test("a real UUID converts to a valid 32-hex ImageUUID")
    func imageUUIDFromUUID() throws {
        let uuid = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let image = ImageUUID(uuid: uuid)
        #expect(image.rawValue == "123456781234123412341234567890ab")
        let reparsed = try #require(ImageUUID(rawValue: image.rawValue))
        #expect(reparsed == image)
    }

    @Test("ImageUUID rejects the wrong length")
    func imageUUIDRejectsWrongLength() {
        #expect(ImageUUID(rawValue: String(repeating: "a", count: 31)) == nil)
        #expect(ImageUUID(rawValue: String(repeating: "a", count: 33)) == nil)
        // A SHA256Digest-shaped 64-hex string must not be accepted as an
        // ImageUUID -- the two types must never be interchangeable by
        // accident just because both are hex.
        #expect(ImageUUID(rawValue: SHA256Digest.of("x").rawValue) == nil)
    }

    @Test("ImageUUID rejects a hyphenated UUID string")
    func imageUUIDRejectsHyphenatedForm() {
        #expect(ImageUUID(rawValue: "12345678-1234-1234-1234-1234567890ab") == nil)
    }

    // MARK: - CompilationUnitID

    @Test("derive(...) is deterministic for identical inputs")
    func compilationUnitIDIsDeterministic() {
        let a = CompilationUnitID.derive(
            projectIdentity: "proj", target: "App", module: "App",
            sourcePath: "Sources/App/A.swift", lowererID: "bool-literal", lowererVersion: 1
        )
        let b = CompilationUnitID.derive(
            projectIdentity: "proj", target: "App", module: "App",
            sourcePath: "Sources/App/A.swift", lowererID: "bool-literal", lowererVersion: 1
        )
        #expect(a == b)
    }

    @Test("derive(...) changes when any single input changes")
    func compilationUnitIDVariesWithEachInput() {
        let base = CompilationUnitID.derive(
            projectIdentity: "proj", target: "App", module: "App",
            sourcePath: "Sources/App/A.swift", lowererID: "bool-literal", lowererVersion: 1
        )
        let differentPath = CompilationUnitID.derive(
            projectIdentity: "proj", target: "App", module: "App",
            sourcePath: "Sources/App/B.swift", lowererID: "bool-literal", lowererVersion: 1
        )
        let differentVersion = CompilationUnitID.derive(
            projectIdentity: "proj", target: "App", module: "App",
            sourcePath: "Sources/App/A.swift", lowererID: "bool-literal", lowererVersion: 2
        )
        #expect(base != differentPath)
        #expect(base != differentVersion)
    }

    // MARK: - Codable round trip

    @Test("SHA256Digest/ImageUUID/CompilationUnitID/RunID all encode as their raw hex, not a nested object")
    func hexIdentitiesEncodeAsPlainStrings() throws {
        let digest = SHA256Digest.of("x")
        let data = try JSONEncoder().encode(digest)
        let decodedString = try JSONDecoder().decode(String.self, from: data)
        #expect(decodedString == digest.rawValue)

        let decodedBack = try JSONDecoder().decode(SHA256Digest.self, from: data)
        #expect(decodedBack == digest)
    }

    @Test("decoding a malformed hex string for SHA256Digest throws, not nil-coalesces")
    func decodingMalformedHexThrows() throws {
        let data = try JSONEncoder().encode("not-hex-at-all")
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(SHA256Digest.self, from: data)
        }
    }

    @Test("RunID is unique per construction")
    func runIDIsUniquePerConstruction() {
        #expect(RunID() != RunID())
    }
}
