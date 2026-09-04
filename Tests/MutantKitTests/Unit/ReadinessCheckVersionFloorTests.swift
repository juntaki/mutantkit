@testable import CLI
import Foundation
import MutationModel
import Testing

/// `ReadinessCheck.xcodeItem`'s version-floor check (README.md: "Requires
/// ... Xcode 16+") and the `leadingMajorVersion(in:)` parser it depends on.
/// The below-floor branch cannot be exercised by driving the real toolchain
/// probe — this machine's own installed Xcode is above the floor — so these
/// tests hand `xcodeItem` a hand-built `ToolchainFingerprint` instead, and
/// test the pure parser directly.
@Suite("ReadinessCheck: Xcode version-floor check")
struct ReadinessCheckVersionFloorTests {
    // MARK: - leadingMajorVersion(in:)

    @Test(
        "leadingMajorVersion(in:) extracts the first run of digits, or nil when none exist",
        arguments: [
            ("Xcode 16.4", 16),
            ("Xcode 16.4 Build version 16E140", 16),
            ("16", 16),
            ("Xcode 9", 9),
            ("", nil),
            ("Xcode", nil),
            ("not a version string", nil)
        ] as [(String, Int?)]
    )
    func leadingMajorVersionParsing(text: String, expected: Int?) {
        #expect(ReadinessCheck.leadingMajorVersion(in: text) == expected)
    }

    // MARK: - xcodeItem(toolchain:)

    @Test("Below the documented Xcode floor: warning, with a remedy naming the floor")
    func belowFloorXcodeWarns() {
        let item = ReadinessCheck.xcodeItem(toolchain: fingerprint(xcodeVersion: "Xcode 15.4"))
        #expect(item.status == .warning)
        #expect(item.code == .xcodeToolchain)
        #expect(item.detail.contains("below the documented floor"))
        #expect(item.detail.contains("Xcode 16+"))
        #expect(item.remedy?.contains("Xcode 16+") == true)
    }

    @Test("Exactly at the documented Xcode floor: ok, no remedy")
    func atFloorXcodeIsOK() {
        let item = ReadinessCheck.xcodeItem(toolchain: fingerprint(xcodeVersion: "Xcode 16.0"))
        #expect(item.status == .ok)
        #expect(item.remedy == nil)
        #expect(!item.detail.contains("below the documented floor"))
    }

    @Test("Above the documented Xcode floor: ok, no remedy")
    func aboveFloorXcodeIsOK() {
        let item = ReadinessCheck.xcodeItem(toolchain: fingerprint(xcodeVersion: "Xcode 26.0"))
        #expect(item.status == .ok)
        #expect(item.remedy == nil)
    }

    @Test("An unparseable Xcode version string is treated as \"cannot confirm the floor\", not \"below it\"")
    func unparseableXcodeVersionIsOK() {
        let item = ReadinessCheck.xcodeItem(toolchain: fingerprint(xcodeVersion: "Xcode Ultra Edition"))
        #expect(item.status == .ok)
        #expect(item.remedy == nil)
    }

    @Test("No Xcode found at all: warning, unrelated to the version floor")
    func missingXcodeWarns() {
        let item = ReadinessCheck.xcodeItem(toolchain: fingerprint(xcodeVersion: nil))
        #expect(item.status == .warning)
        #expect(item.detail == "not found")
    }

    // MARK: - Helpers

    private func fingerprint(xcodeVersion: String?) -> ToolchainFingerprint {
        ToolchainFingerprint(
            toolVersion: "test",
            toolCommitSHA: nil,
            swiftVersion: "Swift version 6.0",
            swiftSyntaxVersion: "600.0.0",
            xcodeVersion: xcodeVersion
        )
    }
}
