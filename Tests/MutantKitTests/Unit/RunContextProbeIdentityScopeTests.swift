@testable import CLI
import Foundation
import MutationModel
import XCTest

/// Each cached artifact is keyed by an identity, and an identity that is
/// wider than what it guards is not free: it throws away work that was still
/// valid. These pin the scope of each one — what it must ignore, and what it
/// must still see — on both axes `RunContextProbe.IdentityScope` decides:
/// how much of the `Configuration`, and how precisely the MutantKit build
/// that produced the artifact is identified.
///
/// Split out of `RunContextProbeTests` because that class had grown past the
/// length this repo lints for, not because the subject is unrelated.
final class RunContextProbeIdentityScopeTests: XCTestCase {
    /// The scoped-out half. A per-test coverage map is measured against
    /// `buildBaseline`'s own *unmutated* artifact, so nothing about which
    /// mutants are planned, how they are executed, or how the run reports
    /// changes what it records. Keying it on those anyway is not a
    /// theoretical hit-rate loss: on a real iOS project the pass costs ~100
    /// minutes, and this is exactly what made an `isolated`-vs-`schemata`
    /// comparison, or a `maxMutants` bump, re-measure all of it.
    func testCoverageAttributionScopeIgnoresWhatTheBaselineCannotSee() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        var isolatedFifty = Configuration()
        isolatedFifty.execution.strategy = .isolated
        isolatedFifty.execution.budget = BudgetSettings(maxMutants: 50, seed: 42)
        isolatedFifty.operators.profile = .conservative
        isolatedFifty.reports = [.console]
        var schemataOneFifty = Configuration()
        schemataOneFifty.execution.strategy = .schemata
        schemataOneFifty.execution.budget = BudgetSettings(maxMutants: 150, seed: 7)
        schemataOneFifty.operators.profile = .experimental
        schemataOneFifty.reports = [.console, .json]
        schemataOneFifty.sources.include = ["Sources/Only/**"]

        let digestA = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: isolatedFifty, toolchain: makeToolchain(),
            purpose: "coverageProfileCache3", identityScope: .coverageAttribution
        )
        let digestB = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: schemataOneFifty, toolchain: makeToolchain(),
            purpose: "coverageProfileCache3", identityScope: .coverageAttribution
        )

        XCTAssertEqual(
            digestA, digestB,
            """
            a measurement of the unmutated baseline must be shared across runs that differ only in \
            what they mutate, how they execute it, or how they report
            """
        )
    }

    /// The kept half, and the one that matters for soundness: `project` and
    /// `tests` decide which scheme, destination and test targets the
    /// measurement actually runs, so two configurations differing there
    /// measure genuinely different things and must never share an entry.
    func testCoverageAttributionScopeStillSeparatesSchemeAndTestTargets() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        var unitScheme = Configuration()
        unitScheme.project.scheme = "AppUnit"
        unitScheme.tests.targets = ["AppTests"]
        var uiScheme = unitScheme
        uiScheme.project.scheme = "AppUI"
        var otherTargets = unitScheme
        otherTargets.tests.targets = ["AppTests", "AppIntegrationTests"]

        func digest(_ configuration: Configuration) async throws -> String {
            try await RunContextProbe.computeContextDigest(
                projectRoot: repo, configuration: configuration, toolchain: makeToolchain(),
                purpose: "coverageProfileCache3", identityScope: .coverageAttribution
            )
        }

        let base = try await digest(unitScheme)
        let differentScheme = try await digest(uiScheme)
        let differentTargets = try await digest(otherTargets)

        XCTAssertNotEqual(base, differentScheme, "a different scheme runs a different suite and must re-measure")
        XCTAssertNotEqual(base, differentTargets, "a different test target set enumerates different tests and must re-measure")
    }

    /// The commit SHA is too strict for a measurement that costs ~100
    /// minutes: in a release build it is stamped in, so a commit that never
    /// touched the measurement throws the whole thing away. Observed in the
    /// field with two installs of the same `1.0.4-dev` version.
    func testCoverageAttributionIgnoresTheToolCommitSHA() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        func digest(commit: String?) async throws -> String {
            try await RunContextProbe.computeContextDigest(
                projectRoot: repo, configuration: Configuration(),
                toolchain: makeToolchain(toolCommitSHA: commit),
                purpose: "coverageProfileCache3", identityScope: .coverageAttribution
            )
        }

        let a = try await digest(commit: "aaaaaaaa")
        let b = try await digest(commit: "bbbbbbbb")
        XCTAssertEqual(a, b, "a commit that never touched the measurement must not discard it")
        // …and a development build, where the SHA is nil for every binary
        // ever built locally, must not be the *only* thing standing between
        // two different implementations.
        let withoutCommit = try await digest(commit: nil)
        XCTAssertEqual(withoutCommit, a, "a development build, where the SHA is always nil, needs a real guard too")
    }

    /// The other half: dropping the SHA is only sound because something
    /// precise replaced it. A change to how the measurement is performed
    /// must still miss.
    func testCoverageAttributionSeesTheExecutionImplementationVersion() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        let digest = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: Configuration(), toolchain: makeToolchain(),
            purpose: "coverageProfileCache3", identityScope: .coverageAttribution
        )

        // Asserted through the digest's own inputs rather than by mutating a
        // constant: the point is that the version is *in* the key, so that
        // bumping it invalidates every entry.
        XCTAssertTrue(
            RunContextProbe.IdentityScope.coverageAttribution.toolIdentityComponents
                .contains("executionImplementationVersion=\(ExecutionImplementationVersion.current)"),
            "the coverage scope must carry the one identity that says how the measurement was performed"
        )
        XCTAssertFalse(RunContextProbe.IdentityScope.coverageAttribution.usesToolReleaseIdentity)
        XCTAssertFalse(digest.isEmpty)
    }

    /// The result cache keeps the commit SHA: it already checks
    /// `ExecutionImplementationVersion` and
    /// `MutationVerdictVerifier.currentVersion` at load time, so the SHA is a
    /// third, automatic belt over two precise braces rather than the only
    /// guard.
    func testResultCacheStillSeesTheToolCommitSHA() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        func digest(commit: String?) async throws -> String {
            try await RunContextProbe.computeContextDigest(
                projectRoot: repo, configuration: Configuration(),
                toolchain: makeToolchain(toolCommitSHA: commit), purpose: "resultCache2"
            )
        }

        let a = try await digest(commit: "aaaaaaaa")
        let b = try await digest(commit: "bbbbbbbb")
        XCTAssertNotEqual(a, b)
    }

    /// The scope narrows only the purpose that asked for it. A mutant's
    /// evaluated outcome can depend on nearly all of the configuration, so
    /// the result cache stays keyed on the whole of it — the conservative
    /// default, where a setting added later is folded in without anyone
    /// having to remember to.
    func testResultCacheStillSeesTheWholeConfiguration() async throws {
        let (repo, _) = try await committedBaseline()
        defer { try? FileManager.default.removeItem(at: repo) }

        var isolated = Configuration()
        isolated.execution.strategy = .isolated
        var schemata = Configuration()
        schemata.execution.strategy = .schemata

        let digestA = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: isolated, toolchain: makeToolchain(), purpose: "resultCache2"
        )
        let digestB = try await RunContextProbe.computeContextDigest(
            projectRoot: repo, configuration: schemata, toolchain: makeToolchain(), purpose: "resultCache2"
        )

        XCTAssertNotEqual(digestA, digestB, "the result cache's default scope must still cover execution settings")
    }

    private func committedBaseline() async throws -> (URL, String) {
        let fixture = try await GitFixture.committedBaseline()
        return (fixture.repo, fixture.state)
    }
}
