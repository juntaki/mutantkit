@testable import AppleBuildAdapters
import Foundation

/// Recorded-shape `simctl` JSON and device builders shared by the unit tests.
/// Every runtime carries its own `version` and `platform`; no test derives one
/// from an identifier.
enum SimctlFixtures {
    static let prefix = "com.apple.CoreSimulator.SimRuntime."

    /// One `simctl list runtimes --json` entry; `nil` omits the field, as a broken `simctl` would.
    struct Runtime {
        let identifier: String
        let version: String?
        let platform: String?

        init(_ identifier: String, _ version: String?, _ platform: String?) {
            self.identifier = identifier
            self.version = version
            self.platform = platform
        }
    }

    /// `simctl list runtimes --json` for a runtime list.
    static func runtimesJSON(_ runtimes: [Runtime]) -> String {
        let entries = runtimes.map { runtime -> String in
            var fields = ["\"identifier\": \"\(runtime.identifier)\"", "\"isAvailable\": true", "\"buildversion\": \"24A000\""]
            if let version = runtime.version { fields.append("\"version\": \"\(version)\"") }
            if let platform = runtime.platform { fields.append("\"platform\": \"\(platform)\"") }
            return "{\(fields.joined(separator: ", "))}"
        }
        return "{\"runtimes\": [\(entries.joined(separator: ","))]}"
    }

    /// The runtimes JSON matching `iOS-18-0` only — what most pool tests list.
    static let iOS18RuntimesJSON = runtimesJSON([Runtime(prefix + "iOS-18-0", "18.0", "iOS")])

    /// `simctl list devices available --json` for `[identifier: [(udid, name)]]`.
    static func devicesJSON(_ devices: [String: [(udid: String, name: String)]]) -> String {
        let groups = devices.map { identifier, list -> String in
            let entries = list.map { "{\"udid\": \"\($0.udid)\", \"name\": \"\($0.name)\", \"state\": \"Shutdown\", \"isAvailable\": true}" }
            return "\"\(identifier)\": [\(entries.joined(separator: ","))]"
        }
        return "{\"devices\": {\(groups.joined(separator: ","))}}"
    }

    static func catalog(runtimes: [Runtime], devices: [String: [(udid: String, name: String)]]) throws -> SimulatorRuntimeCatalog {
        try SimulatorRuntimeCatalog.build(runtimesJSON: Data(runtimesJSON(runtimes).utf8), devicesJSON: Data(devicesJSON(devices).utf8))
    }

    /// A catalog device on a runtime of the given platform/version, built directly.
    /// `.device` is the plain `SimulatorDevice` (the persisted shape).
    static func device(
        _ name: String, udid: String? = nil, identifier: String = prefix + "iOS-18-0",
        platform: String = "iOS", version: String = "18.0", state: String = "Shutdown"
    ) -> CatalogDevice {
        CatalogDevice(
            device: SimulatorDevice(
                udid: udid ?? "\(name)-\(identifier)-\(version)".replacingOccurrences(of: " ", with: "-"),
                name: name, runtimeIdentifier: identifier, state: state
            ),
            platform: platform, runtimeVersion: RuntimeVersion(version)!
        )
    }

    /// A lease on `device`, destination as the pool builds it.
    static func lease(_ device: CatalogDevice) -> SimulatorLease {
        SimulatorLease(device: device.device, destination: device.destination)
    }
}
