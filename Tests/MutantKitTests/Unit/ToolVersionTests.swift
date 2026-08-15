@testable import CLI
import Foundation
import Testing

/// `ToolVersion` is the single source of truth for `mutantkit --version`
/// (wired via `MutantKit.configuration.version` in `MutantKit.swift`) and for
/// every plan/report's recorded toolchain fingerprint. A version string that
/// drifts between those call sites would silently break reproducibility, so
/// this pins both the honest "development build" shape (what every local
/// `swift build` produces) and the substitution contract
/// `Scripts/release-build.sh` depends on to stamp a tagged release.
@Suite("ToolVersion contract")
struct ToolVersionTests {
    /// A checkout that has not been through `Scripts/release-build.sh` must
    /// report itself as a development build rather than claiming a version it
    /// does not have — `nil` `commitSHA` and a `-dev` suffixed version are the
    /// truthful defaults committed to source.
    @Test("development build reports an honest dev version and no commit SHA")
    func developmentBuildIsHonest() {
        #expect(ToolVersion.version == "0.1.0-dev")
        #expect(ToolVersion.commitSHA == nil)
    }

    /// `MutantKit.swift` passes `ToolVersion.summary` directly to
    /// `CommandConfiguration(version:)`, so this is what `mutantkit --version`
    /// prints. The Homebrew formula's own test (`homebrew-mutantkit/Formula/
    /// mutantkit.rb`) asserts `shell_output("--version")` matches
    /// `"mutantkit #{version}"` — the first line here is that contract's other
    /// half.
    @Test("summary's first line matches the Homebrew formula's version assertion")
    func summaryFirstLineIsMutantkitVersion() {
        let firstLine = ToolVersion.summary.split(separator: "\n", maxSplits: 1).first.map(String.init)
        #expect(firstLine == "mutantkit \(ToolVersion.version)")
    }

    /// A development build must not silently claim a commit it was not built
    /// from — `summary` distinguishes that case in prose rather than printing
    /// a stale or fabricated SHA.
    @Test("summary reports a development build honestly when commitSHA is nil")
    func summaryReportsDevelopmentBuildHonestly() {
        if ToolVersion.commitSHA == nil {
            #expect(ToolVersion.summary.contains("commit: (development build)"))
        }
    }

    /// `Scripts/release-build.sh` substitutes both fields with a single pair
    /// of `sed` patterns:
    ///   public static let version = ".*"
    ///   public static let commitSHA: String? = nil
    /// If either literal drifts from what's in `Sources/CLI/Version.swift`,
    /// the release script's substitution silently becomes a no-op — the built
    /// binary would still report "0.1.0-dev" even after being "stamped" for a
    /// real release. This pins the exact literals the script's `sed` targets,
    /// so a change to `Version.swift` that breaks the substitution fails a
    /// fast unit test instead of surfacing as a mislabeled release asset.
    @Test("release-build.sh's substitution targets are present verbatim in Version.swift")
    func releaseScriptSubstitutionTargetsExist() throws {
        let versionFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Unit
            .deletingLastPathComponent() // MutantKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources/CLI/Version.swift")
        let source = try String(contentsOf: versionFile, encoding: .utf8)

        #expect(source.contains(#"public static let version = "0.1.0-dev""#))
        #expect(source.contains("public static let commitSHA: String? = nil"))
    }
}
