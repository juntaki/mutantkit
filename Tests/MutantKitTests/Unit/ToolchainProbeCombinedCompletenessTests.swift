@testable import CLI
import Testing

/// Direct, no-subprocess regression for `ToolchainProbe
/// .combinedCacheIdentityComplete`: the pure function `fingerprint`/
/// `buildSDKIdentity` both call to decide `cacheIdentityComplete`, split out
/// exactly the way `ProcessSupervisor.classify(readResult:errno:)` was, so
/// this specific combining logic can be pinned without going through a real
/// `swift --version`/`xcodebuild -version`/`xcrun` subprocess at all.
///
/// `ToolchainCacheIdentityCompletenessTests` covers the layer above this —
/// `RunContextProbe` refusing a cache key once handed a `false`
/// `toolchainCacheIdentityComplete` — but hand-constructs that `false`
/// directly rather than calling this function, so it cannot catch a defect
/// in the combining logic itself. This suite calls the real function.
@Suite("ToolchainProbe: combined cache-identity completeness")
struct ToolchainProbeCombinedCompletenessTests {
    @Test("Every probe complete (swift, xcode, sdk-version, sdk-build) combines to a complete cache identity")
    func allFourProbesCompleteCombinesToComplete() {
        #expect(ToolchainProbe.combinedCacheIdentityComplete(
            .value("swift-1"), .value("xcode-1"), .value("sdk-version-1"), .value("sdk-build-1")
        ))
    }

    /// `.unavailable` is a genuine, reproducible fact about the machine
    /// (missing executable, non-zero exit), not lost evidence — it must
    /// never veto completeness the way `.incomplete` does.
    @Test("An unavailable probe alone does not make the combined identity incomplete")
    func unavailableProbeAloneStaysComplete() {
        #expect(ToolchainProbe.combinedCacheIdentityComplete(
            .unavailable, .value("xcode-1"), .value("sdk-version-1"), .value("sdk-build-1")
        ))
    }

    @Test("A version-probe-incomplete outcome alone rejects the combined identity")
    func versionIncompleteAloneRejects() {
        #expect(!ToolchainProbe.combinedCacheIdentityComplete(
            .value("swift-1"), .value("xcode-1"), .incomplete, .value("sdk-build-1")
        ))
    }

    /// The exact case a round-2 adversarial experiment proved slips through
    /// `ToolchainCacheIdentityCompletenessTests` today: reverting
    /// `buildSDKIdentity`'s `version.isIncomplete || build.isIncomplete` to
    /// `&&` (ignoring a build-number-only incompleteness while its paired
    /// version probe is fine) still built clean and passed every test meant
    /// to cover this, because that suite never calls the real combining
    /// logic. This test calls `combinedCacheIdentityComplete` directly and
    /// must fail the moment that regression is reintroduced.
    @Test("A build-number-probe-incomplete outcome alone (version sub-probe fine) still rejects the combined identity")
    func buildNumberIncompleteAloneRejects() {
        #expect(!ToolchainProbe.combinedCacheIdentityComplete(
            .value("swift-1"), .value("xcode-1"), .value("sdk-version-1"), .incomplete
        ))
    }
}
