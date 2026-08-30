@testable import AppleBuildAdapters
import Foundation
import Testing

@Suite("SwiftPM test product resolver")
struct SwiftPMTestProductResolverTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-product-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBundle(named name: String, in directory: URL, withBinary: Bool = true) throws {
        let bundle = directory.appendingPathComponent("\(name).xctest", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        if withBinary {
            try Data("fake binary".utf8).write(to: macOS.appendingPathComponent(name))
        }
    }

    @Test("Resolves the one unambiguous .xctest bundle's binary")
    func resolvesTheOneBundle() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeBundle(named: "PricingPackageTests", in: directory)

        let resolved = try #require(SwiftPMTestProductResolver.resolve(productsDirectory: directory))
        // Suffix, not full-path equality: `FileManager.contentsOfDirectory`
        // returns paths with macOS's /var -> /private/var temp-dir symlink
        // already resolved, which a plain, unresolved `directory` URL is
        // not -- comparing the structurally-meaningful tail avoids a false
        // mismatch from that unrelated normalization difference.
        #expect(resolved.path.hasSuffix("PricingPackageTests.xctest/Contents/MacOS/PricingPackageTests"))
    }

    @Test("Two .xctest bundles is ambiguous, not a first-one-wins guess")
    func twoBundlesIsAmbiguous() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeBundle(named: "FirstPackageTests", in: directory)
        try makeBundle(named: "SecondPackageTests", in: directory)

        #expect(SwiftPMTestProductResolver.resolve(productsDirectory: directory) == nil)
    }

    @Test("No .xctest bundle at all is unsupported")
    func noBundleIsUnsupported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(SwiftPMTestProductResolver.resolve(productsDirectory: directory) == nil)
    }

    @Test("A bundle whose own binary is missing is unsupported")
    func bundleMissingBinaryIsUnsupported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeBundle(named: "PricingPackageTests", in: directory, withBinary: false)

        #expect(SwiftPMTestProductResolver.resolve(productsDirectory: directory) == nil)
    }

    @Test("A nonexistent products directory is unsupported")
    func nonexistentDirectoryIsUnsupported() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-does-not-exist-\(UUID().uuidString)")
        #expect(SwiftPMTestProductResolver.resolve(productsDirectory: directory) == nil)
    }
}
