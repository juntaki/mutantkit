import Foundation
import MutationModel
import Testing

/// Caught by `codex review` before this shipped, not hypothetical: the
/// `["**"]` `sources.include` marker `init`/`setup` now write for a
/// resolved SwiftPM detection (`ProjectDetectionPlan
/// .detectedSwiftPMTestTargetsAndSources`'s own doc comment) means "no
/// additional narrowing — `plan` resolves the real scope live from
/// SwiftPM's build graph." That marker is safe only *intersected* with a
/// real, successful live resolution; read on its own by `SourceFileWalker`
/// it means "every `.swift` file in the whole project." An earlier revision
/// of `SwiftPMLiveSourceResolution.resolve` returned `nil` (meaning "keep
/// `sources.include` unchanged") on every failure path, including ones a
/// real `mutantkit.yml` can genuinely hit — which would have silently
/// turned a normal, narrow SwiftPM run into a whole-repository one the
/// moment live resolution could not proceed for any reason.
///
/// Exercises one such real, constructible failure path end-to-end (an
/// out-of-root `project.path`, `SwiftPMLiveSourceResolution
/// .PackageLocation.outsideRoot`) through the real `mutantkit` binary
/// against a real fixture with real, mutable production sources — proving
/// the fix degrades to an explicit, empty, loudly-warned-about scope
/// instead of silently discovering mutations across the whole fixture.
@Suite("Acceptance: SwiftPM live source resolution fails safe", .enabled(if: Acceptance.isEnabled))
struct SwiftPMLiveSourceResolutionFailSafeAcceptanceTests {
    @Test("plan degrades to an empty, warned-about scope when project.path resolves outside the project root")
    func outOfRootProjectPathDegradesToEmptyScopeNotWholeRepository() throws {
        let staged = try Acceptance.stageFixture("SwiftPackageMacOS")
        defer { try? FileManager.default.removeItem(at: staged) }

        let configuration = """
        version: 1
        project:
          kind: swiftPackageMacOS
          path: /this-path-is-deliberately-outside-the-staged-fixture-root
        sources:
          include: ["**"]
        tests:
          targets: [SomeTests]
        operators:
          profile: default
        """
        try Data(configuration.utf8).write(to: staged.appendingPathComponent("mutantkit.yml"), options: .atomic)

        let result = try Acceptance.run(["plan", "--output", "failsafe-plan.json"], in: staged)

        #expect(result.exitCode == 0, "an empty discovery is not itself an error")
        #expect(
            result.output.contains("discovered: 0"),
            """
            an unresolvable project.path with sources.include: ["**"] must degrade to an empty scope, \
            not fall back to matching every .swift file in the fixture — got: \(result.output)
            """
        )
        #expect(result.output.contains("warning: zero mutations discovered"))
    }
}
