import Foundation
import MutationModel
import Testing

/// `SchemataBuildReceipt`/`BuiltImageReceipt` are the build-time half of
/// ADR-0006 Stage 2's proof chain -- what a runtime STARTUP/HIT event's
/// `compilationUnitID`/`imageUUID` gets checked against. If construction
/// itself accepted a receipt with two slices claiming the same image UUID,
/// or two compilation units under the same ID, the verifier's later
/// "unique chain" lookup would be ambiguous before it ever ran.
@Suite("Schemata build receipt: construction-time invariants")
struct SchemataBuildReceiptTests {
    private func uuid(_ byte: UInt8) -> ImageUUID {
        ImageUUID(rawValue: String(repeating: String(format: "%02x", byte), count: 16))!
    }

    private func compilationUnitID(_ seed: String) -> CompilationUnitID {
        CompilationUnitID.derive(
            projectIdentity: "proj", target: "App", module: "App", sourcePath: seed, lowererID: "bool-literal", lowererVersion: 1
        )
    }

    private func target(_ name: String = "App") -> BuildTargetIdentity {
        BuildTargetIdentity(projectIdentity: "proj", targetName: name, moduleName: name)
    }

    private func slice(architecture cpuType: Int32, uuid: ImageUUID) -> BuiltImageSlice {
        BuiltImageSlice(architecture: BuiltArchitectureIdentity(cpuType: cpuType, cpuSubtype: 0), imageUUID: uuid)
    }

    // MARK: - BuiltImageReceipt

    @Test("a receipt with two distinct architecture slices constructs successfully")
    func distinctSlicesConstructSuccessfully() throws {
        let receipt = try BuiltImageReceipt(
            buildTarget: target(), binaryPath: "/build/App",
            contentHash: SHA256Digest.of("bytes"),
            slices: [slice(architecture: 0x0100_000C, uuid: uuid(0xAA)), slice(architecture: 0x0100_0007, uuid: uuid(0xBB))]
        )
        #expect(receipt.slices.count == 2)
    }

    @Test("two slices of the same image sharing an ImageUUID is refused")
    func duplicateImageUUIDWithinImageIsRefused() {
        let shared = uuid(0xCC)
        #expect(throws: SchemataBuildReceiptError.duplicateImageUUIDWithinImage(shared)) {
            _ = try BuiltImageReceipt(
                buildTarget: target(), binaryPath: "/build/App",
                contentHash: SHA256Digest.of("bytes"),
                slices: [slice(architecture: 0x0100_000C, uuid: shared), slice(architecture: 0x0100_0007, uuid: shared)]
            )
        }
    }

    @Test("slices are stored sorted by cpuType regardless of construction order")
    func slicesAreSortedRegardlessOfInputOrder() throws {
        let a = try BuiltImageReceipt(
            buildTarget: target(), binaryPath: "/build/App", contentHash: SHA256Digest.of("x"),
            slices: [slice(architecture: 0x0100_0007, uuid: uuid(0x01)), slice(architecture: 0x0100_000C, uuid: uuid(0x02))]
        )
        let b = try BuiltImageReceipt(
            buildTarget: target(), binaryPath: "/build/App", contentHash: SHA256Digest.of("x"),
            slices: [slice(architecture: 0x0100_000C, uuid: uuid(0x02)), slice(architecture: 0x0100_0007, uuid: uuid(0x01))]
        )
        #expect(a.slices == b.slices)
        // 0x0100_0007 (x86_64) < 0x0100_000C (arm64) numerically.
        #expect(a.slices.first?.architecture.cpuType == 0x0100_0007)
    }

    // MARK: - SchemataBuildReceipt

    private func makeReceipt(images: [BuiltImageReceipt] = [], compilationUnits: [CompilationUnitReceipt]) throws -> SchemataBuildReceipt {
        try SchemataBuildReceipt(
            planID: "plan-1", workUnitID: "wu-1", chunkID: "chunk-1",
            toolchainHash: SHA256Digest.of("toolchain"), buildArgumentsHash: SHA256Digest.of("args"),
            runtimeABIVersion: 3, images: images, compilationUnits: compilationUnits
        )
    }

    @Test("distinct compilation unit IDs construct successfully")
    func distinctCompilationUnitsConstructSuccessfully() throws {
        let a = CompilationUnitReceipt(
            compilationUnitID: compilationUnitID("A.swift"), sourceEmbeddingID: SHA256Digest.of("A"), buildTarget: target()
        )
        let b = CompilationUnitReceipt(
            compilationUnitID: compilationUnitID("B.swift"), sourceEmbeddingID: SHA256Digest.of("B"), buildTarget: target()
        )
        let receipt = try makeReceipt(compilationUnits: [a, b])
        #expect(receipt.compilationUnits.count == 2)
    }

    @Test("the same compilation unit ID reported twice is refused")
    func duplicateCompilationUnitIDIsRefused() {
        let id = compilationUnitID("A.swift")
        let first = CompilationUnitReceipt(compilationUnitID: id, sourceEmbeddingID: SHA256Digest.of("A"), buildTarget: target())
        let second = CompilationUnitReceipt(compilationUnitID: id, sourceEmbeddingID: SHA256Digest.of("A-changed"), buildTarget: target())
        #expect(throws: SchemataBuildReceiptError.duplicateCompilationUnitID(id)) {
            _ = try makeReceipt(compilationUnits: [first, second])
        }
    }

    @Test("two images reporting the same build target is refused")
    func duplicateBuildTargetIsRefused() {
        let image1 = try? BuiltImageReceipt(buildTarget: target(), binaryPath: "/a", contentHash: SHA256Digest.of("a"), slices: [])
        let image2 = try? BuiltImageReceipt(buildTarget: target(), binaryPath: "/b", contentHash: SHA256Digest.of("b"), slices: [])
        #expect(throws: SchemataBuildReceiptError.duplicateBuildTarget(target())) {
            _ = try makeReceipt(images: [image1!, image2!], compilationUnits: [])
        }
    }

    @Test("compilation units are stored sorted regardless of construction order")
    func compilationUnitsAreSortedRegardlessOfInputOrder() throws {
        let a = CompilationUnitReceipt(
            compilationUnitID: compilationUnitID("A.swift"), sourceEmbeddingID: SHA256Digest.of("A"), buildTarget: target()
        )
        let b = CompilationUnitReceipt(
            compilationUnitID: compilationUnitID("B.swift"), sourceEmbeddingID: SHA256Digest.of("B"), buildTarget: target()
        )
        let forward = try makeReceipt(compilationUnits: [a, b])
        let reversed = try makeReceipt(compilationUnits: [b, a])
        #expect(forward.compilationUnits == reversed.compilationUnits)
    }

    @Test("version is stamped to currentVersion regardless of what a caller might try to pass")
    func versionIsAlwaysCurrentVersion() throws {
        let receipt = try makeReceipt(compilationUnits: [])
        #expect(receipt.version == SchemataBuildReceipt.currentVersion)
    }

    @Test("SchemataBuildReceipt round-trips through JSON")
    func schemataBuildReceiptRoundTripsThroughJSON() throws {
        let unit = CompilationUnitReceipt(
            compilationUnitID: compilationUnitID("A.swift"), sourceEmbeddingID: SHA256Digest.of("A"), buildTarget: target()
        )
        let image = try BuiltImageReceipt(
            buildTarget: target(), binaryPath: "/build/App", contentHash: SHA256Digest.of("bytes"),
            slices: [slice(architecture: 0x0100_000C, uuid: uuid(0x01))]
        )
        let receipt = try makeReceipt(compilationUnits: [unit])
        let withImage = try SchemataBuildReceipt(
            planID: receipt.planID, workUnitID: receipt.workUnitID, chunkID: receipt.chunkID,
            toolchainHash: receipt.toolchainHash, buildArgumentsHash: receipt.buildArgumentsHash,
            runtimeABIVersion: receipt.runtimeABIVersion, images: [image], compilationUnits: receipt.compilationUnits
        )

        let data = try JSONEncoder().encode(withImage)
        let decoded = try JSONDecoder().decode(SchemataBuildReceipt.self, from: data)
        #expect(decoded == withImage)
    }

    @Test("SchemataBuildReceipt.image(for:) and .compilationUnit(for:) resolve by exact identity")
    func lookupsResolveByExactIdentity() throws {
        let unit = CompilationUnitReceipt(
            compilationUnitID: compilationUnitID("A.swift"), sourceEmbeddingID: SHA256Digest.of("A"), buildTarget: target()
        )
        let image = try BuiltImageReceipt(
            buildTarget: target(), binaryPath: "/build/App", contentHash: SHA256Digest.of("bytes"),
            slices: [slice(architecture: 0x0100_000C, uuid: uuid(0x01))]
        )
        let receipt = try makeReceipt(images: [image], compilationUnits: [unit])
        #expect(receipt.image(for: target()) == image)
        #expect(receipt.image(for: target("Other")) == nil)
        #expect(receipt.compilationUnit(for: unit.compilationUnitID) == unit)
        #expect(receipt.compilationUnit(for: compilationUnitID("Missing.swift")) == nil)
    }

    @Test("BuiltArchitectureIdentity.displayName matches the known arm64/x86_64 names")
    func displayNameMatchesKnownArchitectures() {
        #expect(BuiltArchitectureIdentity(cpuType: 0x0100_000C, cpuSubtype: 0).displayName == "arm64")
        #expect(BuiltArchitectureIdentity(cpuType: 0x0100_0007, cpuSubtype: 0).displayName == "x86_64")
        #expect(BuiltArchitectureIdentity(cpuType: 0, cpuSubtype: 0).displayName.hasPrefix("cpu_"))
    }
}
