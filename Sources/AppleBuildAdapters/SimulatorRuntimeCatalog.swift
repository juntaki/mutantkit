import Foundation

/// A dotted numeric OS version (`27.2`, `26.3.1`), compared component-wise as
/// integers — `27.10` is newer than `27.9`, and `27.2` equals `27.2.0`.
///
/// The only source of an OS version anywhere in this codebase is a runtime's
/// own `version` field from `simctl list runtimes --json`. A runtime
/// *identifier* is an opaque key and is never parsed for a version.
public struct RuntimeVersion: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Components with trailing zeros removed, so `27.2` and `27.2.0` are one value.
    public let components: [Int]

    /// `nil` unless `string` is one or more dot-separated non-negative integers.
    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) ? Int(part) : nil }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }
        var trimmed = numbers
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        components = trimmed
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let version = RuntimeVersion(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a dotted numeric version: \(raw)"))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// At least `major.minor` (`27.0`, not `27`), as Apple prints versions.
    public var description: String {
        (components + (components.count < 2 ? [0] : [])).map(String.init).joined(separator: ".")
    }

    public static func < (lhs: RuntimeVersion, rhs: RuntimeVersion) -> Bool {
        for (left, right) in zip(lhs.components, rhs.components) where left != right { return left < right }
        return lhs.components.count < rhs.components.count
    }
}

/// A device together with the runtime facts the catalog knows about it.
///
/// `SimulatorDevice` keeps its persisted shape (it is encoded into run
/// manifests); platform and version live here, catalog-side only.
public struct CatalogDevice: Sendable, Hashable {
    public let device: SimulatorDevice
    /// `iOS`, `tvOS`, `watchOS` or `visionOS` — the runtime's `platform` field.
    public let platform: String
    /// The runtime's `version` field.
    public let runtimeVersion: RuntimeVersion

    public init(device: SimulatorDevice, platform: String, runtimeVersion: RuntimeVersion) {
        self.device = device
        self.platform = platform
        self.runtimeVersion = runtimeVersion
    }

    public var udid: String { device.udid }
    public var name: String { device.name }
    public var runtimeIdentifier: String { device.runtimeIdentifier }

    /// The `-destination` argument that addresses this exact device: by UDID,
    /// never by name (names repeat across — and within — runtimes), with the
    /// `platform=` value taken from the runtime's `platform` field.
    public var destination: String {
        "platform=\(SimulatorRuntimeCatalog.destinationPlatform(forPlatform: platform)),id=\(udid)"
    }
}

/// A device `simctl` listed that the catalog could not place on a known runtime.
public struct SkippedDevice: Sendable, Hashable {
    public let udid: String
    public let name: String
    public let runtimeIdentifier: String
    public let reason: String
}

/// One installed simulator runtime, as `simctl list runtimes --json` reports it.
public struct SimulatorRuntime: Sendable, Hashable {
    /// Opaque key (e.g. `com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4`).
    /// Used only to join and to tell two runtimes apart — never parsed.
    public let identifier: String
    public let version: RuntimeVersion
    /// The runtime's own `platform` field, normalized (`xrOS` → `visionOS`):
    /// `iOS`, `tvOS`, `watchOS`, `visionOS`.
    public let platform: String
    public let buildVersion: String?
    /// Available devices under this runtime, sorted by name then UDID.
    public let devices: [CatalogDevice]

    /// The `platform=` value `xcodebuild -destination` expects for this runtime.
    public var destinationPlatform: String { SimulatorRuntimeCatalog.destinationPlatform(forPlatform: platform) }
}

public enum SimulatorRuntimeCatalogError: Error, CustomStringConvertible, Equatable {
    case unreadableJSON(source: String, detail: String)
    /// A runtime has available devices but `simctl` gave no usable `version`
    /// or `platform` for it. Refusing to guess one from the identifier.
    case runtimeMetadataMissing(identifier: String, field: String)

    public var description: String {
        switch self {
        case let .unreadableJSON(source, detail):
            "simctl emitted unreadable JSON for `\(source)`: \(detail)"
        case let .runtimeMetadataMissing(identifier, field):
            """
            `simctl list runtimes --json` reports no usable `\(field)` for runtime \(identifier), \
            which has available simulators. MutantKit does not infer an OS version or platform \
            from a runtime identifier; update Xcode or repair the runtime \
            (`xcrun simctl runtime list`).
            """
        }
    }
}

/// The one place MutantKit learns which simulator runtimes exist: built from
/// `simctl list runtimes --json` joined, by runtime identifier, with
/// `simctl list devices available --json`.
///
/// Apple's identifiers are not a version scheme — a device-specific runtime is
/// `…SimRuntime.iOS-27-2-iPhone19-4` (OS 27.2, not 27.2.4), and the shape can
/// change again — so the identifier is a join key only. Version and platform
/// come from the runtime's `version` and `platform` fields. A guard test
/// (`SimulatorRuntimeIdentifierGuardTests`) fails if Sources/ or the test
/// support code parse a runtime identifier for a version or platform.
public struct SimulatorRuntimeCatalog: Sendable {
    /// Unavailable runtimes and runtimes with no available device are omitted.
    /// Sorted by version, then identifier.
    public let runtimes: [SimulatorRuntime]

    /// Devices `simctl` listed under a runtime `list runtimes` does not report
    /// (a runtime removed or mid-install while the two listings ran). They are
    /// left out of `runtimes` rather than aborting discovery; a caller that
    /// needs one of them (`DestinationResolver`) looks it up in `skipped` by UDID or name
    /// and reports its `reason`.
    public let skipped: [SkippedDevice]

    public var devices: [CatalogDevice] { runtimes.flatMap(\.devices) }

    public init(runtimes: [SimulatorRuntime], skipped: [SkippedDevice] = []) {
        self.runtimes = runtimes.sorted { ($0.version, $0.identifier) < ($1.version, $1.identifier) }
        self.skipped = skipped
    }

    /// This catalog without the device `udid` — how a pool keeps its one
    /// source of truth current after deleting a clone.
    public func removing(udid: String) -> SimulatorRuntimeCatalog {
        SimulatorRuntimeCatalog(
            runtimes: runtimes.map {
                SimulatorRuntime(
                    identifier: $0.identifier, version: $0.version, platform: $0.platform,
                    buildVersion: $0.buildVersion, devices: $0.devices.filter { $0.udid != udid }
                )
            }.filter { !$0.devices.isEmpty },
            skipped: skipped.filter { $0.udid != udid }
        )
    }

    /// `simctl` argv for the two listings, in the order `build` takes them.
    static let runtimesArguments = ["simctl", "list", "runtimes", "--json"]
    static let devicesArguments = ["simctl", "list", "devices", "available", "--json"]

    public static func build(runtimesJSON: Data, devicesJSON: Data) throws -> SimulatorRuntimeCatalog {
        struct RuntimesPayload: Decodable {
            struct Runtime: Decodable {
                let identifier: String
                let version: String?
                let platform: String?
                let isAvailable: Bool?
                let buildversion: String?
            }

            let runtimes: [Runtime]
        }
        struct DevicesPayload: Decodable {
            struct Device: Decodable {
                let udid: String
                let name: String
                let state: String
                let isAvailable: Bool?
            }

            let devices: [String: [Device]]
        }

        let runtimesPayload: RuntimesPayload
        let devicesPayload: DevicesPayload
        do { runtimesPayload = try JSONDecoder().decode(RuntimesPayload.self, from: runtimesJSON) } catch {
            throw SimulatorRuntimeCatalogError.unreadableJSON(source: "list runtimes", detail: "\(error)")
        }
        do { devicesPayload = try JSONDecoder().decode(DevicesPayload.self, from: devicesJSON) } catch {
            throw SimulatorRuntimeCatalogError.unreadableJSON(source: "list devices available", detail: "\(error)")
        }

        let known = Dictionary(runtimesPayload.runtimes.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var runtimes: [SimulatorRuntime] = []
        var skipped: [SkippedDevice] = []
        for (identifier, listed) in devicesPayload.devices.sorted(by: { $0.key < $1.key }) {
            let live = listed.filter { $0.isAvailable ?? true }
            guard !live.isEmpty else { continue }
            guard let runtime = known[identifier] else {
                skipped += live.map {
                    SkippedDevice(
                        udid: $0.udid, name: $0.name, runtimeIdentifier: identifier,
                        reason: "its runtime \(identifier) is not in `simctl list runtimes --json` (removed or still installing)"
                    )
                }
                continue
            }
            guard runtime.isAvailable ?? true else { continue }
            guard let rawVersion = runtime.version, let version = RuntimeVersion(rawVersion) else {
                throw SimulatorRuntimeCatalogError.runtimeMetadataMissing(identifier: identifier, field: "version")
            }
            guard let rawPlatform = runtime.platform, !rawPlatform.isEmpty else {
                throw SimulatorRuntimeCatalogError.runtimeMetadataMissing(identifier: identifier, field: "platform")
            }
            let platform = normalizedPlatform(rawPlatform)
            let devices = live
                .map {
                    CatalogDevice(
                        device: SimulatorDevice(udid: $0.udid, name: $0.name, runtimeIdentifier: identifier, state: $0.state),
                        platform: platform, runtimeVersion: version
                    )
                }
                .sorted { ($0.name, $0.udid) < ($1.name, $1.udid) }
            runtimes.append(SimulatorRuntime(
                identifier: identifier, version: version, platform: platform,
                buildVersion: runtime.buildversion, devices: devices
            ))
        }
        return SimulatorRuntimeCatalog(runtimes: runtimes, skipped: skipped)
    }

    // MARK: - Platform names

    /// `simctl` has reported visionOS as both `visionOS` and `xrOS`.
    static func normalizedPlatform(_ raw: String) -> String {
        raw.caseInsensitiveCompare("xrOS") == .orderedSame ? "visionOS" : raw
    }

    /// `iOS` → `iOS Simulator`, matching `xcodebuild -destination`'s `platform=`.
    public static func destinationPlatform(forPlatform platform: String) -> String { "\(normalizedPlatform(platform)) Simulator" }

    // MARK: - Selection

    /// The runtimes of `platform` at its highest installed version — usually
    /// one, several when a device-specific runtime shares a version with a
    /// generic one. Sorted by identifier.
    public func latestRuntimes(platform: String) -> [SimulatorRuntime] {
        let candidates = runtimes.filter { $0.platform == platform }
        guard let latest = candidates.map(\.version).max() else { return [] }
        return candidates.filter { $0.version == latest }
    }

    /// Runtimes of `platform` whose version equals `version`.
    public func runtimes(platform: String, version: RuntimeVersion) -> [SimulatorRuntime] {
        runtimes.filter { $0.platform == platform && $0.version == version }
    }

    /// Selection rule when several runtimes share one version: the device named
    /// `name` under the runtime with the smallest identifier (an arbitrary but
    /// stable tiebreak — identifiers are opaque), so two runs on one machine
    /// pick the same device. Callers address the result by UDID, which
    /// `xcodebuild` resolves unambiguously however many runtimes share the version.
    public static func device(named name: String, in runtimes: [SimulatorRuntime]) -> CatalogDevice? {
        runtimes.sorted { $0.identifier < $1.identifier }
            .lazy.compactMap { $0.devices.first(where: { $0.name == name }) }.first
    }
}
