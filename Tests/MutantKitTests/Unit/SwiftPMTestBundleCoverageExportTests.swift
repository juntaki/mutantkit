@testable import AppleBuildAdapters
import Foundation
import MutationExecution
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

        let found = SwiftPMTestBundleCoverageExport.testBundleInventory(in: root)?.executables ?? []
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

        let outcome = await SwiftPMTestBundleCoverageExport.refresh(productsDirectory: root, codecovDirectory: codecov)

        #expect(outcome == .notNeeded)
        #expect(!FileManager.default.fileExists(atPath: stale.path), "a stale export would be merged into this run's coverage")
    }

    private func codecovDirectory(in root: URL, withProfile: Bool = true) throws -> URL {
        let codecov = root.appendingPathComponent("codecov", isDirectory: true)
        try FileManager.default.createDirectory(at: codecov, withIntermediateDirectories: true)
        if withProfile { try Data().write(to: codecov.appendingPathComponent("default.profdata")) }
        return codecov
    }

    @Test("A complete export of every bundle is written and reported as exported")
    func completeExportIsWritten() async throws {
        let root = try makeProducts(bundles: ["ATests", "BTests"])
        defer { try? FileManager.default.removeItem(at: root) }
        let codecov = try codecovDirectory(in: root)

        let outcome = await SwiftPMTestBundleCoverageExport.refresh(
            productsDirectory: root, codecovDirectory: codecov, run: { _, _ in result(output: "{\"ok\":1}") }
        )

        #expect(outcome == .exported)
        let written = try Data(contentsOf: codecov.appendingPathComponent(SwiftPMTestBundleCoverageExport.outputFileName))
        #expect(String(decoding: written, as: UTF8.self) == "{\"ok\":1}")
    }

    @Test("A bundle whose executable is missing makes the export incomplete, not smaller")
    func unreadableBundleIsIncomplete() async throws {
        let root = try makeProducts(bundles: ["ATests", "BTests"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("GhostTests.xctest/Contents/MacOS", isDirectory: true), withIntermediateDirectories: true
        )
        let codecov = try codecovDirectory(in: root)
        let ran = RanFlag()

        let outcome = await SwiftPMTestBundleCoverageExport.refresh(
            productsDirectory: root, codecovDirectory: codecov, run: { _, _ in await ran.set(); return result() }
        )

        guard case let .incomplete(reason) = outcome else { Issue.record("expected incomplete, got \(outcome)"); return }
        #expect(reason.contains("GhostTests.xctest"))
        #expect(await !ran.value, "no partial export may be attempted over an incomplete bundle inventory")
    }

    @Test("A failed, truncated or unrunnable export is incomplete and leaves no output file")
    func failedExportIsIncomplete() async throws {
        let root = try makeProducts(bundles: ["ATests", "BTests"])
        defer { try? FileManager.default.removeItem(at: root) }
        let codecov = try codecovDirectory(in: root)
        let output = codecov.appendingPathComponent(SwiftPMTestBundleCoverageExport.outputFileName)
        try Data("stale".utf8).write(to: output)

        let runners: [SwiftPMTestBundleCoverageExport.ExportRunner] = [
            { _, _ in result(exit: 1) },
            { _, _ in result(complete: false) },
            { _, _ in result(output: "") },
            { _, _ in nil }
        ]
        for runner in runners {
            let outcome = await SwiftPMTestBundleCoverageExport.refresh(
                productsDirectory: root, codecovDirectory: codecov, run: runner
            )
            guard case .incomplete = outcome else { Issue.record("expected incomplete, got \(outcome)"); continue }
            #expect(!FileManager.default.fileExists(atPath: output.path), "a stale or partial export must not survive")
        }
    }

    @Test("Several bundles with no merged profile are incomplete")
    func missingProfileIsIncomplete() async throws {
        let root = try makeProducts(bundles: ["ATests", "BTests"])
        defer { try? FileManager.default.removeItem(at: root) }
        let codecov = try codecovDirectory(in: root, withProfile: false)

        let outcome = await SwiftPMTestBundleCoverageExport.refresh(
            productsDirectory: root, codecovDirectory: codecov, run: { _, _ in result() }
        )

        guard case .incomplete = outcome else { Issue.record("expected incomplete, got \(outcome)"); return }
    }

    @Test("A previous export that cannot be removed is incomplete")
    func failedRemovalIsIncomplete() async throws {
        let root = try makeProducts(bundles: ["ATests", "BTests"])
        let codecov = try codecovDirectory(in: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codecov.path)
            try? FileManager.default.removeItem(at: root)
        }
        try Data("stale".utf8).write(to: codecov.appendingPathComponent(SwiftPMTestBundleCoverageExport.outputFileName))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: codecov.path)

        let outcome = await SwiftPMTestBundleCoverageExport.refresh(
            productsDirectory: root, codecovDirectory: codecov, run: { _, _ in result() }
        )

        guard case .incomplete = outcome else { Issue.record("expected incomplete, got \(outcome)"); return }
    }

    @Test("A products directory that cannot be listed is incomplete, not zero bundles")
    func unlistableProductsDirectoryIsIncomplete() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("mutantkit-none-\(UUID().uuidString)")

        let outcome = await SwiftPMTestBundleCoverageExport.refresh(
            productsDirectory: missing, codecovDirectory: missing.appendingPathComponent("codecov"), run: { _, _ in result() }
        )

        guard case .incomplete = outcome else { Issue.record("expected incomplete, got \(outcome)"); return }
    }
}

private actor RanFlag {
    private(set) var value = false
    func set() { value = true }
}

private func result(exit: Int32 = 0, output: String = "{}", complete: Bool = true) -> ProcessResult {
    ProcessResult(
        exitCode: exit, standardOutput: Data(output.utf8), standardError: Data(), durationSeconds: 0.1,
        timedOut: false, terminatingSignal: nil, outputComplete: complete
    )
}
