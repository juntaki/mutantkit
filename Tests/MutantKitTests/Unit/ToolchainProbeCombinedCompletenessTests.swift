@testable import CLI
import Testing

/// Direct, no-subprocess regression for `ToolchainProbe
/// .combinedIdentityEvidenceComplete`: the pure function `fingerprint`/
/// `buildSDKIdentity` both call to decide `identityEvidenceComplete`, split out
/// exactly the way `ProcessSupervisor.classify(readResult:errno:)` was, so
/// this specific combining logic can be pinned without going through a real
/// `swift --version`/`xcodebuild -version`/`xcrun` subprocess at all.
///
/// `ToolchainCacheIdentityCompletenessTests` covers the layer above this —
/// `RunContextProbe` refusing a cache key once handed a `false`
/// `toolchainCacheIdentityComplete` — but hand-constructs that `false`
/// directly rather than calling this function, so it cannot catch a defect
/// in the combining logic itself. This suite calls the real function.
@Suite("ToolchainProbe: combined identity-evidence completeness")
struct ToolchainProbeCombinedCompletenessTests {
    @Test("Every probe complete (swift, xcode, sdk-version, sdk-build) combines to a complete identity")
    func allFourProbesCompleteCombinesToComplete() {
        #expect(ToolchainProbe.combinedIdentityEvidenceComplete(
            .value("swift-1"), .value("xcode-1"), .value("sdk-version-1"), .value("sdk-build-1")
        ))
    }

    /// `.notPresent` is a genuine, reproducible fact about the machine (a
    /// missing executable — nothing was ever launched), not lost or
    /// unproven evidence — it must never veto completeness the way
    /// `.incomplete`/`.probeFailed` does.
    @Test("A notPresent probe alone does not make the combined identity incomplete")
    func notPresentProbeAloneStaysComplete() {
        #expect(ToolchainProbe.combinedIdentityEvidenceComplete(
            .notPresent, .value("xcode-1"), .value("sdk-version-1"), .value("sdk-build-1")
        ))
    }

    /// The gap a round-4 review found: a subprocess that actually ran but
    /// timed out, was signalled, exited non-zero, or produced no parseable
    /// version despite exiting `0` is not a reproducible fact about the
    /// machine the way `.notPresent` is — two machines with genuinely
    /// different toolchains, one hitting a one-off `.probeFailed` on this
    /// exact probe, must not collapse onto the identical identity. Distinct
    /// from `notPresentProbeAloneStaysComplete` above: the only difference
    /// between the two outcomes is *why* no value was captured, and only
    /// one of the two reasons is safe to hash.
    @Test("A probeFailed outcome alone rejects the combined identity, unlike a notPresent outcome")
    func probeFailedAloneRejects() {
        #expect(!ToolchainProbe.combinedIdentityEvidenceComplete(
            .probeFailed, .value("xcode-1"), .value("sdk-version-1"), .value("sdk-build-1")
        ))
    }

    @Test("A version-probe-incomplete outcome alone rejects the combined identity")
    func versionIncompleteAloneRejects() {
        #expect(!ToolchainProbe.combinedIdentityEvidenceComplete(
            .value("swift-1"), .value("xcode-1"), .incomplete, .value("sdk-build-1")
        ))
    }

    /// The exact case a round-2 adversarial experiment proved slips through
    /// `ToolchainCacheIdentityCompletenessTests` today: reverting
    /// `buildSDKIdentity`'s `version.isIncomplete || build.isIncomplete` to
    /// `&&` (ignoring a build-number-only incompleteness while its paired
    /// version probe is fine) still built clean and passed every test meant
    /// to cover this, because that suite never calls the real combining
    /// logic. This test calls `combinedIdentityEvidenceComplete` directly and
    /// must fail the moment that regression is reintroduced.
    @Test("A build-number-probe-incomplete outcome alone (version sub-probe fine) still rejects the combined identity")
    func buildNumberIncompleteAloneRejects() {
        #expect(!ToolchainProbe.combinedIdentityEvidenceComplete(
            .value("swift-1"), .value("xcode-1"), .value("sdk-version-1"), .incomplete
        ))
    }
}
