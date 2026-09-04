import Foundation
@testable import MutationExecution
import Testing

/// Real, subprocess-backed coverage for `ToolchainCacheFingerprintProbe` —
/// the same "ask the real environment" convention `ToolchainProbeTests`
/// (`Sources/CLI/ToolchainProbe.swift`'s own test suite) already follows.
/// Fast (four short subprocess invocations, well under a second each on
/// this machine) and therefore not gated behind `Acceptance` — unlike
/// `SharedModuleCacheTests`, nothing here spawns a real `swift build`.
@Suite("ToolchainCacheFingerprintProbe: real toolchain identity")
struct ToolchainCacheFingerprintProbeTests {
    @Test("Every field resolves to a real, non-\"unknown\" value on this machine — not fabricated or hardcoded")
    func resolvesRealValues() async throws {
        let workingDirectory = FileManager.default.temporaryDirectory
        let fingerprint = await ToolchainCacheFingerprintProbe.shared.fingerprint(workingDirectory: workingDirectory)

        #expect(fingerprint.swiftVersion != "unknown")
        #expect(fingerprint.xcodeVersion != "unknown")
        #expect(fingerprint.sdkVersion != "unknown")
        #expect(fingerprint.targetTriple != "unknown")
        // A real triple, not a placeholder — `swift -print-target-info`'s own
        // shape (confirmed live on this machine: "arm64-apple-macosx26.0").
        #expect(fingerprint.targetTriple.contains("-apple-"))
    }

    @Test("Memoized: two calls in the same process return the identical value")
    func memoizesAcrossCalls() async throws {
        let workingDirectory = FileManager.default.temporaryDirectory
        let first = await ToolchainCacheFingerprintProbe.shared.fingerprint(workingDirectory: workingDirectory)
        let second = await ToolchainCacheFingerprintProbe.shared.fingerprint(workingDirectory: workingDirectory)
        #expect(first == second)
    }
}

/// Pure, no-subprocess coverage for `ToolchainCacheFingerprintProbe
/// .resolvedValue(for:)` — the collision-safety invariant this codebase
/// already tests for the identical distinction one layer up
/// (`ToolchainProbeResult.identityEvidenceComplete`,
/// `ToolchainCacheIdentityCompletenessTests`): a genuinely reproducible
/// absence is safe to fold into a fixed, shared "unknown", but an
/// untrustworthy probe (lost evidence, not a fact about the machine) must
/// never be.
@Suite("ToolchainCacheFingerprintProbe: unknown-fallback collision safety")
struct ToolchainCacheFingerprintProbeUnknownFallbackTests {
    @Test("A genuinely absent executable resolves to the stable, shared \"unknown\" string")
    func notPresentResolvesToTheStableUnknownString() {
        #expect(ToolchainCacheFingerprintProbe.resolvedValue(for: .notPresent) == "unknown")
    }

    @Test("An untrustworthy probe never resolves to the plain string \"unknown\" that a genuine absence uses")
    func untrustworthyProbeNeverResolvesToThePlainUnknownString() {
        #expect(ToolchainCacheFingerprintProbe.resolvedValue(for: .untrustworthy) != "unknown")
    }

    @Test(
        """
        Two untrustworthy probes never resolve to the identical string — two different toolchains that each merely \
        happen to hit an untrustworthy probe must never collapse onto the same fingerprint digest and therefore the \
        same, wrongly shared cache directory
        """
    )
    func twoUntrustworthyProbesNeverCollide() {
        let first = ToolchainCacheFingerprintProbe.resolvedValue(for: .untrustworthy)
        let second = ToolchainCacheFingerprintProbe.resolvedValue(for: .untrustworthy)
        #expect(first != second)
    }

    @Test("A real value resolves to exactly itself, verbatim")
    func realValueResolvesVerbatim() {
        #expect(ToolchainCacheFingerprintProbe.resolvedValue(for: .value("Apple Swift version 6.3.3")) == "Apple Swift version 6.3.3")
    }
}

/// Pure, no-subprocess coverage for the JSON half of
/// `ToolchainCacheFingerprintProbe`'s target-triple probe — parsing `swift
/// -print-target-info`'s own real output shape, captured live from this
/// machine's toolchain during this task's own investigation, so this pins
/// the *actual* shape rather than a guessed one.
@Suite("ToolchainCacheFingerprintProbe: target-info JSON parsing")
struct ToolchainCacheFingerprintProbeJSONParsingTests {
    /// A real `swift -print-target-info` payload from this machine (Xcode
    /// path genericized; every other field verbatim), trimmed to the
    /// top-level shape that matters here.
    private static let realSample = """
    {
      "compilerVersion": "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)",
      "target": {
        "triple": "arm64-apple-macosx26.0",
        "unversionedTriple": "arm64-apple-macosx",
        "moduleTriple": "arm64-apple-macos",
        "platform": "macosx",
        "arch": "arm64"
      },
      "paths": {
        "runtimeResourcePath": "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
      }
    }
    """

    @Test("Parses the real triple out of a real swift -print-target-info payload")
    func parsesRealSample() {
        let triple = ToolchainCacheFingerprintProbe.parseTargetTriple(fromTargetInfoJSON: Data(Self.realSample.utf8))
        #expect(triple == "arm64-apple-macosx26.0")
    }

    @Test("Malformed JSON parses to nil, not a crash or a fabricated value")
    func malformedJSONParsesToNil() {
        let triple = ToolchainCacheFingerprintProbe.parseTargetTriple(fromTargetInfoJSON: Data("not json".utf8))
        #expect(triple == nil)
    }

    @Test("Valid JSON missing the target.triple field parses to nil rather than guessing")
    func missingFieldParsesToNil() {
        let triple = ToolchainCacheFingerprintProbe.parseTargetTriple(fromTargetInfoJSON: Data(#"{"target": {}}"#.utf8))
        #expect(triple == nil)
    }
}
