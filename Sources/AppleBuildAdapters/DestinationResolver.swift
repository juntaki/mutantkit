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

    public init(requested: String, device: SimulatorDevice?) {
        self.requested = requested
        self.device = device
    }

    /// The `-destination` argument to actually pass to `xcodebuild`: the
    /// resolved device by UDID when there is one, the original specifier
    /// otherwise.
    public var destinationArgument: String { device?.destination ?? requested }
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
    /// A destination already pinned to `id=<udid>` names a UDID nothing on
    /// this machine has.
    case unknownUDID(String)
    case simulatorPoolFailure(String)

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
        case let .unknownUDID(udid):
            "No simulator with UDID \(udid) is available on this machine."
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
    /// token its `SimRuntime` identifier uses for the same platform (e.g. a
    /// `platform=visionOS Simulator` destination's devices report a runtime
    /// identifier containing `SimRuntime.xrOS-...`, not `visionOS` — real
    /// Apple naming, not a typo). Phase C10 (competitive-parity program):
    /// this list used to be `"iOS Simulator"` alone, which meant a
    /// `platform=tvOS Simulator,name=X`/`watchOS Simulator`/`visionOS
    /// Simulator` destination silently skipped this whole type's name/UDID
    /// pinning entirely — reintroducing, for those three platforms only, the
    /// exact "OS:latest resolves differently per invocation" bug this type
    /// exists to fix for iOS (see this type's own doc comment).
    static let simulatorPlatforms: [(name: String, runtimeToken: String)] = [
        ("iOS Simulator", "iOS"),
        ("tvOS Simulator", "tvOS"),
        ("watchOS Simulator", "watchOS"),
        ("visionOS Simulator", "xrOS")
    ]

    /// Module-internal, not `private`: `XcodeBuildAdapter
    /// .destinationNeedsSimulatorLease` reuses this exact check rather than
    /// keeping its own separate `"iOS Simulator"`-only test — Phase C10
    /// found that duplicate had the identical bug this one did, and fixing
    /// one without the other would have left tvOS/watchOS/visionOS
    /// destinations resolved correctly but leased not at all, letting two
    /// concurrent workers collide on one real device.
    static func isSimulatorDestination(_ requested: String) -> Bool {
        simulatorPlatforms.contains { requested.localizedCaseInsensitiveContains($0.name) }
    }

    /// The `SimRuntime` token for the platform `requested` names (`nil` for
    /// a non-simulator destination) — used to scope "latest installed
    /// runtime" to runtimes of the *same platform* as what was actually
    /// requested, never across all installed simulator platforms at once.
    /// Without this, a machine with both iOS and tvOS runtimes installed
    /// resolving an unqualified tvOS destination could in principle compute
    /// "latest" from an iOS runtime identifier that happens to sort higher —
    /// wrong for exactly the same reason mixing runtimes together was
    /// already understood to be wrong for iOS alone.
    private static func runtimeToken(forRequestedDestination requested: String) -> String? {
        simulatorPlatforms.first { requested.localizedCaseInsensitiveContains($0.name) }?.runtimeToken
    }

    /// Resolves against a live pool — the production entry point. Devices
    /// are only listed (an actual `simctl` call) when `requested` actually
    /// names a simulator; a macOS or physical-device destination never
    /// touches `simctl` at all.
    public static func resolve(_ requested: String, using pool: SimulatorPool) async throws -> ResolvedDestination {
        guard isSimulatorDestination(requested) else {
            return ResolvedDestination(requested: requested, device: nil)
        }

        let devices: [SimulatorDevice]
        do {
            devices = try await pool.availableDevices()
        } catch let error as SimulatorPoolError {
            throw DestinationResolutionError.simulatorPoolFailure(error.description)
        }

        return try resolve(requested, against: devices)
    }

    /// The pure decision, given the device list already in hand — separated
    /// from `resolve(_:using:)` so the ambiguity/not-found/latest-runtime
    /// logic can be pinned in a unit test without any of them needing a real
    /// simulator or a `simctl` call to do it.
    static func resolve(_ requested: String, against devices: [SimulatorDevice]) throws -> ResolvedDestination {
        guard isSimulatorDestination(requested) else {
            // macOS, a physical device, or something this tool does not
            // model: nothing to pin, and nothing to be ambiguous about.
            return ResolvedDestination(requested: requested, device: nil)
        }

        if let udid = udid(inDestination: requested) {
            guard let match = devices.first(where: { $0.udid == udid }) else {
                throw DestinationResolutionError.unknownUDID(udid)
            }
            return ResolvedDestination(requested: requested, device: match)
        }

        guard let name = Self.deviceName(inDestination: requested) else {
            // A simulator destination with neither `id=` nor `name=` — e.g.
            // the generic placeholder. Nothing this run can pin ahead of
            // time; the existing name-hint leasing path handles it as before.
            return ResolvedDestination(requested: requested, device: nil)
        }

        let matches = devices.filter { $0.name == name }
        guard !matches.isEmpty else {
            throw DestinationResolutionError.notFound(
                name: name,
                knownNames: Array(Set(devices.map(\.name))).sorted()
            )
        }

        if let explicitOS = Self.explicitOS(inDestination: requested) {
            guard let match = matches.first(where: { $0.runtimeIdentifier.localizedCaseInsensitiveContains(explicitOS) })
            else {
                throw DestinationResolutionError.notFound(
                    name: "\(name) (OS \(explicitOS))",
                    knownNames: matches.map { "\($0.name) (\($0.runtimeIdentifier))" }
                )
            }
            return ResolvedDestination(requested: requested, device: match)
        }

        // No explicit OS: this is exactly the implicit `OS:latest` case.
        // "Latest" is the highest-version runtime installed on the machine
        // at all — not just among this name's matches — because that is
        // what xcodebuild's own unqualified resolution means, and the
        // property a resolution must not silently deviate from. Scoped to
        // runtimes of the *requested platform* (`platformDevices`), not
        // every installed simulator platform at once — see
        // `runtimeToken(forRequestedDestination:)`'s own doc comment.
        let requestedRuntimeToken = Self.runtimeToken(forRequestedDestination: requested)
        let platformDevices = requestedRuntimeToken.map { token in
            devices.filter { $0.runtimeIdentifier.localizedCaseInsensitiveContains("SimRuntime.\(token)-") }
        } ?? devices
        guard let latestRuntime = platformDevices.map(\.runtimeIdentifier).max(by: Self.runtimeIsOlder) else {
            throw DestinationResolutionError.notFound(name: name, knownNames: [])
        }

        guard let match = matches.first(where: { $0.runtimeIdentifier == latestRuntime }) else {
            throw DestinationResolutionError.ambiguousAcrossRuntimes(
                name: name,
                expectedRuntime: latestRuntime,
                foundUnder: Array(Set(matches.map(\.runtimeIdentifier))).sorted()
            )
        }
        return ResolvedDestination(requested: requested, device: match)
    }

    // MARK: - Destination string parsing

    static func field(named field: String, inDestination destination: String) -> String? {
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

    // MARK: - Runtime version comparison

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-3-1` → `[26, 3, 1]`, or
    /// `...SimRuntime.tvOS-17-0` → `[17, 0]`, and likewise for `watchOS-`/
    /// `xrOS-`.
    ///
    /// Compared component-wise as integers, not as strings: a lexicographic
    /// comparison of the identifiers puts `iOS-26-10` before `iOS-26-9`
    /// (`'1' < '9'`), which is simply wrong once any component reaches two
    /// digits.
    ///
    /// Phase C10 (competitive-parity program): generalized from a
    /// hardcoded `"iOS-"` search to every known platform token. Before
    /// this, a tvOS/watchOS/visionOS runtime identifier always produced an
    /// empty `[]` here regardless of its real version — harmless while
    /// `resolve` only ever reached this function for iOS destinations (an
    /// empty array always sorts as "oldest", so a real iOS runtime always
    /// won `max(by:)` against any non-iOS one), but would have made
    /// `runtimeIsOlder` unable to tell two different *tvOS* runtime
    /// versions apart from each other at all once tvOS/watchOS/visionOS
    /// destinations started reaching this same "OS:latest" logic.
    private static func versionComponents(of runtimeIdentifier: String) -> [Int] {
        for (_, token) in Self.simulatorPlatforms {
            guard let range = runtimeIdentifier.range(of: "\(token)-") else { continue }
            return runtimeIdentifier[range.upperBound...].split(separator: "-").compactMap { Int($0) }
        }
        return []
    }

    private static func runtimeIsOlder(_ lhs: String, _ rhs: String) -> Bool {
        let left = versionComponents(of: lhs)
        let right = versionComponents(of: rhs)
        for (a, b) in zip(left, right) where a != b { return a < b }
        return left.count < right.count
    }
}
