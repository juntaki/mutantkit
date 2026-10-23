@testable import AppleBuildAdapters
import Foundation
import Testing

@Suite("SwiftPM test bundle coverage export")
struct SwiftPMTestBundleCoverageExportTests {
    private func makeProducts(bundles: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-bundles-\(UUID().uuidString)")
        for bundle in bundles {
            let macOS = root.appendingPathComponent("\(bundle).xctest/Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try Data().write(to: macOS.appendingPathComponent(bundle))
        }
        // Things that are not test bundles must be ignored.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Other.framework/Contents/MacOS", isDirectory: true), withIntermediateDirectories: true
        )
        try Data().write(to: root.appendingPathComponent("loose-file"))
        return root
    }

    @Test("Every test bundle's executable is found, in path order, and nothing else")
    func findsEveryBundle() throws {
        let root = try makeProducts(bundles: ["ZetaTests", "AlphaTests"])
        defer { try? FileManager.default.removeItem(at: root) }

        let found = SwiftPMTestBundleCoverageExport.testBundleExecutables(in: root)
        #expect(found.map { $0.lastPathComponent } == ["AlphaTests", "ZetaTests"])
        #expect(found.allSatisfy { $0.path.contains(".xctest/Contents/MacOS/") })
    }

    @Test("The first bundle is the positional binary and each other bundle is an -object")
    func exportArgumentsListEveryBundle() {
        let profile = URL(fileURLWithPath: "/p/default.profdata")
        let bundles = ["/b/A", "/b/B", "/b/C"].map { URL(fileURLWithPath: $0) }

        #expect(SwiftPMTestBundleCoverageExport.exportArguments(profileData: profile, executables: bundles) == [
            "llvm-cov", "export", "-format=text", "-instr-profile=/p/default.profdata", "/b/A",
            "-object", "/b/B", "-object", "/b/C"
        ])
        #expect(SwiftPMTestBundleCoverageExport.exportArguments(profileData: profile, executables: []).isEmpty)
    }

    @Test("With fewer than two bundles an earlier export is removed and none is written")
    func staleExportIsRemovedWhenNotNeeded() async throws {
        let root = try makeProducts(bundles: ["OnlyTests"])
        defer { try? FileManager.default.removeItem(at: root) }
        let codecov = root.appendingPathComponent("codecov", isDirectory: true)
        try FileManager.default.createDirectory(at: codecov, withIntermediateDirectories: true)
        let stale = codecov.appendingPathComponent(SwiftPMTestBundleCoverageExport.outputFileName)
        try Data("stale".utf8).write(to: stale)

        await SwiftPMTestBundleCoverageExport.refresh(productsDirectory: root, codecovDirectory: codecov)

        #expect(!FileManager.default.fileExists(atPath: stale.path), "a stale export would be merged into this run's coverage")
    }
}
