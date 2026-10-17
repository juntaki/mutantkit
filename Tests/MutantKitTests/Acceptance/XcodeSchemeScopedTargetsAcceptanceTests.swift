@testable import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// General rule for Xcode target resolution, fixed on `Fixtures/XcodeSchemeScope`:
///
///     scheme "App" builds App, and App depends on Core
///     Shared/Pricing.swift is compiled by App *and* by Experimental, which the scheme never builds
///     Experimental/Banner.swift is compiled only by Experimental
///
/// Only targets the run's scheme reaches can be embedded and exercised. Embedding a shared source for a
/// target the scheme never builds produced a chunk whose built product does not exist, which forfeited
/// schemata for every mutation in it (found on wikipedia-ios, whose `Experimental` app shares sources
/// with `Wikipedia`).
@Suite("Xcode target resolution is scoped to the run's scheme")
struct XcodeSchemeScopedTargetsAcceptanceTests {
    @Test("shared sources keep the built targets' placements, drop the unbuilt target, and report sources only it compiles")
    func resolutionIsScopedToTheScheme() async throws {
        let root = try Acceptance.stageFixture("XcodeSchemeScope")
        let resolution = try await XcodeTargetResolver.resolveSchemeScopedTargetInfo(projectRoot: root, scheme: "App")

        func targets(_ file: String) -> [String] { (resolution.targetInfo[file] ?? []).map(\.target).sorted() }
        #expect(targets("Shared/Pricing.swift") == ["App"], "\(targets("Shared/Pricing.swift"))")
        #expect(targets("Core/Limits.swift") == ["Core"], "\(targets("Core/Limits.swift"))")
        #expect(resolution.targetInfo["Experimental/Banner.swift"] == nil)
        #expect(resolution.filesOutsideScheme == ["Experimental/Banner.swift"], "\(resolution.filesOutsideScheme)")
    }

    @Test("an unknown or unset scheme is not provable and is refused rather than widened to every target")
    func unprovableSchemeFailsClosed() async throws {
        let root = try Acceptance.stageFixture("XcodeSchemeScope")
        for scheme in [nil, "NoSuchScheme"] as [String?] {
            await #expect(throws: XcodeTargetResolver.ResolutionError.self) {
                _ = try await XcodeTargetResolver.resolveSchemeScopedTargetInfo(projectRoot: root, scheme: scheme)
            }
        }
    }
}

@Suite("Schemata on a project whose sources are shared with an unbuilt target", .enabled(if: Acceptance.simulatorEnabled))
struct XcodeSchemeScopedSchemataAcceptanceTests {
    private static let sharedRun = Result {
        try Acceptance.planAndRun(
            fixture: "XcodeSchemeScope",
            configuration: """
            version: 1
            project:
              kind: xcodeProject
              scheme: App
              destination: \(try Acceptance.iPhoneDestination())
            sources:
              include: [Core/**, Shared/**, Experimental/**]
            tests:
              targets: [AppTests]
            operators:
              profile: default
            execution:
              strategy: schemata
              workers: 2
            reports: [console, json]
            """
        )
    }

    @Test("receipts resolve and schemata executes; the unbuilt target's source falls back per mutation, not per run")
    func schemataExecutesDespiteTheUnbuiltTarget() throws {
        let run = try Self.sharedRun.get()
        #expect(run.exitCode == 0, "\(run.runOutput)")
        let strategy = try #require(run.report.executionStrategy)
        #expect(strategy.degradationReason == nil, "\(String(describing: strategy.degradationReason))")
        #expect(strategy.effectiveCount > 0)
        let reasons = Set((strategy.fallbackReasonCounts ?? [:]).keys)
        #expect(!reasons.contains("buildReceiptUnavailable"), "\(reasons)")
        let qualification = SchemataQualification(maximumUnexpectedFallbacks: strategy.fallbackCount)
        #expect(qualification.violations(in: run.report).isEmpty, "\(qualification.violations(in: run.report))")
    }
}
