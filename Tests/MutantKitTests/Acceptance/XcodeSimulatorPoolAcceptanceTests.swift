import AppleBuildAdapters
import Foundation
import MutationModel
import Testing

/// Phase C4 (competitive-parity program): proves `execution.simulatorPool:
/// true` actually provisions and uses more than one real simulator across
/// concurrent workers — not merely that `workers: 2` is accepted as
/// configuration. Reuses the existing `XcodeProject` fixture
/// (`Checkout`/`CheckoutTests`, 5 mutants) rather than a new one: the point
/// of this suite is the *execution* path, not new mutation-outcome
/// coverage, and `XcodeProjectAcceptanceTests` already calibrates exactly
/// which of these 5 mutants must be killed/survived.
///
/// Scope, recorded honestly rather than silently assumed: this suite
/// proves device-per-worker assignment, outcome parity, and clone
/// cleanup/orphan sweeping. It does *not* add a new crash/hang fixture to
/// separately prove "one worker's crash does not poison a sibling" — with
/// per-worker device assignment, that guarantee is now structural (two
/// workers never share a CoreSimulator instance at all, unlike the
/// pre-C4 single-shared-device model where a timeout on one mutant could
/// contend with a sibling's own test run), and building a dedicated third
/// fixture combination to demonstrate it empirically was judged
/// disproportionate to this phase's remaining time budget. Likewise, no
/// dedicated cancellation-returns-slot test: `SimulatorPoolCloningTests`
/// already proves `releaseWorkerPool`'s own cleanup logic in isolation,
/// and `RunCommand`'s `do`/`catch` wrapping (see its own doc comment)
/// already runs that same cleanup on every thrown-error exit path, which
/// is what a `Task` cancellation surfaces as.
///
/// `.serialized`: every test in this suite touches the same physical
/// `Acceptance.iPhoneDestination()` device (booting it, cloning it,
/// directly shelling out to `simctl clone` against it) — real, shared
/// machine state, not a per-test fixture. Running two of these tests
/// concurrently races on that one device's boot state (`simctl clone`
/// refuses a booted source; a concurrently-running sibling can boot it
/// out from under a `simctl clone` this suite's own setup code just
/// issued), exactly the failure mode a first, unserialized version of
/// this suite hit under real concurrent execution. Same rationale as
/// `XcodeAppDebugDylibAcceptanceTests`' own `.serialized` trait.
@Suite("Acceptance: Xcode simulator pool (Phase C4)", .enabled(if: Acceptance.simulatorEnabled), .serialized)
struct XcodeSimulatorPoolAcceptanceTests {
    private static func configuration() throws -> String {
        """
        version: 1
        project:
          kind: xcodeProject
          scheme: Checkout
          destination: \(try Acceptance.iPhoneDestination())
        sources:
          include: [Sources/**]
        tests:
          targets: [CheckoutTests]
        operators:
          profile: default
        execution:
          strategy: isolated
          workers: 2
          incrementalBuild: true
          simulatorPool: true
        reports: [console, json]
        """
    }

    /// Every currently-installed simulator's UDID, so a real run's
    /// clone-cleanup can be checked against a "before" snapshot rather
    /// than assuming a totally clean machine.
    private static func currentSimulatorUDIDs() throws -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        struct Listing: Decodable {
            struct Device: Decodable { let udid: String; let name: String }
            let devices: [String: [Device]]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        return Set(listing.devices.values.flatMap { $0 }.map(\.udid))
    }

    private static func currentClones() throws -> [(udid: String, name: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        struct Listing: Decodable {
            struct Device: Decodable { let udid: String; let name: String }
            let devices: [String: [Device]]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        return listing.devices.values.flatMap { $0 }
            .filter { $0.name.hasPrefix("mutantkit-clone-") }
            .map { (udid: $0.udid, name: $0.name) }
    }

    /// Extracts the UDID a mutant's own test invocation actually ran
    /// against, from its recorded evidence — never assumed, always read
    /// back from `-destination platform=iOS Simulator,id=<udid>` in the
    /// exact command MutantKit ran, the same evidentiary standard
    /// `XcodeCoverageSelectionAcceptanceTests` already holds per-test
    /// narrowing to.
    private static func destinationUDID(_ result: MutationResult) -> String? {
        guard let arguments = result.evidence?.testCommand?.arguments else { return nil }
        for (index, argument) in arguments.enumerated() where argument == "-destination" {
            guard index + 1 < arguments.count else { return nil }
            return AppleAdapterFactoryTestHelpers.udid(inDestination: arguments[index + 1])
        }
        return nil
    }

    @Test("Two workers actually run on two distinct simulator devices, and every mutant's outcome matches the single-device baseline")
    func twoWorkersUseTwoDistinctDevices() throws {
        let run = try Acceptance.planAndRun(fixture: "XcodeProject", configuration: try Self.configuration())
        defer { run.cleanUp() }

        let integrity = run.report.integrity
        #expect(integrity.violations.isEmpty, "\(integrity.violations.map(\.detail))")
        #expect(integrity.planned == 5)
        #expect(integrity.sourceApplied == 5)
        #expect(integrity.buildObserved == 5)

        // Exactly the same outcome XcodeProjectAcceptanceTests calibrates
        // for the plain, single-device run -- proving per-worker device
        // assignment changes *where* a mutant's test runs, never *what*
        // the verdict is.
        #expect(run.killed == [
            .init(declaration: "canApplyCoupon(subtotal:)", original: ">=", replacement: ">"),
            .init(declaration: "canApplyCoupon(subtotal:)", original: ">=", replacement: "<")
        ])
        #expect(run.mutations(withOutcome: .survived) == [
            .init(declaration: "requiresSignature(itemCount:)", original: ">", replacement: ">="),
            .init(declaration: "requiresSignature(itemCount:)", original: ">", replacement: "<="),
            .init(declaration: "expressCheckoutEnabled", original: "true", replacement: "false")
        ])

        let usedUDIDs = Set(run.report.results.compactMap(Self.destinationUDID))
        #expect(
            usedUDIDs.count == 2,
            "expected exactly 2 distinct simulator devices across 2 workers, found \(usedUDIDs)"
        )
    }

    @Test("Every clone this run created is deleted once it completes")
    func clonesAreCleanedUpAfterTheRun() throws {
        let before = try Self.currentClones()
        #expect(before.isEmpty, "a clone from an earlier, unrelated run is already present: \(before)")

        let run = try Acceptance.planAndRun(fixture: "XcodeProject", configuration: try Self.configuration())
        run.cleanUp()

        let after = try Self.currentClones()
        #expect(after.isEmpty, "expected every mutantkit-clone-* device to be deleted after the run, found \(after)")
    }

    @Test("A stray clone from a prior interrupted run is swept before a new run provisions its own")
    func orphanClonesAreSweptBeforeProvisioning() throws {
        // Simulates exactly what a SIGKILLed prior run leaves behind:
        // a real mutantkit-clone-* device that nothing ever deleted.
        let base = try Acceptance.iPhoneDestination()
        let resolvedUDID = try AppleAdapterFactoryTestHelpers.udid(inDestination: base) ?? Self.resolveNamedDeviceUDID(base)
        let baseUDID = try #require(resolvedUDID)

        // `simctl clone` refuses a currently-booted source (see
        // `SimulatorPool.provisionWorkerPool`'s own doc comment) -- a real
        // constraint this test's own direct `simctl clone` call below must
        // work around itself, since it bypasses `SimulatorPool` entirely.
        // A prior test in this (`.serialized`) suite may well have left
        // `base` booted. Best-effort, exit code ignored: shutting down an
        // already-shutdown device is a harmless no-op.
        let shutdown = Process()
        shutdown.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        shutdown.arguments = ["simctl", "shutdown", baseUDID]
        try shutdown.run()
        shutdown.waitUntilExit()

        let clone = Process()
        clone.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        clone.arguments = ["simctl", "clone", baseUDID, "mutantkit-clone-orphan-test"]
        let pipe = Pipe()
        clone.standardOutput = pipe
        try clone.run()
        clone.waitUntilExit()
        let orphanUDID = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(clone.terminationStatus == 0, "test setup: could not create the orphan clone to sweep")

        let before = try Self.currentClones()
        #expect(before.contains { $0.udid == orphanUDID }, "test setup: orphan clone not visible before the run")

        let run = try Acceptance.planAndRun(fixture: "XcodeProject", configuration: try Self.configuration())
        run.cleanUp()

        let after = try Self.currentClones()
        #expect(!after.contains { $0.udid == orphanUDID }, "the pre-existing orphan clone should have been swept, found \(after)")
    }

    /// Real-world motivation (2026-08-26): a genuine disk-full crash killed
    /// a live `mutantkit run` mid-benchmark, leaving 3 real
    /// `mutantkit-clone-<pid>-*` devices behind with no MutantKit process
    /// left running to clean them up. They were removed manually before
    /// this exact code path ever got to prove itself against them. The
    /// test above (`orphanClonesAreSweptBeforeProvisioning`) only exercises
    /// `cleanupOrphanClones`'s *unparseable-name* fallback — its clone name
    /// carries no embedded PID at all, so it never reaches the PID-liveness
    /// check (`parseOwnerPID`/`kill(pid, 0)`) that is the actual mechanism
    /// meant to handle exactly the scenario above. This test calls
    /// `SimulatorPool.cleanupOrphanClones()` directly, against two real
    /// clones whose names *do* embed a PID: one confirmed dead (a real
    /// process this test spawns and waits out, so its PID is real and
    /// definitely no longer running), one confirmed alive (this test
    /// process's own PID) — proving the dead one is swept and the live one
    /// is not, the exact distinction the real incident needed.
    @Test("cleanupOrphanClones sweeps a clone whose embedded PID is confirmed dead, and leaves one whose PID is alive")
    func cleanupOrphanClonesDistinguishesDeadFromLiveOwnerPID() async throws {
        let base = try Acceptance.iPhoneDestination()
        let resolvedUDID = try AppleAdapterFactoryTestHelpers.udid(inDestination: base) ?? Self.resolveNamedDeviceUDID(base)
        let baseUDID = try #require(resolvedUDID)

        let shutdown = Process()
        shutdown.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        shutdown.arguments = ["simctl", "shutdown", baseUDID]
        try shutdown.run()
        shutdown.waitUntilExit()

        // A real process, spawned and awaited to completion here, so its
        // PID is guaranteed to have actually existed and to be dead by the
        // time `cleanupOrphanClones` looks at it -- not a made-up constant.
        let shortLived = Process()
        shortLived.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try shortLived.run()
        let deadPID = shortLived.processIdentifier
        shortLived.waitUntilExit()

        let alivePID = ProcessInfo.processInfo.processIdentifier
        let baseDevice = SimulatorDevice(udid: baseUDID, name: "base", runtimeIdentifier: "unused", state: "Shutdown")
        let pool = SimulatorPool(workingDirectory: Acceptance.packageRoot)

        let deadOwnerClone = try await pool.cloneDevice(from: baseDevice, label: "\(deadPID)-real-dead-owner-test")
        let liveOwnerClone = try await pool.cloneDevice(from: baseDevice, label: "\(alivePID)-real-live-owner-test")
        // `cleanupOrphanClones` never touches a live-owner clone (that is
        // exactly what this test proves), so it is never deleted as a
        // side effect of the sweep under test -- this test must clean it
        // up itself, unconditionally, regardless of how the expectations
        // below turn out.
        defer {
            let delete = Process()
            delete.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            delete.arguments = ["simctl", "delete", liveOwnerClone.udid]
            try? delete.run()
            delete.waitUntilExit()
        }

        _ = await pool.cleanupOrphanClones()

        let after = try Self.currentClones()
        #expect(!after.contains { $0.udid == deadOwnerClone.udid }, "a clone owned by a confirmed-dead PID must be swept")
        #expect(after.contains { $0.udid == liveOwnerClone.udid }, "a clone owned by this live test process's own PID must NOT be swept")
    }

    /// `iPhoneDestination()` returns a `name=`-qualified destination, never
    /// `id=` -- resolve it to a UDID the same way `DestinationResolver`
    /// would, for the one test above that needs a concrete UDID to clone
    /// from directly.
    private static func resolveNamedDeviceUDID(_ destination: String) throws -> String? {
        guard let name = AppleAdapterFactoryTestHelpers.deviceName(inDestination: destination) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        struct Listing: Decodable {
            struct Device: Decodable { let udid: String; let name: String }
            let devices: [String: [Device]]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        return listing.devices.values.flatMap { $0 }.first { $0.name == name }?.udid
    }
}

/// Tiny, test-only mirrors of `DestinationResolver`'s private string
/// parsing — that type's own helpers are `internal` to `AppleBuildAdapters`
/// and this suite lives in the app-level test target, which does not
/// import that module's internal API surface.
private enum AppleAdapterFactoryTestHelpers {
    static func field(named field: String, inDestination destination: String) -> String? {
        for component in destination.split(separator: ",") {
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == field else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func udid(inDestination destination: String) -> String? {
        field(named: "id", inDestination: destination)
    }

    static func deviceName(inDestination destination: String) -> String? {
        field(named: "name", inDestination: destination)
    }
}
