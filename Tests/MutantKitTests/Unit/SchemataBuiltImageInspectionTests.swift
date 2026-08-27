import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// `SchemataBuiltImageInspection` is the build-time half of ADR-0006's
/// proof chain, wired into `SwiftPackageMacOSAdapter`: it discovers the
/// real built bundle(s) under a chunk's `productsDirectory` and extracts
/// each one's real `LC_UUID`-backed identity. `SchemataMutationRunnerAcceptanceTests`
/// proves this against a genuine `swift build` end to end; this pins the
/// discovery/refusal behavior directly against a fabricated products
/// directory containing a real compiled binary (built with the `swiftc` on
/// this machine, the same technique `MachOReceiptExtractorTests` uses).
@Suite("Schemata built image inspection", .subprocessExclusive)
struct SchemataBuiltImageInspectionTests {
    /// Compiles a trivial real binary once and reuses it across tests —
    /// building it is a real `swiftc` invocation, not free.
    private enum CompileError: Error, CustomStringConvertible {
        case failed(String)
        var description: String {
            switch self {
            case let .failed(output): "failed to compile the fixture binary: \(output)"
            }
        }
    }

    private static func compileFixtureBinary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schemata-image-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("main.swift")
        try Data("print(\"hi\")\n".utf8).write(to: sourceURL)
        let binaryURL = root.appendingPathComponent("fixture")

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        compile.arguments = ["swiftc", sourceURL.path, "-o", binaryURL.path]
        let pipe = Pipe()
        compile.standardError = pipe
        compile.standardOutput = pipe
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CompileError.failed(output)
        }
        return binaryURL
    }

    private static let compiledBinaryResult = Swift.Result { try compileFixtureBinary() }

    private static func compiledBinary() throws -> URL {
        try compiledBinaryResult.get()
    }

    /// Stages `<productsDirectory>/Fixture.xctest/Contents/MacOS/Fixture`,
    /// the on-disk shape `SchemataBuiltImageInspection` looks for — a copy
    /// of the real compiled fixture binary, not a stub, so extraction
    /// exercises the real `MachOReceiptExtractor` path.
    private func stageBundle(named name: String = "Fixture", extension bundleExtension: String = "xctest") throws -> URL {
        let productsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schemata-image-products-\(UUID().uuidString)")
        let bundle = productsDirectory.appendingPathComponent("\(name).\(bundleExtension)")
        let macOSDirectory = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOSDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try Self.compiledBinary(), to: macOSDirectory.appendingPathComponent(name))
        return productsDirectory
    }

    @Test("A products directory with one real xctest bundle produces one receipt with a real UUID")
    func oneRealBundleProducesOneReceipt() throws {
        let productsDirectory = try stageBundle()
        defer { try? FileManager.default.removeItem(at: productsDirectory) }

        let receipts = try SchemataBuiltImageInspection.inspect(productsDirectory: productsDirectory)

        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        #expect(receipt.bundleName == "Fixture")
        #expect(!receipt.slices.isEmpty)
        for slice in receipt.slices {
            #expect(slice.imageUUID.rawValue.count == 32)
        }
    }

    @Test("Two bundles produce two receipts, sorted deterministically")
    func twoBundlesProduceTwoReceipts() throws {
        let productsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schemata-image-products-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: productsDirectory) }
        for name in ["Alpha", "Beta"] {
            let macOSDirectory = productsDirectory.appendingPathComponent("\(name).xctest/Contents/MacOS")
            try FileManager.default.createDirectory(at: macOSDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: try Self.compiledBinary(), to: macOSDirectory.appendingPathComponent(name))
        }

        let receipts = try SchemataBuiltImageInspection.inspect(productsDirectory: productsDirectory)

        #expect(receipts.map(\.bundleName) == ["Alpha", "Beta"])
    }

    @Test("inspectSingle inspects one already-known binary path directly, with no discovery")
    func inspectSingleInspectsOneKnownPath() throws {
        let productsDirectory = try stageBundle()
        defer { try? FileManager.default.removeItem(at: productsDirectory) }
        let binaryPath = productsDirectory.appendingPathComponent("Fixture.xctest/Contents/MacOS/Fixture")

        let discovered = try SchemataBuiltImageInspection.inspectSingle(at: binaryPath, bundleName: "Fixture")

        #expect(discovered.bundleName == "Fixture")
        #expect(!discovered.slices.isEmpty)
    }

    @Test("An empty products directory is refused, not silently reported as zero images")
    func emptyProductsDirectoryIsRefused() throws {
        let productsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schemata-image-products-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: productsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: productsDirectory) }

        #expect(throws: SchemataBuiltImageInspectionError.self) {
            _ = try SchemataBuiltImageInspection.inspect(productsDirectory: productsDirectory)
        }
    }

    @Test("A bundle whose expected binary path does not exist is skipped, not fabricated")
    func bundleWithNoBinaryIsSkipped() throws {
        let productsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("schemata-image-products-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: productsDirectory.appendingPathComponent("Empty.xctest/Contents/MacOS"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: productsDirectory) }

        #expect(throws: SchemataBuiltImageInspectionError.self) {
            _ = try SchemataBuiltImageInspection.inspect(productsDirectory: productsDirectory)
        }
    }

    @Test("Two invocations against the same real binary report the same UUID")
    func repeatedInspectionIsDeterministic() throws {
        let productsDirectory = try stageBundle()
        defer { try? FileManager.default.removeItem(at: productsDirectory) }

        let first = try SchemataBuiltImageInspection.inspect(productsDirectory: productsDirectory)
        let second = try SchemataBuiltImageInspection.inspect(productsDirectory: productsDirectory)

        #expect(first == second)
    }
}
