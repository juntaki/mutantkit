import AppleBuildAdapters
import Foundation
@testable import MutationExecution
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import SwiftFrontend
import Testing

/// ADR-0008 §5 item 5(b): the actual evidence gate for the crash/no-rebuild
/// policy choice. §4(c) scopes containment to forced *timeout*-kills only,
/// on the reasoning that §1.2's documented residue/escaped-descendant risk
/// is specific to processes `ProcessSupervisor` itself force-kills after a
/// timeout — but no source evidence traced for that ADR establishes that an
/// *ordinarily-crashing* process cannot also leave residue. This suite is
/// real, non-mocked, and slow by design (a real `swift build` + `swift
/// test` against a synthetic mutant, in-process against the real
/// `SwiftPackageMacOSAdapter` — the same pattern `SchemataMutationRunner
/// AcceptanceTests` already uses, which sidesteps the documented
/// subprocess-env-inheritance issue the CLI-driven `Acceptance.planAndRun`
/// path has for schemata suites): it engineers a mutant that, once
/// activated, forks a real background child (identifiable in `ps`/`pgrep`
/// output by a unique marker path in its own argv) and writes a real marker
/// file, then crashes promptly.
///
/// **Real findings from running this suite (not a hypothesis — measured
/// directly, twice, with two different crash mechanisms):**
///
/// 1. **Residue is real.** A promptly-crashing mutant does leave a live
///    descendant behind — the background child survives the crash and is
///    still running, findable by `pgrep`, after the whole run (baseline +
///    mutant + finalization) completes. This resolves the "can a prompt
///    crash also leave residue" question in the affirmative — the same
///    conclusion §4(c) flagged as the thing this test needed to establish
///    before being taken on faith either way.
/// 2. **But the obvious fix — widen containment's trigger to also key off
///    `.crashed`/`.failed` — is not safe, and the evidence shows why.**
///    Under SwiftPM's `swift test`/XCTest runner specifically, neither
///    `fatalError(_:)` nor a raw wild-pointer trap (SIGSEGV/SIGBUS) inside a
///    test method produces `TestRunResult.status == .crashed` — XCTest's own
///    crash handling intercepts both and reports them through its
///    structured test output as an ordinary failed assertion
///    (`.failed` -> `.killedByAssertion`), indistinguishable at the
///    `TestRunResult.status` level from a real assertion legitimately
///    catching the mutant. `.crashed` appears to be unreachable from an
///    in-test-method crash under this specific adapter at all. Consequently:
///    keying containment off `.crashed` would be inert (nothing to trigger
///    on), and keying it off `.failed` would rebuild after almost *every*
///    ordinary kill — the overwhelming majority of real schemata
///    evaluations — destroying schemata mode's entire performance
///    rationale for a residue risk `.failed` alone cannot actually predict.
///
/// **Disposition:** §4(c)'s scoping (containment triggers on `.timedOut`
/// only) is *not* changed by this finding — changing it the way the ADR's
/// text anticipated would trade a real but narrow residue risk for a much
/// larger, certain performance regression. The residue risk this test
/// confirmed is real and should be tracked as follow-up work, but the right
/// fix is a different mechanism than "widen the status trigger" — e.g.
/// snapshotting the process descendant tree after *every* primary run
/// (independent of `status`) and reaping anything new, the same
/// `sysctl(KERN_PROC_ALL)`-based technique `ProcessSupervisor` already uses
/// for a forced timeout-kill (§1.2), applied unconditionally rather than
/// keyed off any single `TestRunResult` field. That is new design work, out
/// of scope for this ADR's already-frozen decision, not a same-milestone
/// code change this evidence justifies making unreviewed.
///
/// Off by default like every other acceptance suite: `MUTANTKIT_ACCEPTANCE=1 swift test`.
@Suite("Acceptance: ADR-0008 crash residue (evidence gate)", .enabled(if: Acceptance.isEnabled))
struct SchemataCrashResidueAcceptanceTests {
    private static let relativePath = "Sources/CrashResidueFixtureLib/Widget.swift"

    /// The one mutation candidate in this fixture: `false -> true` makes the
    /// test below take the residue-then-crash branch; the baseline
    /// (`false`) takes the harmless branch. Exactly one candidate, so
    /// schemata mode has nothing to disambiguate — the chunk's single
    /// embedded entry is unambiguously this mutant.
    private static func librarySource(markerPath: String) -> String {
        """
        public func shouldLeaveResidueAndCrash() -> Bool {
            false
        }
        """
    }

    /// `tail -f <marker>` is the stand-in "hung descendant": it never exits
    /// on its own, and its own argv contains `markerPath`, so
    /// `survivingProcesses(referencing:)` (the same `pgrep -fl` pattern
    /// `ProcessSupervisionAcceptanceTests` already uses for isolated mode's
    /// hang) can find it from *outside* the crashed process, after the
    /// whole run completes, regardless of whether anything reaped it.
    private static func testSource(markerPath: String) -> String {
        """
        import XCTest
        import CrashResidueFixtureLib

        final class CrashResidueFixtureLibTests: XCTestCase {
            func testShouldLeaveResidueAndCrash() {
                if shouldLeaveResidueAndCrash() {
                    FileManager.default.createFile(atPath: "\(markerPath)", contents: Data())
                    let child = Process()
                    child.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
                    child.arguments = ["-f", "\(markerPath)"]
                    // Its own /dev/null, not inherited descriptors: a child
                    // that shares this process's stdout pipe would keep that
                    // pipe open after this process crashes, so the harness
                    // reading it never sees EOF and reports a timeout
                    // instead of a crash — measured directly (see ADR-0008
                    // §5 item 5(b) commit history): the harness's crash
                    // classification depends on this.
                    child.standardOutput = FileHandle.nullDevice
                    child.standardError = FileHandle.nullDevice
                    child.standardInput = FileHandle.nullDevice
                    try? child.run()
                    // A raw trap, not `fatalError(_:)`: XCTest's own runner
                    // intercepts `fatalError` and reports it through
                    // structured test output as an ordinary failed
                    // assertion (`TestRunResult.status == .failed`,
                    // indistinguishable from a real assertion catching the
                    // mutant) — measured directly. An unguarded wild-pointer
                    // write raises SIGSEGV/SIGBUS directly, which is what
                    // this test actually needs to characterize.
                    let wildPointer = UnsafeMutablePointer<Int>(bitPattern: 0x4)!
                    wildPointer.pointee = 1
                }
                XCTAssertTrue(true)
            }
        }
        """
    }

    private func stageFixture(markerPath: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-crash-residue-\(UUID().uuidString)")
        let librarySourcesDirectory = directory.appendingPathComponent("Sources/CrashResidueFixtureLib")
        let testSourcesDirectory = directory.appendingPathComponent("Tests/CrashResidueFixtureLibTests")
        try FileManager.default.createDirectory(at: librarySourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testSourcesDirectory, withIntermediateDirectories: true)

        let packageManifest = """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "CrashResidueFixtureLib",
            platforms: [.macOS(.v14)],
            targets: [
                .target(name: "CrashResidueFixtureLib"),
                .testTarget(name: "CrashResidueFixtureLibTests", dependencies: ["CrashResidueFixtureLib"])
            ]
        )
        """
        try Data(packageManifest.utf8).write(to: directory.appendingPathComponent("Package.swift"))
        try Data(Self.librarySource(markerPath: markerPath).utf8).write(to: directory.appendingPathComponent(Self.relativePath))
        try Data(Self.testSource(markerPath: markerPath).utf8)
            .write(to: testSourcesDirectory.appendingPathComponent("CrashResidueFixtureLibTests.swift"))
        return directory
    }

    private func lowerFixture(markerPath: String) throws -> (point: MutationPoint, program: SchemataProgram) {
        let source = Self.librarySource(markerPath: markerPath)
        let points = try CoreOperatorExpansionTestSupport.discover(
            source, operatorID: BoolLiteralInversionOperator.descriptor.id, relativePath: Self.relativePath
        )
        let point = try #require(points.first)
        #expect(points.count == 1, "expected exactly one candidate — this fixture must be unambiguous")

        let chunk = SchemataChunk(
            chunkID: "crash-residue-fixture-chunk", points: [point],
            projectIdentity: "CrashResidueFixtureLib.xcodeproj",
            target: "CrashResidueFixtureLib", module: "CrashResidueFixtureLib", product: "CrashResidueFixtureLib"
        )
        let program = try BoolLiteralSchemataLowerer().lower(
            chunk, sources: [SchemataSourceFile(relativePath: Self.relativePath, contents: source)]
        )
        return (point, program)
    }

    /// `pgrep -fl <needle>` — mirrors `ProcessSupervisionAcceptanceTests
    /// .survivingProcesses(referencing:)` exactly, so this evidence is
    /// gathered the same, already-trusted way isolated mode's own hang
    /// acceptance suite gathers it.
    private func survivingProcesses(referencing needle: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", needle]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.contains("pgrep") }
    }

    @Test("A prompt crash (not a timeout) that already left a background child and a marker file: gathers real residue evidence")
    func promptCrashResidueEvidence() async throws {
        let markerPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-adr0008-crash-marker-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: markerPath) }

        let projectDirectory = try stageFixture(markerPath: markerPath)
        defer { try? FileManager.default.removeItem(at: projectDirectory) }
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutantkit-crash-residue-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let (point, program) = try lowerFixture(markerPath: markerPath)
        let originalSources = [Self.relativePath: Data(Self.librarySource(markerPath: markerPath).utf8)]

        let adapter = SwiftPackageMacOSAdapter(configuration: Configuration())
        let workspaces = try WorkspaceManager(projectRoot: projectDirectory, scratchRoot: scratchRoot)
        let runner = SchemataMutationRunner(
            planID: "plan-crash-residue", workUnitID: "plan-crash-residue",
            programs: [program], points: [point.id: point], originalSources: originalSources,
            build: adapter, test: adapter, workspaces: workspaces, timeouts: TimeoutSettings(baselineSeconds: 120),
            toolchainHash: "test-toolchain", buildArgumentsHash: "test-build-arguments", policy: .permissive
        )

        let outcome = try await runner.run()

        // Necessary precondition for this evidence to mean anything: the
        // mutant genuinely activated the crash branch (proven by the marker
        // file existing at all — the baseline `false` path never creates
        // it).
        let markerWritten = FileManager.default.fileExists(atPath: markerPath)
        #expect(markerWritten, "the mutated branch must have run for real and written its marker before crashing")

        let result = try #require(outcome.results.first { $0.point.id == point.id })
        // Not `.timedOut`/`.survived` — some non-timeout, non-passing
        // classification, whatever XCTest's own crash handling maps this
        // to (measured: `.killedByAssertion`, from `TestRunResult.status ==
        // .failed` — see this suite's own doc comment for why `.crashed`
        // itself turns out to be unreachable here).
        #expect(
            result.outcome != .timedOut && result.outcome != .survived,
            "expected a non-timeout, non-passing outcome for a mutant that crashed promptly, got \(result.outcome): \(result.diagnosis)"
        )

        // The actual evidence: is the background child (tail -f, argv
        // contains the marker path) still alive after the whole run —
        // baseline, mutant, containment/finalization — has completed?
        // Give the OS a brief, bounded moment to finish any async teardown
        // before sampling, rather than a hard immediate check.
        try await Task.sleep(nanoseconds: 300_000_000)
        let survivors = survivingProcesses(referencing: markerPath)
        defer { for line in survivors { killSurvivor(from: line) } }

        // This is deliberately not a correctness assertion in either
        // direction — it is the evidence gate ADR-0008 §5 item 5(b) exists
        // to produce, and residue is the confirmed, expected, reproducible
        // finding (see this suite's own doc comment for the full
        // disposition) — recorded via `withKnownIssue` rather than a hard
        // failure, so this stays a standing, visible finding without
        // blocking CI on a known, already-triaged architectural gap that
        // isn't safely fixable by widening the `.timedOut` trigger.
        withKnownIssue("""
        ADR-0008 §5 item 5(b): a promptly-crashing (non-timeout) schemata mutant leaves a live descendant behind \
        (classified \(result.outcome) — see this suite's own doc comment for why `.crashed` itself turns out to be \
        unreachable here, and why widening containment's `.timedOut`-only trigger is not the safe fix). Tracked as \
        follow-up architecture work (unconditional post-primary-run descendant reaping), not a same-milestone code \
        change.
        """) {
            #expect(survivors.isEmpty, "residue: \(survivors.joined(separator: "\n"))")
        }
    }

    private func killSurvivor(from pgrepLine: String) {
        guard let pid = Int32(pgrepLine.split(separator: " ").first ?? "") else { return }
        kill(pid, SIGKILL)
    }
}
