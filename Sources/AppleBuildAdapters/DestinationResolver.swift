import Foundation
import MutationModel

/// One `-destination` specifier, resolved to a concrete device (or proven to
/// need none), once, at run start.
///
/// A configured `platform=iOS Simulator,name=X` with no explicit OS is not a
/// destination — it is a *question* xcodebuild answers fresh on every single
/// invocation, against whatever it currently considers `OS:latest`. Found the
/// hard way: a machine that had accumulated devices under more than one
/// simulator runtime silently resolved that question differently than
/// expected, and every build/test call in the run repeated the guess rather
/// than sharing one answer. This type is that one answer, computed before the
/// run's first build and reused — unchanged — for every build, test,
/// `reproduce`, and eventually `replay` afterward.
public struct ResolvedDestination: Codable, Sendable, Hashable {
    /// The destination exactly as configured, before resolution — kept so
    /// evidence can show what was asked for alongside what it resolved to.
    public let requested: String
    /// The concrete simulator this resolved to. `nil` for a destination with
    /// no device to resolve — `platform=macOS`, a physical device, or a
    /// generic placeholder (`generic/platform=iOS`) that a caller must still
    /// pick a real device for at test time.
    public let device: SimulatorDevice?

    /// The runtime `platform` (`iOS`, `tvOS`, …) of the selected device, from the
    /// catalog at resolve time. `nil` only for a record written before this field
    /// existed (an older run manifest) — `DestinationResolver.completingForReplay`
    /// fills it from the live catalog before such a record is used.
    public let platform: String?

    public init(requested: String, device: SimulatorDevice?, platform: String? = nil) {
        self.requested = requested
        self.device = device
        self.platform = platform
    }

    /// The `-destination` argument to actually pass to `xcodebuild`: the
    /// resolved device by UDID when there is one, the original specifier
    /// otherwise.
    ///
    /// The `platform=` label comes from the selected device's own runtime
    /// platform, never from the user's `requested` string — so a stale
    /// `platform=tvOS Simulator,id=<iOS device>` and a correct
    /// `platform=iOS Simulator,id=<same>` yield one argument and therefore one
    /// run-lock key, exactly as on main.
    public var destinationArgument: String {
        guard let device else { return requested }
        guard let platform else { return "id=\(device.udid)" }
        return "platform=\(SimulatorRuntimeCatalog.destinationPlatform(forPlatform: platform)),id=\(device.udid)"
    }
}

public enum DestinationResolutionError: Error, CustomStringConvertible, Sendable {
    /// A named device exists, but not under the runtime an unqualified
    /// destination would implicitly resolve to (`OS:latest` — the highest
    /// version among *all* installed runtimes, not just this name's
    /// matches). Refusing to pick a different runtime silently is the whole
    /// point: `xcodebuild` given the same ambiguous name would have failed
    /// with a much less actionable "no device matches" once builds were
    /// already underway, or worse, `SimulatorPool`'s own name-substring
    /// matching would have picked whichever runtime happened to sort first
    /// — the *older* one, on a plain lexicographic comparison of runtime
    /// identifiers.
    case ambiguousAcrossRuntimes(name: String, expectedRuntime: String, foundUnder: [String])
    /// No device with this name exists under any installed runtime at all.
    case notFound(name: String, knownNames: [String])
    /// Same condition as `notFound`, but the name came from the built-in
    /// default literal because no `project.destination` is configured.
    case defaultDestinationNotFound(name: String, knownNames: [String])
    /// A destination already pinned to `id=<udid>` names a UDID nothing on
    /// this machine has.
    case unknownUDID(String)
    case simulatorPoolFailure(String)
    /// A replayed run recorded a simulator that this machine no longer has.
    case recordedDeviceMissing(String)
    /// The requested device was listed by `simctl`, but under a runtime
    /// `list runtimes` does not report, so it cannot be used or classified.
    case deviceSkipped(String)
    /// The requested device exists, but the scheme's available destinations
    /// (`xcodebuild -showdestinations`) do not include it — or any device the
    /// request names. There is no silent fallback to a device the scheme
    /// cannot use.
    case notSupportedByScheme(scheme: String, requested: String, supported: [String], unsupported: [String])

    public var description: String {
        switch self {
        case let .ambiguousAcrossRuntimes(name, expectedRuntime, foundUnder):
            """
            Destination device "\(name)" was requested with no explicit OS, which resolves to \
            the latest installed runtime (\(expectedRuntime)) — but "\(name)" exists only under: \
            \(foundUnder.joined(separator: ", ")). Refusing to silently run against a different \
            runtime than an unqualified "latest" implies. Create a "\(name)" simulator under \
            \(expectedRuntime) (Xcode > Settings > Platforms, or `xcrun simctl create`), or name \
            an explicit OS in the destination (e.g. \
            "platform=iOS Simulator,name=\(name),OS=<version>").
            """
        case let .notFound(name, knownNames):
            """
            No simulator named "\(name)" is available. Known device names: \
            \(knownNames.isEmpty ? "(none)" : knownNames.joined(separator: ", ")).
            """
        case let .defaultDestinationNotFound(name, knownNames):
            """
            No `project.destination` is configured, and the built-in default "\(name)" does not \
            exist on this machine. Run `mutantkit setup` (or `mutantkit init`) to pick an installed \
            simulator, or set `project.destination` in mutantkit.yml. Known device names: \
            \(knownNames.isEmpty ? "(none)" : knownNames.joined(separator: ", ")).
            """
        case let .unknownUDID(udid):
            "No simulator with UDID \(udid) is available on this machine."
        case let .recordedDeviceMissing(udid):
            """
            The recorded run used simulator \(udid), which is not available on this machine, so its \
            exact conditions cannot be replayed. Use --run to build and test against the current \
            environment instead.
            """
        case let .deviceSkipped(detail):
            "The requested simulator cannot be used: \(detail)"
        case let .notSupportedByScheme(scheme, requested, supported, unsupported):
            if supported.isEmpty {
                """
                Scheme "\(scheme)" cannot run on the requested destination "\(requested)": none of \
                its matching simulators (\(unsupported.joined(separator: ", "))) is among the \
                scheme's available destinations (`xcodebuild -showdestinations -scheme "\(scheme)"`). \
                Choose a destination the scheme lists, or install the runtime it needs.
                """
            } else {
                """
                Scheme "\(scheme)" supports \(supported.joined(separator: ", ")) but not the \
                simulator "\(requested)" asks for (not supported: \(unsupported.joined(separator: ", "))). \
                Name one of the supported simulators, or an OS the scheme lists.
                """
            }
        case let .simulatorPoolFailure(detail):
            "Could not resolve the destination: \(detail)"
        }
    }
}

/// Resolves a configured `-destination` specifier to one concrete simulator.
///
/// Called exactly once per run, before the baseline build — see
/// `RunCommand`. Every build, test, and reproduce/replay invocation for that
/// run then uses the same `ResolvedDestination`, so "which runtime did this
/// run actually use" has one answer, not one answer per xcodebuild
/// invocation that happened to agree by luck.
public enum DestinationResolver {
    /// Every `platform=` value `xcodebuild -destination` accepts that names a
    /// simulator, as opposed to macOS or a physical device, paired with the
    /// runtime `platform` field (`simctl list runtimes --json`) it corresponds
    /// to. A destination naming any of these gets this type's name/UDID
    /// pinning, so the "OS:latest resolves differently per invocation" bug is
    /// closed for every simulator platform, not just iOS.
    static let simulatorPlatforms: [(name: String, platform: String)] = [
        ("iOS Simulator", "iOS"),
        ("tvOS Simulator", "tvOS"),
        ("watchOS Simulator", "watchOS"),
        ("visionOS Simulator", "visionOS")
    ]

    /// Module-internal, not `private`: `XcodeBuildAdapter
    /// .destinationNeedsSimulatorLease` reuses this exact check rather than
    /// keeping its own separate `"iOS Simulator"`-only test — that
    /// duplicate had the identical bug this one did, and fixing one without
    /// the other would have left tvOS/watchOS/visionOS destinations
    /// resolved correctly but leased not at all, letting two concurrent
    /// workers collide on one real device.
    static func isSimulatorDestination(_ requested: String) -> Bool {
        simulatorPlatforms.contains { requested.localizedCaseInsensitiveContains($0.name) }
    }

    /// The runtime platform for the destination `requested` names (`nil` for
    /// a non-simulator destination) — used to scope "latest installed
    /// runtime" to runtimes of the *same platform* as what was requested.
    ///
    /// Read from the destination's own `platform=` field, not by searching the
    /// whole string: `platform=watchOS Simulator,name=iOS Simulator Lab` is a
    /// watchOS destination whatever the device is called.
    private static func runtimePlatform(forRequestedDestination requested: String) -> String? {
        guard let value = field(named: "platform", inDestination: requested) else { return nil }
        return simulatorPlatforms.first { $0.name.caseInsensitiveCompare(value) == .orderedSame }?.platform
    }

    /// Resolves against a live pool — the production entry point. Devices
    /// are only listed (an actual `simctl` call) when `requested` actually
    /// names a simulator; a macOS or physical-device destination never
    /// touches `simctl` at all.
    public static func resolve(
        _ requested: String,
        using pool: SimulatorPool,
        schemeDestinations: SchemeDestinations? = nil,
        isBuiltInDefault: Bool = false
    ) async throws -> ResolvedDestination {
        guard isSimulatorDestination(requested) else {
            return ResolvedDestination(requested: requested, device: nil)
        }

        let catalog: SimulatorRuntimeCatalog
        do {
            catalog = try await pool.runtimeCatalog()
        } catch let error as SimulatorPoolError {
            throw DestinationResolutionError.simulatorPoolFailure(error.description)
        }

        return try resolve(
            requested, against: catalog.devices, skipped: catalog.skipped,
            schemeDestinations: schemeDestinations, isBuiltInDefault: isBuiltInDefault
        )
    }

    /// Completes a record decoded from a run manifest for replay. The recorded
    /// UDID is always looked up in the live catalog — fails closed if the device
    /// is gone or the catalog cannot be read, for a record of either format —
    /// and the `platform` is filled from it only when the record has none
    /// (a main-format manifest).
    public static func completingForReplay(
        _ recorded: ResolvedDestination,
        using pool: SimulatorPool
    ) async throws -> ResolvedDestination {
        guard let device = recorded.device else { return recorded }
        let catalog: SimulatorRuntimeCatalog
        do {
            catalog = try await pool.runtimeCatalog()
        } catch let error as SimulatorPoolError {
            throw DestinationResolutionError.simulatorPoolFailure(error.description)
        }
        guard let live = catalog.devices.first(where: { $0.udid == device.udid }) else {
            throw DestinationResolutionError.recordedDeviceMissing(device.udid)
        }
        return ResolvedDestination(requested: recorded.requested, device: device, platform: recorded.platform ?? live.platform)
    }

    /// The pure decision, given the device list already in hand — separated
    /// from `resolve(_:using:)` so the ambiguity/not-found/latest-runtime
    /// logic can be pinned in a unit test without any of them needing a real
    /// simulator or a `simctl` call to do it.
    static func resolve(
        _ requested: String,
        against devices: [CatalogDevice],
        skipped: [SkippedDevice] = [],
        schemeDestinations: SchemeDestinations? = nil,
        isBuiltInDefault: Bool = false
    ) throws -> ResolvedDestination {
        guard isSimulatorDestination(requested) else {
            // macOS, a physical device, or something this tool does not
            // model: nothing to pin, and nothing to be ambiguous about.
            return ResolvedDestination(requested: requested, device: nil)
        }

        if let udid = udid(inDestination: requested) {
            guard let match = devices.first(where: { $0.udid == udid }) else {
                if let skippedDevice = skipped.first(where: { $0.udid == udid }) {
                    throw DestinationResolutionError.deviceSkipped("\(udid) (\(skippedDevice.name)): \(skippedDevice.reason)")
                }
                throw DestinationResolutionError.unknownUDID(udid)
            }
            try requireSchemeSupport(of: [match], requested: requested, scheme: schemeDestinations)
            return ResolvedDestination(requested: requested, device: match.device, platform: match.platform)
        }

        guard let name = Self.deviceName(inDestination: requested) else {
            // A simulator destination with neither `id=` nor `name=` — e.g.
            // the generic placeholder. Nothing this run can pin ahead of
            // time; the existing name-hint leasing path handles it as before.
            return ResolvedDestination(requested: requested, device: nil)
        }

        let matches = devices.filter { $0.name == name }
        guard !matches.isEmpty else {
            if let skippedDevice = skipped.first(where: { $0.name == name }) {
                throw DestinationResolutionError.deviceSkipped(
                    "\"\(name)\" (\(skippedDevice.udid)): \(skippedDevice.reason)"
                )
            }
            let knownNames = Array(Set(devices.map(\.name))).sorted()
            if isBuiltInDefault {
                throw DestinationResolutionError.defaultDestinationNotFound(name: name, knownNames: knownNames)
            }
            throw DestinationResolutionError.notFound(name: name, knownNames: knownNames)
        }

        // Only devices the scheme can use are candidates: the newest runtime and
        // the same-version tie are both decided among them. A request that
        // resolves on the full catalog but not on the usable devices fails as
        // "not supported by the scheme", never as a misleading not-found.
        guard let scheme = schemeDestinations else {
            return try select(name: name, requested: requested, from: devices, matches: matches)
        }
        try requireSchemeSupport(of: matches, requested: requested, scheme: scheme)
        do {
            return try select(
                name: name, requested: requested,
                from: devices.filter { scheme.supports(udid: $0.udid) }, matches: matches
            )
        } catch let error as DestinationResolutionError {
            guard (try? select(name: name, requested: requested, from: devices, matches: matches)) != nil else { throw error }
            throw DestinationResolutionError.notSupportedByScheme(
                scheme: scheme.scheme, requested: requested,
                supported: matches.filter { scheme.supports(udid: $0.udid) }.map(Self.describe).sorted(),
                unsupported: matches.filter { !scheme.supports(udid: $0.udid) }.map(Self.describe).sorted()
            )
        }
    }

    /// The device `name` resolves to among `devices`; `matches` are all devices
    /// of that name (for diagnostics).
    private static func select(
        name: String, requested: String, from devices: [CatalogDevice], matches: [CatalogDevice]
    ) throws -> ResolvedDestination {
        let platform = Self.runtimePlatform(forRequestedDestination: requested)
        let platformDevices = platform.map { platform in devices.filter { $0.platform == platform } } ?? devices

        if let explicitOS = Self.explicitOS(inDestination: requested) {
            // Compared as numeric versions against each runtime's own
            // `version` field: `OS=27.2` matches version 27.2 whatever the
            // runtime's identifier looks like. The configured value is user
            // input, and older configs spell it with hyphens (`OS=26-3-1`), so
            // `-` is read as `.` here — config parsing, not identifier parsing.
            // Equality is exact and numeric: `26.3` equals `26.3.0` but no
            // longer matches 26.3.1 (it used to, as a substring of the identifier).
            let wanted = RuntimeVersion(explicitOS.replacingOccurrences(of: "-", with: "."))
            let sameVersion = platformDevices.filter { $0.runtimeVersion == wanted }
            guard let match = Self.pick(named: name, from: sameVersion) else {
                throw DestinationResolutionError.notFound(
                    name: "\(name) (OS \(explicitOS))",
                    knownNames: matches.map { "\($0.name) (OS \($0.runtimeVersion), \($0.runtimeIdentifier))" }
                )
            }
            return ResolvedDestination(requested: requested, device: match.device, platform: match.platform)
        }

        // No explicit OS: this is exactly the implicit `OS:latest` case.
        // "Latest" is the highest-version runtime of the requested platform
        // installed on the machine at all — not just among this name's
        // matches — because that is what xcodebuild's own unqualified
        // resolution means. Several runtimes can share that version (a
        // generic 27.2 beside a device-specific one); the name is then
        // looked up under all of them, ties broken by `pick`.
        guard let latest = platformDevices.map(\.runtimeVersion).max() else {
            throw DestinationResolutionError.notFound(name: name, knownNames: [])
        }
        guard let match = Self.pick(named: name, from: platformDevices.filter { $0.runtimeVersion == latest }) else {
            throw DestinationResolutionError.ambiguousAcrossRuntimes(
                name: name,
                expectedRuntime: "\(platform ?? "simulator") \(latest)",
                foundUnder: Array(Set(matches.map { "\($0.runtimeIdentifier) (OS \($0.runtimeVersion))" })).sorted()
            )
        }
        return ResolvedDestination(requested: requested, device: match.device, platform: match.platform)
    }

    /// Fails when a scheme's destinations are known and none of `candidates`
    /// (the devices the request names) is among them.
    private static func requireSchemeSupport(
        of candidates: [CatalogDevice], requested: String, scheme: SchemeDestinations?
    ) throws {
        guard let scheme, !candidates.contains(where: { scheme.supports(udid: $0.udid) }) else { return }
        throw DestinationResolutionError.notSupportedByScheme(
            scheme: scheme.scheme, requested: requested,
            supported: [], unsupported: candidates.map(Self.describe).sorted()
        )
    }

    private static func describe(_ device: CatalogDevice) -> String {
        "\(device.name) \(device.udid) (\(device.runtimeIdentifier))"
    }

    /// The device named `name` among `candidates` (all one platform and version).
    /// When more than one runtime of that version has such a device, the one under
    /// the smallest runtime identifier wins — an arbitrary but stable tiebreak,
    /// since identifiers are opaque. The result is addressed by UDID
    /// (`ResolvedDestination.destinationArgument`), so `xcodebuild` never has to
    /// resolve the duplicate name itself.
    private static func pick(named name: String, from candidates: [CatalogDevice]) -> CatalogDevice? {
        candidates.filter { $0.name == name }
            .min { ($0.runtimeIdentifier, $0.udid) < ($1.runtimeIdentifier, $1.udid) }
    }

    // MARK: - Destination string parsing

    /// `public`, not just module-internal: `ToolchainProbe` (in the `CLI`
    /// module) reuses this exact, already-tested destination-string parser
    /// to determine which SDK a run actually built against, rather than
    /// duplicating the same `key=value` splitting logic a second time.
    public static func field(named field: String, inDestination destination: String) -> String? {
        for component in destination.split(separator: ",") {
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == field else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func deviceName(inDestination destination: String) -> String? {
        field(named: "name", inDestination: destination)
    }

    static func udid(inDestination destination: String) -> String? {
        field(named: "id", inDestination: destination)
    }

    static func explicitOS(inDestination destination: String) -> String? {
        guard let value = field(named: "OS", inDestination: destination), value != "latest" else { return nil }
        return value
    }

    /// The destination guessed for an `xcodebuild`-based kind with no
    /// configured `project.destination` at all — the same default
    /// `ProjectDetectionPlan.defaultDestination(for:)` already uses when
    /// `init`/`setup` write a fresh `mutantkit.yml`. Kept as one function
    /// both `XcodeBuildAdapter.destination()` and `AppleAdapterFactory
    /// .resolveDestinationIfNeeded` call, after a real-project inconsistency
    /// (`doctor` run with no `mutantkit.yml` at all against an iOS-only
    /// Xcode app picked `platform=macOS` here — wrong, and it failed
    /// outright on a provisioning-profile error — while `setup` moments
    /// later, on the identical project, correctly picked a real iOS
    /// Simulator via `ProjectDetectionPlan`'s own default) showed this
    /// literal had drifted to only special-case `.swiftPackageApple`,
    /// leaving `.xcodeProject`/`.xcodeWorkspace` on the wrong default.
    /// `.xcodeProject`/`.xcodeWorkspace` can genuinely be a macOS app too —
    /// this is a last-resort guess for when nothing else (an explicit
    /// destination, or `XcodeConfigDetector`'s own real per-scheme
    /// discovery) has already answered the question, not a claim that
    /// every Xcode project targets iOS.
    public static func defaultDestination(for kind: ProjectKind) -> String {
        switch kind {
        case .swiftPackageApple, .xcodeProject, .xcodeWorkspace:
            "platform=iOS Simulator,name=iPhone 16"
        case .swiftPackageMacOS, .auto:
            "platform=macOS"
        }
    }

    /// The same destination with its concrete device dropped — what to pass
    /// to an `xcodebuild` invocation that only *reads* settings and never
    /// builds or runs anything on a device.
    ///
    /// `xcodebuild -showBuildSettings -destination platform=iOS Simulator,id=<udid>`
    /// refuses outright ("Unable to find a device matching the provided
    /// destination specifier", exit 64) the moment that UDID stops resolving
    /// — the device was deleted, or the simulator set was reset, at any point
    /// after the build that produced the artifact. Observed in CI: a schemata
    /// chunk built and tested fine, then `resolveSchemataBuildReceipt` could
    /// not read back where its own product had been written, so the chunk
    /// degraded to isolated with `.buildReceiptUnavailable` — a real
    /// degradation caused by nothing about the build.
    ///
    /// A settings query needs the *platform*, because that is what selects
    /// the `Debug-iphonesimulator` product directory and the wrapper layout;
    /// it does not need a device. Measured against two real fixtures on Xcode
    /// 26.6: a device-pinned and a `generic/platform=iOS Simulator` query
    /// return byte-identical `MACH_O_TYPE`, `BUILT_PRODUCTS_DIR`,
    /// `EXECUTABLE_PATH`, `WRAPPER_NAME` and `PRODUCT_NAME`. (They differ in
    /// `ARCHS`, `ONLY_ACTIVE_ARCH`, `TARGET_DEVICE_*` and the per-arch
    /// intermediate paths derived from them — none of which any settings
    /// reader here consults.)
    ///
    /// Only a simulator platform is rewritten, and only when `platform=`
    /// names one exactly: `platform=macOS` has no device to lose, an
    /// already-generic specifier parses no `platform=` field at all and is
    /// returned untouched, and a physical-device destination is left alone
    /// rather than guessed at, since no measurement here covers one. A
    /// rewrite that were wrong anyway fails closed — a `BUILT_PRODUCTS_DIR`
    /// for the wrong platform holds no artifact, and the caller raises
    /// `builtArtifactMissing`.
    public static func buildSettingsDestination(for destination: String) -> String {
        guard
            let platform = field(named: "platform", inDestination: destination),
            simulatorPlatforms.contains(where: { $0.name.caseInsensitiveCompare(platform) == .orderedSame })
        else { return destination }
        return "generic/platform=\(platform)"
    }
}
