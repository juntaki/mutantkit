@testable import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// `TestProductHasher` decides *which files* activation evidence gets computed
/// from — a decision `MachOCodeHashTests` never touches, since it only hashes
/// bytes it's handed directly.
///
/// Found missing by running MutantKit against an actual Xcode-project iOS
/// app: Xcode's "Debug Dylib" build acceleration — on by
/// default for Debug/simulator builds on recent toolchains — moves an app or
/// framework target's own compiled code out of its host executable and into a
/// loose `<Target>.debug.dylib` sitting directly inside the `.app`, leaving a
/// near-empty stub behind that loads it at runtime. `bundleExtensions` had no
/// entry for a loose file, so every one of six mutants — across four files in
/// two different targets — hashed only the unchanging stub and reported
/// `mutationNotActivated`, and the run produced no score at all.
@Suite("Test product hasher")
struct TestProductHasherTests {
    @Test("A loose debug dylib inside a .app changes the product hash")
    func looseDylibChangesProductHash() throws {
        let stub = try fixtureBinaryData()
        var mutatedDylib = stub
        // Offset 808 is inside this fixture's `__TEXT,__text` (offset 808,
        // size 0x14), which is allow-listed — a flip outside any allow-listed
        // section would leave the code hash, and this test, unchanged.
        mutatedDylib[810] ^= 0xFF

        let baselineRoot = try makeProductsDirectory(appExecutable: stub, debugDylib: stub)
        let mutantRoot = try makeProductsDirectory(appExecutable: stub, debugDylib: mutatedDylib)

        let baselineHash = try #require(TestProductHasher.hash(productsDirectory: baselineRoot))
        let mutantHash = try #require(TestProductHasher.hash(productsDirectory: mutantRoot))

        #expect(baselineHash != mutantHash)
    }

    @Test("Two products with an identical debug dylib hash the same")
    func identicalLooseDylibsHashTheSame() throws {
        let stub = try fixtureBinaryData()

        let first = try makeProductsDirectory(appExecutable: stub, debugDylib: stub)
        let second = try makeProductsDirectory(appExecutable: stub, debugDylib: stub)

        let firstHash = try #require(TestProductHasher.hash(productsDirectory: first))
        let secondHash = try #require(TestProductHasher.hash(productsDirectory: second))

        #expect(firstHash == secondHash)
    }

    @Test("A .app with no debug dylib still hashes its own executable")
    func appWithoutDylibStillHashes() throws {
        let stub = try fixtureBinaryData()
        let root = try makeProductsDirectory(appExecutable: stub, debugDylib: nil)

        #expect(TestProductHasher.hash(productsDirectory: root) != nil)
    }

    @Test("No test bundle anywhere yields nil, not a crash")
    func emptyDirectoryYieldsNil() throws {
        let root = try makeTempDirectory()
        #expect(TestProductHasher.hash(productsDirectory: root) == nil)
    }

    // MARK: - Helpers

    private func fixtureBinaryData() throws -> Data {
        let resourceURL = try #require(Bundle.module.resourceURL)
        let url = resourceURL.appendingPathComponent("Fixtures/macho-test-binary")
        return try Data(contentsOf: url)
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-test-product-hasher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A products directory with one `.app` bundle — `App.app/App` as the
    /// host executable and, when supplied, a loose `App.app/App.debug.dylib`
    /// beside it. Exactly the shape Xcode's Debug Dylib build produces.
    private func makeProductsDirectory(appExecutable: Data, debugDylib: Data?) throws -> URL {
        let root = try makeTempDirectory()
        let app = root.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try appExecutable.write(to: app.appendingPathComponent("App"))
        if let debugDylib {
            try debugDylib.write(to: app.appendingPathComponent("App.debug.dylib"))
        }
        return root
    }
}
