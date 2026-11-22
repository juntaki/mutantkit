@testable import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// Pins `SimulatorRuntimeCatalog` and the selection built on it against
/// recorded-shape `simctl` JSON. The regression these exist for: GitHub's
/// `xcode-27-arm64` image provisions `…SimRuntime.iOS-27-2-iPhone19-4` (OS
/// 27.2) beside `…SimRuntime.iOS-27-1`, and splitting the identifier on `-`
/// read it as OS 27.2.4 — a destination no simulator has.
@Suite("Simulator runtime catalog")
struct SimulatorRuntimeCatalogTests {
    private static let p = SimctlFixtures.prefix
    private static let deviceSpecific = p + "iOS-27-2-iPhone19-4"
    private static let generic271 = p + "iOS-27-1"

    /// The CI shape from runs 42539295401 / 44541313659.
    private static func ci27() throws -> SimulatorRuntimeCatalog {
        try SimctlFixtures.catalog(
            runtimes: [.init(generic271, "27.1", "iOS"), .init(deviceSpecific, "27.2", "iOS")],
            devices: [
                generic271: [("UDID-271-A", "iPhone 17")],
                deviceSpecific: [("UDID-272-DUO", "iPhone Duo"), ("UDID-272-B", "iPhone 17")]
            ]
        )
    }

    // MARK: - RuntimeVersion

    @Test("Versions compare numerically per component, and trailing zeros do not matter")
    func versionOrdering() throws {
        #expect(try #require(RuntimeVersion("27.10")) > #require(RuntimeVersion("27.9")))
        #expect(try #require(RuntimeVersion("9.0")) < #require(RuntimeVersion("26.0")))
        #expect(try #require(RuntimeVersion("27.2")) == #require(RuntimeVersion("27.2.0")))
        #expect(try #require(RuntimeVersion("27.2.1")) > #require(RuntimeVersion("27.2")))
        #expect(RuntimeVersion("27.2.4")?.description == "27.2.4")
        for bad in ["", "abc", "27..2", "27.x", "-1", "27.2-iPhone19"] { #expect(RuntimeVersion(bad) == nil, "\(bad)") }
    }

    // MARK: - The CI regression

    @Test("iOS-27-2-iPhone19-4 beside iOS-27-1 is OS 27.2 with its device under it — never 27.2.4")
    func deviceSpecificRuntimeIsVersion272() throws {
        let catalog = try Self.ci27()
        let latest = try #require(catalog.latestRuntimes(platform: "iOS").first)
        #expect(catalog.latestRuntimes(platform: "iOS").count == 1)
        #expect(latest.identifier == Self.deviceSpecific)
        #expect(latest.version.description == "27.2")
        #expect(latest.devices.map(\.name) == ["iPhone 17", "iPhone Duo"])
        #expect(catalog.devices.allSatisfy { $0.runtimeVersion.description != "27.2.4" })
    }

    @Test("The resolver pins `iPhone Duo` to the 27.2 runtime's device by UDID")
    func resolverPicksTheDeviceSpecificRuntime() throws {
        let devices = try Self.ci27().devices
        let resolved = try DestinationResolver.resolve("platform=iOS Simulator,name=iPhone Duo", against: devices)
        #expect(resolved.device?.udid == "UDID-272-DUO")
        #expect(resolved.destinationArgument == "platform=iOS Simulator,id=UDID-272-DUO")

        let explicit = try DestinationResolver.resolve("platform=iOS Simulator,name=iPhone Duo,OS=27.2", against: devices)
        #expect(explicit.device?.udid == "UDID-272-DUO")
        // 27.2.4 is the bogus version the old parser invented; nothing has it.
        #expect(throws: DestinationResolutionError.self) {
            try DestinationResolver.resolve("platform=iOS Simulator,name=iPhone Duo,OS=27.2.4", against: devices)
        }
    }

    @Test("The detector suggests the iPhone under the 27.2 runtime, name-only")
    func detectorSuggestsLatest() throws {
        let devices = try Self.ci27().devices
        // Both runtimes have "iPhone 17"; the lexicographically first iPhone under 27.2 wins.
        #expect(XcodeConfigDetector.selectDestination(from: devices) == "platform=iOS Simulator,name=iPhone 17")
    }

    // MARK: - Unknown / future identifier shapes

    @Test("Identifier shape is irrelevant: version and platform come from the fields")
    func unknownIdentifierShapes() throws {
        let catalog = try SimctlFixtures.catalog(
            runtimes: [
                .init(Self.p + "iOS-30-0-Foo1-2", "30.0", "iOS"),
                .init("org.example.Rocket-Sim.Runtime", "31.0", "iOS"),
                .init(Self.p + "iOS-99-9", "28.0", "iOS")
            ],
            devices: [
                Self.p + "iOS-30-0-Foo1-2": [("U1", "iPhone A")],
                "org.example.Rocket-Sim.Runtime": [("U2", "iPhone B")],
                Self.p + "iOS-99-9": [("U3", "iPhone C")]
            ]
        )
        let latest = try #require(catalog.latestRuntimes(platform: "iOS").first)
        #expect(latest.identifier == "org.example.Rocket-Sim.Runtime")
        #expect(latest.version.description == "31.0")
        let thirty = try #require(RuntimeVersion("30.0"))
        #expect(catalog.runtimes(platform: "iOS", version: thirty).map(\.identifier) == [Self.p + "iOS-30-0-Foo1-2"])
        // The identifier says 99.9; the field says 28.0.
        #expect(catalog.runtimes.first { $0.identifier == Self.p + "iOS-99-9" }?.version.description == "28.0")
    }

    @Test("27.10 is newer than 27.9")
    func tenBeatsNine() throws {
        let catalog = try SimctlFixtures.catalog(
            runtimes: [.init(Self.p + "iOS-27-9", "27.9", "iOS"), .init(Self.p + "iOS-27-10", "27.10", "iOS")],
            devices: [Self.p + "iOS-27-9": [("U9", "iPhone 9")], Self.p + "iOS-27-10": [("U10", "iPhone 10")]]
        )
        #expect(catalog.latestRuntimes(platform: "iOS").first?.version.description == "27.10")
        #expect(XcodeConfigDetector.selectDestination(from: catalog.devices) == "platform=iOS Simulator,name=iPhone 10")
        let resolved = try DestinationResolver.resolve("platform=iOS Simulator,name=iPhone 10", against: catalog.devices)
        #expect(resolved.device?.udid == "U10")
    }

    // MARK: - Same version twice

    @Test("Two runtimes of one version: the smallest identifier wins, deterministically, by UDID")
    func sameVersionTwice() throws {
        let generic = Self.p + "iOS-27-2"
        let catalog = try SimctlFixtures.catalog(
            runtimes: [.init(Self.deviceSpecific, "27.2", "iOS"), .init(generic, "27.2", "iOS")],
            devices: [Self.deviceSpecific: [("U-SPECIFIC", "iPhone 17")], generic: [("U-GENERIC", "iPhone 17")]]
        )
        #expect(catalog.latestRuntimes(platform: "iOS").map(\.identifier) == [generic, Self.deviceSpecific].sorted())
        for devices in [catalog.devices, catalog.devices.reversed()] {
            let resolved = try DestinationResolver.resolve("platform=iOS Simulator,name=iPhone 17", against: Array(devices))
            #expect(resolved.device?.udid == "U-GENERIC")
            #expect(resolved.destinationArgument == "platform=iOS Simulator,id=U-GENERIC")
        }
        // A name-only suggestion would be ambiguous to xcodebuild here, so the detector pins the UDID.
        #expect(XcodeConfigDetector.selectDestination(from: catalog.devices) == "platform=iOS Simulator,id=U-GENERIC")
    }

    // MARK: - Fail closed

    @Test("A runtime with devices but no version fails closed, naming the runtime")
    func missingVersionFailsClosed() {
        let error = #expect(throws: SimulatorRuntimeCatalogError.self) {
            try SimctlFixtures.catalog(
                runtimes: [.init(Self.deviceSpecific, nil, "iOS")], devices: [Self.deviceSpecific: [("U", "iPhone")]]
            )
        }
        #expect(error == .runtimeMetadataMissing(identifier: Self.deviceSpecific, field: "version"))
        #expect(error?.description.contains(Self.deviceSpecific) == true)
    }

    @Test("An unparseable version, a missing platform, and an unlisted runtime all fail closed")
    func otherMetadataFailuresFailClosed() {
        #expect(throws: SimulatorRuntimeCatalogError.runtimeMetadataMissing(identifier: Self.generic271, field: "version")) {
            try SimctlFixtures.catalog(
                runtimes: [.init(Self.generic271, "twenty-seven", "iOS")], devices: [Self.generic271: [("U", "iPhone")]]
            )
        }
        #expect(throws: SimulatorRuntimeCatalogError.runtimeMetadataMissing(identifier: Self.generic271, field: "platform")) {
            try SimctlFixtures.catalog(runtimes: [.init(Self.generic271, "27.1", nil)], devices: [Self.generic271: [("U", "iPhone")]])
        }
    }

    @Test("Removing a device also drops it from `skipped`")
    func removingDropsSkippedEntries() throws {
        let catalog = try SimctlFixtures.catalog(
            runtimes: [.init(Self.generic271, "27.1", "iOS")],
            devices: [Self.generic271: [("U-OK", "iPhone 17")], Self.deviceSpecific: [("U-GONE", "iPhone Duo")]]
        )
        #expect(catalog.skipped.map(\.udid) == ["U-GONE"])
        let pruned = catalog.removing(udid: "U-GONE")
        #expect(pruned.skipped.isEmpty)
        #expect(pruned.devices.map(\.udid) == ["U-OK"])
    }

    @Test("A device under a runtime missing from `list runtimes` is skipped with a reason, not fatal")
    func unlistedRuntimeIsSkipped() throws {
        let catalog = try SimctlFixtures.catalog(
            runtimes: [.init(Self.generic271, "27.1", "iOS")],
            devices: [Self.generic271: [("U-OK", "iPhone 17")], Self.deviceSpecific: [("U-GONE", "iPhone Duo")]]
        )
        #expect(catalog.devices.map(\.udid) == ["U-OK"])
        #expect(catalog.skipped.map(\.udid) == ["U-GONE"])
        #expect(catalog.skipped.first?.reason.contains(Self.deviceSpecific) == true)

        // An unrelated device still resolves...
        let ok = try DestinationResolver.resolve("platform=iOS Simulator,id=U-OK", against: catalog.devices, skipped: catalog.skipped)
        #expect(ok.device?.udid == "U-OK")
        // ...and only asking for a skipped one fails, naming why.
        for requested in ["platform=iOS Simulator,id=U-GONE", "platform=iOS Simulator,name=iPhone Duo"] {
            let error = #expect(throws: DestinationResolutionError.self) {
                try DestinationResolver.resolve(requested, against: catalog.devices, skipped: catalog.skipped)
            }
            #expect(error?.description.contains("not in `simctl list runtimes --json`") == true, "\(requested)")
        }
    }

    @Test("A runtime without available devices needs no metadata and is omitted")
    func emptyRuntimeIsIgnored() throws {
        let catalog = try SimctlFixtures.catalog(
            runtimes: [.init(Self.deviceSpecific, nil, nil), .init(Self.generic271, "27.1", "iOS")],
            devices: [Self.deviceSpecific: [], Self.generic271: [("U", "iPhone")]]
        )
        #expect(catalog.runtimes.map(\.identifier) == [Self.generic271])
    }

    @Test("Unreadable JSON is reported, not guessed around")
    func unreadableJSON() {
        #expect(throws: SimulatorRuntimeCatalogError.self) {
            try SimulatorRuntimeCatalog.build(runtimesJSON: Data("nope".utf8), devicesJSON: Data("{\"devices\":{}}".utf8))
        }
    }

    // MARK: - Platform from the platform field

    @Test("tvOS, watchOS and xrOS/visionOS classify by the platform field, not the identifier")
    func platformsComeFromTheField() throws {
        let catalog = try SimctlFixtures.catalog(
            runtimes: [
                .init(Self.p + "tvOS-18-0", "18.0", "tvOS"), .init(Self.p + "watchOS-11-0", "11.0", "watchOS"),
                .init(Self.p + "xrOS-2-0", "2.0", "xrOS"), .init(Self.p + "visionOS-26-0", "26.0", "visionOS"),
                // The identifier claims iOS; the field says tvOS — the field wins.
                .init(Self.p + "iOS-18-0", "18.0", "tvOS")
            ],
            devices: [
                Self.p + "tvOS-18-0": [("T1", "Apple TV")], Self.p + "watchOS-11-0": [("W1", "Apple Watch")],
                Self.p + "xrOS-2-0": [("X1", "Vision Pro")], Self.p + "visionOS-26-0": [("X2", "Vision Pro 2")],
                Self.p + "iOS-18-0": [("T2", "Apple TV 4K")]
            ]
        )
        let byUDID = Dictionary(uniqueKeysWithValues: catalog.devices.map { ($0.udid, $0) })
        #expect(byUDID["T1"]?.destination == "platform=tvOS Simulator,id=T1")
        #expect(byUDID["W1"]?.destination == "platform=watchOS Simulator,id=W1")
        #expect(byUDID["X1"]?.destination == "platform=visionOS Simulator,id=X1")
        #expect(byUDID["X2"]?.platform == "visionOS")
        #expect(byUDID["T2"]?.platform == "tvOS")
        #expect(catalog.devices.filter { $0.platform == "iOS" }.isEmpty)
        #expect(XcodeConfigDetector.selectDestination(from: catalog.devices) == nil)
    }

    @Test("`latest` is scoped to the requested platform")
    func latestIsPerPlatform() throws {
        let catalog = try SimctlFixtures.catalog(
            runtimes: [.init(Self.p + "iOS-18-0", "18.0", "iOS"), .init(Self.p + "tvOS-26-0", "26.0", "tvOS")],
            devices: [Self.p + "iOS-18-0": [("I", "Same Name")], Self.p + "tvOS-26-0": [("T", "Same Name")]]
        )
        let ios = try DestinationResolver.resolve("platform=iOS Simulator,name=Same Name", against: catalog.devices)
        #expect(ios.device?.udid == "I")
        let tv = try DestinationResolver.resolve("platform=tvOS Simulator,name=Same Name", against: catalog.devices)
        #expect(tv.device?.udid == "T")
    }

    // MARK: - The pool loads the catalog from both listings

    @Test("SimulatorPool joins `list runtimes` and `list devices available`, and fails closed on a missing version")
    func poolLoadsCatalog() async throws {
        func pool(runtimes: String) -> SimulatorPool {
            let devices = SimctlFixtures.devicesJSON([Self.deviceSpecific: [("UDID-272-DUO", "iPhone Duo")]])
            return SimulatorPool(workingDirectory: FileManager.default.temporaryDirectory, processRunner: { _, arguments, _, _ in
                ProcessResult(
                    exitCode: 0, standardOutput: Data((arguments.contains("runtimes") ? runtimes : devices).utf8), standardError: Data(),
                    durationSeconds: 0.01, timedOut: false, terminatingSignal: nil, outputComplete: true
                )
            })
        }
        let good = pool(runtimes: SimctlFixtures.runtimesJSON([.init(Self.deviceSpecific, "27.2", "iOS")]))
        let device = try #require(try await good.catalogDevices().first)
        #expect(device.runtimeVersion.description == "27.2")
        #expect(device.destination == "platform=iOS Simulator,id=UDID-272-DUO")
        #expect(try await good.lease(udid: "UDID-272-DUO").destination == "platform=iOS Simulator,id=UDID-272-DUO")
        #expect(try await good.runtimeCatalog().runtimes.count == 1)

        let bad = pool(runtimes: SimctlFixtures.runtimesJSON([.init(Self.deviceSpecific, nil, "iOS")]))
        await #expect(throws: SimulatorPoolError.self) { try await bad.availableDevices() }
    }

    // MARK: - Pool: one source of truth, deletion, clone failure

    @Test("After deleting a clone, availableDevices and runtimeCatalog agree")
    func deletionUpdatesBothViews() async throws {
        let deleted = DeleteFlag()
        let pool = SimulatorPool(workingDirectory: FileManager.default.temporaryDirectory, processRunner: { _, arguments, _, _ in
            let body: String
            if arguments.contains("runtimes") {
                body = SimctlFixtures.runtimesJSON([.init(Self.generic271, "27.1", "iOS")])
            } else if arguments.contains("list") {
                body = SimctlFixtures.devicesJSON([Self.generic271: [("U-BASE", "iPhone 17"), ("U-CLONE", "clone")]])
            } else { body = ""; deleted.set() }
            return ProcessResult(
                exitCode: 0, standardOutput: Data(body.utf8), standardError: Data(),
                durationSeconds: 0.01, timedOut: false, terminatingSignal: nil, outputComplete: true
            )
        })
        _ = try await pool.availableDevices()
        try await pool.deleteDevice(udid: "U-CLONE")
        #expect(deleted.value)
        #expect(try await pool.availableDevices().map(\.udid) == ["U-BASE"])
        #expect(try await pool.runtimeCatalog().devices.map(\.udid) == ["U-BASE"])
        #expect(try await pool.catalogDevices().map(\.udid) == ["U-BASE"])
        await #expect(throws: SimulatorPoolError.self) { try await pool.lease(udid: "U-CLONE") }
    }

    private final class DeleteFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}
