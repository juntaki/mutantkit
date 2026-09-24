import Foundation
import Testing

/// Turns five more of an internal structural-invariants audit's 14
/// uncovered findings into permanent, mechanical gates. See
/// `V2InvariantsAuditRegressionSupport`'s own doc comment for why a
/// real-source textual re-scan is the right method: every one of these five
/// invariants is, in the audit's own words, "provable only by direct source
/// reading" — each requires a real `SimulatorPool`/leased device or a real
/// `xcodebuild` invocation to exercise behaviorally, which is exactly the
/// acceptance-suite-only territory `AGENTS.md`'s validation policy keeps
/// out of the fast unit-test loop.
@Suite("Regression: BuildDriver has no stored property capable of holding a simulator lease")
struct BuildDriverNeverLeasesRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    /// §13 (Structural Invariant 1): `BuildDriver`'s entire stored-property
    /// list is `kind`, `projectFileRelativePath`, `configuration`, `scheme`
    /// — nothing capable of holding a `SimulatorPool`/
    /// `SimulatorLeaseCoordinator`/`resolvedDestination` reference. A future
    /// editor who wanted a build to lease a device would have to add a
    /// stored property to this type first — a visible, reviewable diff to
    /// *this exact span*, not a silent behavior change buried in `build`'s
    /// own body. If a build ever held a lease for its whole (much longer
    /// than a test invocation) duration, it would starve `SimulatorPool`'s
    /// limited device pool and serialize what should be independently
    /// schedulable build/test phases.
    @Test("BuildDriver's stored-property block names no simulator/lease-related type")
    func buildDriverHasNoLeaseCapableStoredProperty() throws {
        let text = try Support.read("AppleBuildAdapters/XcodeBuildDriver.swift")
        let propertyBlock = try #require(
            Support.span(in: text, startMarker: "struct BuildDriver: Sendable {", endLinePrefix: "    func "),
            "BuildDriver's declaration or its first method moved from what this test expects"
        )
        for forbidden in ["SimulatorPool", "SimulatorLeaseCoordinator", "SimulatorLease", "resolvedDestination"] {
            #expect(
                !propertyBlock.contains(forbidden),
                """
                BuildDriver's stored-property block now mentions `\(forbidden)` — if this type genuinely gained the \
                ability to hold a lease reference, that is a real, deliberate structural change; update this test \
                (and the file's own header comment, which currently states the opposite) rather than letting it pass silently
                """
            )
        }
        #expect(propertyBlock.contains("let kind: ProjectKind"))
        #expect(propertyBlock.contains("let scheme: XcodeSchemeResolver"))
    }

    /// `build`'s own destination is a plain `String` parameter the caller
    /// computes and passes in, never a value this method resolves itself
    /// via a lease — confirms the stored-property absence above is not
    /// merely compensated for by the method acquiring one internally.
    @Test("BuildDriver.build takes its destination as a plain String parameter, never acquiring a lease itself")
    func buildTakesADestinationParameterNotALease() throws {
        let text = try Support.read("AppleBuildAdapters/XcodeBuildDriver.swift")
        let body = try #require(Support.span(in: text, startMarker: "func build(", endLinePrefix: "    func "))
        #expect(body.contains("buildDestination: String"))
        #expect(!body.contains("withLease("), "BuildDriver.build must never itself acquire a simulator lease: \(body)")
    }
}

/// §15: `preferredDevice` (per-worker device affinity, pinning a persistent
/// sandbox to the same simulator across mutants to reuse warm app state) is
/// honored only on the isolated `leaseAndRunTests` path — the schemata
/// (`runSchemataTokenAfterUninstall`) and batch (`runBatchTests`) lease call
/// sites both pass `preferredDevice: nil` explicitly. If a future refactor
/// unified the three call sites and missed this one differing argument, it
/// would either silently start reusing a specific device across a whole
/// schemata chunk/batch (never verified safe for those paths), or silently
/// drop the isolated-mode optimization.
@Suite("Regression: worker-device affinity (preferredDevice) is honored only by the isolated lease path")
struct WorkerDeviceAffinityIsolatedOnlyRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    @Test("The isolated lease call passes a real preferredDevice; the schemata and batch lease calls pass nil")
    func onlyTheIsolatedLeaseCallHonorsPreferredDevice() throws {
        let text = try Support.read("AppleBuildAdapters/XcodeBuildAdapter.swift")
        let preferredDeviceLines = text.components(separatedBy: .newlines).filter { $0.contains("preferredDevice:") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        let nonNilLines = preferredDeviceLines.filter { !$0.contains("preferredDevice: nil") }
        #expect(
            nonNilLines.count == 1,
            "expected exactly one non-nil preferredDevice: argument (the isolated lease call); found \(nonNilLines.count): \(nonNilLines)"
        )
        #expect(nonNilLines.first?.contains("workerDevicesByWorkspace?[workspace.lastPathComponent]") == true)

        let nilLines = preferredDeviceLines.filter { $0.contains("preferredDevice: nil") }
        #expect(
            nilLines.count == 2,
            "expected exactly two `preferredDevice: nil` lease calls (schemata, batch); found \(nilLines.count): \(nilLines)"
        )
    }
}

/// §16: `runTests`'s own top-level dispatch bypasses the fail-closed
/// uninstall choke point entirely for a non-simulator (e.g. macOS/generic)
/// destination — `guard destinationNeedsSimulatorLease else { return try
/// await runTestsOnDestination(...) }` calls straight through, never via
/// `runTestsAfterUninstall`/`uninstallStaleApp`. The identical shape exists
/// for `runSchemataToken`. This is intentional (a non-simulator destination
/// has no persistent per-device app install a back-to-back mutant run could
/// collide on) — but if a future change routed the non-leased path through
/// the uninstall choke point anyway, every macOS-destination run would pay
/// an unnecessary, potentially-failing `simctl uninstall` call for a
/// destination class that structurally cannot need it.
@Suite("Regression: the stale-app uninstall choke point is reachable only on the leased-simulator path")
struct UninstallOnlyOnLeasedPathRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    @Test("runTestsOnDestination (the non-leased dispatch target) never calls uninstallStaleApp")
    func nonLeasedTestDispatchNeverUninstalls() throws {
        let text = try Support.read("AppleBuildAdapters/XcodeBuildAdapter.swift")
        let body = try #require(
            Support.span(in: text, startMarker: "private func runTestsOnDestination(", endLinePrefix: "    private func "),
            "runTestsOnDestination(...) not found where this test expects it"
        )
        #expect(!body.contains("uninstallStaleApp("), "the non-leased test dispatch must never reach the uninstall choke point: \(body)")
    }

    @Test("runSchemataTokenOnDestination (the non-leased schemata dispatch target) never calls uninstallStaleApp")
    func nonLeasedSchemataDispatchNeverUninstalls() throws {
        let text = try Support.read("AppleBuildAdapters/XcodeBuildAdapter.swift")
        let body = try #require(
            Support.span(in: text, startMarker: "private func runSchemataTokenOnDestination(", endLinePrefix: "    private func "),
            "runSchemataTokenOnDestination(...) not found where this test expects it"
        )
        #expect(
            !body.contains("uninstallStaleApp("),
            "the non-leased schemata test dispatch must never reach the uninstall choke point: \(body)"
        )
    }

    /// The other half: confirms the guard really does route a
    /// non-simulator destination to these exact non-uninstalling methods,
    /// so the two tests above are pinning the branch that is actually
    /// reachable, not an unrelated always-safe function nothing calls into
    /// from `runTests`/`runSchemataToken`.
    @Test("runTests and runSchemataToken both dispatch the non-leased branch to the non-uninstalling method")
    func dispatchGuardsRouteToTheNonUninstallingMethods() throws {
        let text = try Support.read("AppleBuildAdapters/XcodeBuildAdapter.swift")

        let runTestsBody = try #require(Support.span(in: text, startMarker: "func runTests(", endLinePrefix: "    func "))
        #expect(runTestsBody.contains("guard destinationNeedsSimulatorLease else {"))
        #expect(runTestsBody.contains("return try await runTestsOnDestination("))

        let runSchemataTokenBody = try #require(
            Support.span(in: text, startMarker: "func runSchemataToken(", endLinePrefix: "    func ")
        )
        #expect(runSchemataTokenBody.contains("guard destinationNeedsSimulatorLease else {"))
        #expect(runSchemataTokenBody.contains("return try await runSchemataTokenOnDestination("))
    }
}

/// §17: two process-invocation seams coexist by design.
/// `StaleAppUninstaller`/`XcodeSchemeResolver` both spawn through the
/// injectable `processRunner: ProcessRunner` seam (so
/// `XcodeBuildAdapterUninstallFailureTests`/
/// `XcodeBuildAdapterSchemeDiscoveryRetryTests` can script deterministic
/// failures without a real process) — a seam whose own signature has no
/// `terminationGracePeriodSeconds` parameter at all.
/// `XCTestInvocationService`/`BuildDriver` both call `ProcessSupervisor.run`
/// **directly**, always passing `terminationGracePeriodSeconds:`
/// explicitly. If either of the latter two were ever switched onto the
/// injectable seam, they would lose grace-period control over a hung
/// `xcodebuild` invocation — a real behavior change, not a refactor-neutral
/// cleanup — and it would be easy to miss because both seams "just call a
/// process."
@Suite("Regression: the injectable processRunner seam and the direct ProcessSupervisor.run seam stay on their own collaborators")
struct ProcessInvocationSeamSeparationRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    @Test("The injectable ProcessRunner seam's own signature has no terminationGracePeriodSeconds parameter")
    func processRunnerSeamHasNoGracePeriodParameter() throws {
        let text = try Support.read("AppleBuildAdapters/AdapterSupport.swift")
        let signature = try #require(
            Support.span(
                in: text, startMarker: "typealias ProcessRunner = @Sendable (", untilLineEquals: ") async throws -> ProcessResult"
            ),
            "the ProcessRunner typealias's own signature moved or changed shape from what this test expects"
        )
        #expect(!signature.contains("terminationGracePeriodSeconds"))
    }

    @Test("StaleAppUninstaller and XcodeSchemeResolver spawn only through the injectable processRunner seam")
    func uninstallerAndSchemeResolverUseTheInjectableSeam() throws {
        let uninstaller = try Support.read("AppleBuildAdapters/XcodeStaleAppUninstall.swift")
        #expect(uninstaller.contains("let processRunner: ProcessRunner"))
        #expect(!uninstaller.contains("ProcessSupervisor.run("), "StaleAppUninstaller must route only through its injectable seam: \(uninstaller)")

        let schemeResolver = try Support.read("AppleBuildAdapters/XcodeSchemeResolver.swift")
        #expect(schemeResolver.contains("let processRunner: ProcessRunner"))
        #expect(
            !schemeResolver.contains("ProcessSupervisor.run("),
            "XcodeSchemeResolver must route only through its injectable seam"
        )
    }

    @Test("XCTestInvocationService and BuildDriver call ProcessSupervisor.run directly, never the injectable seam")
    func testInvocationAndBuildDriverUseTheDirectSeam() throws {
        let testInvocation = try Support.read("AppleBuildAdapters/XcodeTestInvocation.swift")
        #expect(
            !testInvocation.contains("let processRunner: ProcessRunner"),
            "XCTestInvocationService must not gain a stored injectable processRunner — it would lose grace-period control if used"
        )
        let testInvocationCalls = Support.allSpans(in: testInvocation, startMarker: "ProcessSupervisor.run(", untilLineEquals: ")")
        #expect(testInvocationCalls.count == 2, "expected exactly 2 direct ProcessSupervisor.run(...) calls in XcodeTestInvocation.swift")
        for call in testInvocationCalls {
            #expect(call.contains("terminationGracePeriodSeconds:"), "a direct ProcessSupervisor.run call lost its explicit grace period: \(call)")
        }

        let buildDriver = try Support.read("AppleBuildAdapters/XcodeBuildDriver.swift")
        #expect(!buildDriver.contains("let processRunner: ProcessRunner"))
        let buildDriverCalls = Support.allSpans(in: buildDriver, startMarker: "ProcessSupervisor.run(", untilLineEquals: ")")
        #expect(buildDriverCalls.count == 1, "expected exactly 1 direct ProcessSupervisor.run(...) call in XcodeBuildDriver.swift")
        for call in buildDriverCalls {
            #expect(call.contains("terminationGracePeriodSeconds:"), "a direct ProcessSupervisor.run call lost its explicit grace period: \(call)")
        }
    }
}

/// §18: `GateTimingRecorder` marks exist only on the schemata
/// test-invocation path — four `"token.*"` marks spread across the three
/// functions that path's own call chain actually flows through
/// (`runSchemataTokenAfterUninstall`'s `"token.uninstall"`,
/// `leaseAndRunSchemataToken`'s `"token.leaseAndRun.total"`, and
/// `runSchemataTokenOnDestination`'s `"token.xctestrunVariant"`/
/// `"token.xcresultClassify"`) — never symmetrized onto the isolated
/// (`runTestsAfterUninstall`/`leaseAndRunTests`) or batch
/// (`runBatchTests`/`runBatchOnDestination`) paths. This is timing
/// telemetry, not internal restructuring — a future "symmetrization" in
/// either direction would be a real content change to the machine-readable
/// timing surface `GateTimingRecorder` feeds, which the current code has
/// deliberately not made.
@Suite("Regression: GateTimingRecorder marks stay schemata-only in XcodeBuildAdapter")
struct GateTimingRecorderSchemataOnlyRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    @Test("The schemata token call chain carries all four documented GateTimingRecorder marks, each in its own function")
    func schemataChokePointHasAllFourMarks() throws {
        let text = try Support.read("AppleBuildAdapters/XcodeBuildAdapter.swift")

        let uninstallBody = try #require(
            Support.span(
                in: text, startMarker: "func runSchemataTokenAfterUninstall(",
                endLinePrefix: "    private func leaseAndRunSchemataToken("
            ),
            "runSchemataTokenAfterUninstall(...) not found, or its own next sibling declaration moved"
        )
        #expect(uninstallBody.contains(#"GateTimingRecorder.shared.record("token.uninstall""#))

        let leaseBody = try #require(
            Support.span(
                in: text, startMarker: "private func leaseAndRunSchemataToken(",
                endLinePrefix: "    private func runSchemataTokenOnDestination("
            ),
            "leaseAndRunSchemataToken(...) not found where this test expects it"
        )
        #expect(leaseBody.contains(#"GateTimingRecorder.shared.record("token.leaseAndRun.total""#))

        let destinationBody = try #require(
            Support.span(
                in: text, startMarker: "private func runSchemataTokenOnDestination(", endLinePrefix: "    public func readCoverage("
            ),
            "runSchemataTokenOnDestination(...) not found where this test expects it"
        )
        #expect(destinationBody.contains(#"GateTimingRecorder.shared.record("token.xctestrunVariant""#))
        #expect(destinationBody.contains(#"GateTimingRecorder.shared.record("token.xcresultClassify""#))
    }

    @Test("The isolated choke point (runTestsAfterUninstall/leaseAndRunTests) carries no GateTimingRecorder marks")
    func isolatedChokePointHasNoMarks() throws {
        let text = try Support.read("AppleBuildAdapters/XcodeBuildAdapter.swift")
        let uninstallBody = try #require(
            Support.span(in: text, startMarker: "func runTestsAfterUninstall(", endLinePrefix: "    private func leaseAndRunTests(")
        )
        #expect(!uninstallBody.contains("GateTimingRecorder"))
        let leaseBody = try #require(
            Support.span(in: text, startMarker: "private func leaseAndRunTests(", endLinePrefix: "    func uninstallStaleApp(")
        )
        #expect(!leaseBody.contains("GateTimingRecorder"))
    }

    @Test("The batch path (runBatchTests) carries no GateTimingRecorder marks")
    func batchPathHasNoMarks() throws {
        let text = try Support.read("AppleBuildAdapters/XcodeBuildAdapter.swift")
        let body = try #require(Support.span(in: text, startMarker: "private func runBatchTests(", endLinePrefix: "    private func "))
        #expect(!body.contains("GateTimingRecorder"))
    }
}
