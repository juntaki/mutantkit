import AppleBuildAdapters
import Foundation
import SwiftCoreOperators
import Testing

/// The highest value-per-second test in this whole feature: it reproduces the
/// *exact* originally-reported failure and proves the *exact* fix, using the real
/// production preamble a mutated compilation unit actually gets
/// (`BoolLiteralSchemataLowerer.sharedDeclarationPreamble`), not a hand-written
/// stand-in that could quietly drift from what production emits.
///
/// No simulator boot, no `xcodebuild`, no `.xctestrun` — just `swiftc -target
/// arm64-apple-ios17.0-simulator` compiling and linking a tiny probe against each
/// archive directly, the same two commands the original investigation ran by hand
/// to diagnose and then fix the reported
/// `ld: building for 'iOS-simulator', but linking in object file ... built for
/// 'macOS'` failure.
///
/// The negative control is not decoration: it pins the *exact* error text so a
/// regression (e.g. someone reintroducing a fallback from `.iOSSimulator` to the
/// flat macOS layout in `SchemataRuntimeLibraryLocator`) cannot silently reappear
/// without this suite catching it — the whole reason `SchemataRuntimePlatform`
/// exists in the first place.
///
/// Gated on `Acceptance.simulatorEnabled`: needs the iPhoneSimulator SDK for both
/// archives and for `swiftc -target ...-simulator` itself, never boots a device.
@Suite("Acceptance: iOS-Simulator schemata runtime link viability", .enabled(if: Acceptance.simulatorEnabled))
struct SchemataIOSSimulatorRuntimeLinkAcceptanceTests {
    /// The real declarations a mutated compilation unit gets prepended, plus a
    /// trivial `main` exercising both — proof this specific source, not a
    /// hand-maintained approximation of it, links cleanly.
    private static var probeSource: String {
        BoolLiteralSchemataLowerer.sharedDeclarationPreamble + """
        let hex = String(repeating: "0", count: 64)
        let descriptor = hex.withCString { a in hex.withCString { b in __mutantkitRegisterUnitV3(a, b) } }
        _ = __mutantkitIsActiveV3(descriptor, 0, 0)
        """
    }

    private struct LinkResult {
        let exitCode: Int32
        let output: String
        let binary: URL
    }

    private func link(against libraryDirectory: URL, in directory: URL) throws -> LinkResult {
        let probe = directory.appendingPathComponent("probe-\(UUID().uuidString).swift")
        try Data(Self.probeSource.utf8).write(to: probe)
        let binary = directory.appendingPathComponent("probe-\(UUID().uuidString)")
        let sdkPath = try sdkPath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "--sdk", "iphonesimulator", "swiftc",
            "-target", "arm64-apple-ios17.0-simulator",
            "-sdk", sdkPath,
            probe.path,
            "-L", libraryDirectory.path, "-lMutantKitSchemataRuntime",
            "-o", binary.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return LinkResult(exitCode: process.terminationStatus, output: output, binary: binary)
    }

    private func sdkPath() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "iphonesimulator", "--show-sdk-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("The iOS-Simulator archive links cleanly against a real arm64-apple-ios17.0-simulator target")
    func linksAgainstIOSSimulatorArchive() throws {
        let located = try SchemataRuntimeLibraryLocator.locate(for: .iOSSimulator)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("schemata-ios-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try link(against: located.libraryDirectory, in: directory)
        #expect(result.exitCode == 0, "expected a clean link against the iOS-Simulator archive:\n\(result.output)")

        let otool = Process()
        otool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        otool.arguments = ["otool", "-l", result.binary.path]
        let pipe = Pipe()
        otool.standardOutput = pipe
        try otool.run()
        let otoolOutput = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        otool.waitUntilExit()
        #expect(otoolOutput.contains("platform 7"), "expected the linked probe binary itself to report platform 7 (iOS Simulator)")
    }

    /// Pins the exact originally-reported failure. If this ever starts passing
    /// (i.e. the macOS archive links cleanly into an iOS-Simulator target), either
    /// the toolchain's behavior changed underneath this suite, or — far more
    /// likely and far more concerning — `SchemataRuntimeLibraryLocator` regressed
    /// into handing an iOS-Simulator build the macOS archive again.
    @Test("Negative control: the macOS archive fails the identical link with the originally-reported error")
    func macOSArchiveFailsIdenticalLink() throws {
        let located = try SchemataRuntimeLibraryLocator.locate(for: .macOS)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("schemata-ios-link-negative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try link(against: located.libraryDirectory, in: directory)
        #expect(result.exitCode != 0, "expected the macOS archive to fail an iOS-Simulator-targeted link")
        #expect(
            result.output.contains("building for 'iOS-simulator'") && result.output.contains("built for 'macOS'"),
            "expected the originally-reported linker error, got:\n\(result.output)"
        )
    }
}
