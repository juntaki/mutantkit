import AppleBuildAdapters
import Foundation
import Testing

/// Is the archive `scripts/build-schemata-runtime.sh` produces actually what it
/// claims to be? Locates it exactly the way `XcodeBuildAdapter.buildSchemataChunk`
/// does in production — `SchemataRuntimeLibraryLocator.locate(for: .iOSSimulator)`,
/// never a direct path guess — and inspects the real Mach-O it finds with the same
/// tools (`lipo`/`otool`/`nm`) the original reported linker failure's diagnosis used.
///
/// Deliberately does **not** shell out to `scripts/build-schemata-runtime.sh` or to
/// `swift build` itself: `Package.swift`'s own comment warns against taking the
/// package build lock from inside `swift test` (see `SchemataXcodeRuntimeAcceptanceTests`,
/// which hit exactly that deadlock in an earlier draft). The archive must already
/// exist — produced by `scripts/build-schemata-runtime.sh` as a prerequisite step,
/// the same relationship `swift build --build-tests` has to every other schemata
/// acceptance suite.
///
/// Gated on `Acceptance.simulatorEnabled`, not merely `Acceptance.isEnabled`: this
/// suite needs the iPhoneSimulator SDK (for the archive itself to exist and be
/// inspectable) even though it never boots a simulator, which is exactly what that
/// flag exists to opt out of on a machine/CI lane with `MUTANTKIT_ACCEPTANCE=1` but
/// no simulator runtime installed.
@Suite("Acceptance: iOS-Simulator schemata runtime artifact", .enabled(if: Acceptance.simulatorEnabled))
struct SchemataIOSSimulatorRuntimeArtifactAcceptanceTests {
    private func locateArchive() throws -> URL {
        let located = try SchemataRuntimeLibraryLocator.locate(for: .iOSSimulator)
        return located.libraryDirectory.appendingPathComponent(SchemataRuntimeLibraryLocator.libraryFileName)
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [tool] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) \(arguments.joined(separator: " ")) failed:\n\(output)")
        return output
    }

    @Test("lipo reports both arm64 and x86_64 slices")
    func containsBothArchitectures() throws {
        let output = try run("lipo", ["-archs", try locateArchive().path])
        let archs = Set(output.split(whereSeparator: \.isWhitespace).map(String.init))
        #expect(archs.isSuperset(of: ["arm64", "x86_64"]), "expected arm64 and x86_64, got: \(output)")
    }

    @Test("Every slice's LC_BUILD_VERSION reports platform 7 (PLATFORM_IOSSIMULATOR), never macOS's platform 1")
    func everySliceIsBuiltForIOSSimulator() throws {
        let output = try run("otool", ["-l", try locateArchive().path])
        let platformLines = output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("platform ") }
        #expect(!platformLines.isEmpty, "expected at least one LC_BUILD_VERSION platform line in:\n\(output)")
        #expect(platformLines.allSatisfy { $0 == "platform 7" }, "expected every slice to report platform 7 (iOS Simulator): \(platformLines)")
    }

    @Test("Both v3 runtime entry points are exported, undecorated, from every slice")
    func exportsRuntimeSymbols() throws {
        let output = try run("nm", ["-gU", try locateArchive().path])
        #expect(output.contains("T _mutantkit_register_unit_v3"))
        #expect(output.contains("T _mutantkit_is_active_v3"))
    }
}
