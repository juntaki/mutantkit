@testable import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// An `application` target, not a framework — built with `xcodebuild` and
/// tested on a simulator, same as `XcodeProjectAcceptanceTests`.
///
/// This is the fixture that reproduces the most consequential activation-
/// evidence bug found so far: on a real iOS app project, every single mutant —
/// across four files, two targets — reported `mutationNotActivated`, because
/// recent Xcode toolchains build a Debug/simulator `application` target's own
/// code into a loose `<Target>.debug.dylib` sitting inside the `.app`,
/// leaving a near-empty host executable behind. `TestProductHasher` had no
/// entry for a loose file, so the mutated code was invisible to the scan.
/// `XcodeProjectAcceptanceTests` never caught this because its fixture is a
/// `framework` target, which this toolchain does not build the same way —
/// confirmed empirically, not assumed. Existing unit coverage
/// (`TestProductHasherTests`) exercises the fix with hand-built directories;
/// this suite drives it with a real `xcodebuild` instead.
///
/// This fixture also turned up a second, unrelated bug: back-to-back mutants
/// sharing one leased simulator device occasionally produced a verdict that
/// matched neither binary — once a mutation on dead code (`requiresConfirmation`,
/// which nothing calls) came back `killedByAssertion`, once a mutation the test
/// asserts against directly (`isInStock`) came back `survived`. Both are
/// provably impossible outcomes, confirmed by rebuilding the exact mutant
/// sandbox by hand outside the worker pool and getting the correct verdict every
/// time. Root-caused to two compounding issues in `XcodeBuildAdapter`, both now
/// fixed there: `test-without-building`'s default sysdiagnose collection on
/// failure racing mutantkit's own timeout (`-collect-test-diagnostics never`), and
/// CoreSimulator occasionally serving a stale install from the mutant tested
/// moments before on the same leased device (`uninstallStaleApp`). Confirmed by
/// disabling only the uninstall step and reproducing the exact same impossible
/// verdict on the next run; three runs with both fixes active agreed with
/// ground truth. This suite's own killed/survived assertion below is the
/// regression test for that fix — no `retestKilledMutants` safety net here, so
/// a regression shows up directly rather than being retried away.
/// `.serialized`: two of these tests drive their own independent `xcodebuild`
/// invocations rather than reading the shared run, and Swift Testing runs a
/// suite's tests concurrently by default — which would spawn several real
/// `xcodebuild` processes against one simulator at once purely as an artifact
/// of how this suite is written, not anything under test. That is exactly the
/// resource-contention shape the fixture's own findings are about; a test
/// suite that reintroduced it while proving it fixed would be self-defeating.
@Suite(
    "Acceptance: Xcode application target (Debug Dylib)",
    .enabled(if: Acceptance.simulatorEnabled),
    .serialized
)
struct XcodeAppDebugDylibAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeProject
          scheme: DebugDylibDemo
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [DebugDylibDemoTests]
        operators:
          profile: default
        execution:
          strategy: isolated
          workers: 2
        reports: [console, json]
        """
    }

    private static let sharedRun = Result {
        try Acceptance.planAndRun(fixture: "XcodeAppDebugDylib", configuration: configuration())
    }

    private func run() throws -> AcceptanceRun {
        try Self.sharedRun.get()
    }

    /// Confirms the scenario this suite exists to test is real on this
    /// machine's toolchain, not something the suite merely believes about the
    /// build system. A future Xcode that stops building this way would make
    /// every other assertion in this suite pass for the wrong reason —
    /// because there would be nothing left to catch.
    @Test("This toolchain really does build the target as a loose debug dylib")
    func debugDylibIsReallyProduced() throws {
        let directory = try Acceptance.stageFixture("XcodeAppDebugDylib")
        defer { try? FileManager.default.removeItem(at: directory) }

        let products = try Self.build(in: directory)
        let enumerator = FileManager.default.enumerator(at: products, includingPropertiesForKeys: nil)
        let debugDylibs = enumerator?.allObjects
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "dylib" && $0.lastPathComponent.hasSuffix(".debug.dylib") }
            ?? []
        #expect(!debugDylibs.isEmpty, "expected a loose <Target>.debug.dylib somewhere under \(products.path)")
    }

    /// "Hash differs → activated" only means something if "hash differs" never
    /// happens on its own. Three independent `xcodebuild` invocations of the
    /// identical, unmutated fixture — bypassing mutantkit's own sandboxing
    /// entirely — hashed with the real `TestProductHasher`, the same one
    /// activation evidence depends on. This is the highest-risk case for
    /// nondeterminism in the whole suite: a Debug Dylib build carries more
    /// toolchain-embedded state (a loose dylib beside the stub, a separate
    /// `__preview.dylib`) than the framework fixture `MachOCodeHash`'s
    /// existing repeatability claim was checked against.
    @Test("The real product hash is repeatable across three independent builds")
    func productHashIsRepeatableAcrossIndependentBuilds() throws {
        let hashes = try (0 ..< 3).map { _ -> String in
            let directory = try Acceptance.stageFixture("XcodeAppDebugDylib")
            defer { try? FileManager.default.removeItem(at: directory) }

            let products = try Self.build(in: directory)
            return try #require(
                TestProductHasher.hash(productsDirectory: products),
                "no test product found under \(products.path)"
            )
        }
        #expect(Set(hashes).count == 1, "\(hashes)")
    }

    /// Builds the fixture directly with `xcodebuild`, bypassing mutantkit
    /// entirely, and returns the products directory. Shared by the tests that
    /// need to inspect real build output rather than a `mutantkit run` report.
    @discardableResult
    private static func build(in directory: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            "-project", "DebugDylibDemo.xcodeproj",
            "-scheme", "DebugDylibDemo",
            "-destination", try Acceptance.iPhoneDestination(),
            "-derivedDataPath", "dd",
            "build-for-testing"
        ]
        process.currentDirectoryURL = directory
        // A single shared pipe, drained before waiting rather than after: a
        // separate pipe per stream that's never read deadlocks the moment
        // `build-for-testing`'s output — routinely well past 64KB — fills
        // either one, since the child blocks on a full pipe nobody drains and
        // `waitUntilExit()` then waits for an exit that can never come.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        return directory.appendingPathComponent("dd/Build/Products")
    }

    @Test("The run reconciles and produces a score")
    func runIsInternallyConsistent() throws {
        let run = try self.run()

        #expect(run.report.baseline.passed)
        #expect(run.report.baseline.testSummary?.total == 1)

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        #expect(integrity.planned == 4)
        #expect(integrity.sourceApplied == 4)
        #expect(integrity.buildObserved == 4)
        #expect(run.report.score != nil)
    }

    @Test("Exactly the uncovered mutations survive")
    func survivorsAreExactlyTheUncoveredOnes() throws {
        let run = try self.run()

        #expect(run.killed == [
            .init(declaration: "isInStock(count:)", original: ">=", replacement: ">"),
            .init(declaration: "isInStock(count:)", original: ">=", replacement: "<")
        ])
        #expect(run.mutations(withOutcome: .survived) == [
            .init(declaration: "requiresConfirmation(itemCount:)", original: ">", replacement: ">="),
            .init(declaration: "requiresConfirmation(itemCount:)", original: ">", replacement: "<=")
        ])
    }

    /// The product's central promise, and the one this fixture exists to
    /// prove against a real Debug Dylib build rather than a synthetic one.
    @Test("Every scored mutant is proven active in the build product")
    func everyScoredMutantIsProvenActive() throws {
        let run = try self.run()

        for result in run.report.results where result.outcome.isScorable {
            let activation = try #require(
                result.evidence?.applicationEvidence?.isolatedActivation,
                "\(result.point.displayLocation) was scored without activation evidence"
            )
            #expect(activation.provesActivation, "\(result.point.displayLocation)")
        }
    }
}
