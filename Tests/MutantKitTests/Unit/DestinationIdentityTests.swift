@testable import AppleBuildAdapters
@testable import CLI
import Foundation
import MutationExecution
import MutationModel
import Testing

/// One destination, one identity, one lock key: `run` and `dry-run` take the
/// run lock through `DestinationLock` from the `ResolvedInvocationContext`, so
/// differently spelled requests for one device collide, and a lost race never
/// reaches a simulator side effect. No simulator is involved.
@Suite("DestinationIdentity and DestinationLock")
struct DestinationIdentityTests {
    private func device(udid: String) -> SimulatorDevice {
        SimctlFixtures.device("iPhone 17 Pro", udid: udid, identifier: SimctlFixtures.prefix + "iOS-18-2", version: "18.2").device
    }

    private func context(_ resolved: ResolvedDestination?, root: URL) -> ResolvedInvocationContext {
        ResolvedInvocationContext(
            projectRoot: root, projectPath: nil,
            detection: ProjectDetection(kind: resolved == nil ? .swiftPackageMacOS : .xcodeProject, reason: "test", projectFile: nil),
            scheme: nil, resolvedDestination: resolved
        )
    }

    private func pinned(_ udid: String, root: URL) -> ResolvedInvocationContext {
        context(ResolvedDestination(requested: "x", device: device(udid: udid), platform: "iOS"), root: root)
    }

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dest-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Auto, name, id and a stale platform label for one device share one identity")
    func spellingsOfOneDeviceShareIdentity() {
        let sim = device(udid: "AAAA-BBBB")
        let requests = [
            "auto", "platform=iOS Simulator,name=iPhone 17 Pro", "platform=iOS Simulator,id=AAAA-BBBB",
            "platform=tvOS Simulator,id=AAAA-BBBB"
        ]
        let keys = requests.map { DestinationIdentity(ResolvedDestination(requested: $0, device: sim, platform: "iOS")).lockKey }
        #expect(Set(keys).count == 1, "\(keys)")
        #expect(keys[0] == "simulator:AAAA-BBBB")
    }

    @Test("The real resolver maps a stale platform label and a name to the same identity")
    func resolverOutputsShareIdentity() throws {
        let ios = SimctlFixtures.device("iPhone 17 Pro", udid: "UDID-IOS", version: "18.2")
        let keys = try [
            "platform=iOS Simulator,id=UDID-IOS", "platform=tvOS Simulator,id=UDID-IOS",
            "platform=iOS Simulator,name=iPhone 17 Pro"
        ].map { try DestinationIdentity(DestinationResolver.resolve($0, against: [ios])).lockKey }
        #expect(Set(keys) == ["simulator:UDID-IOS"])
    }

    @Test("UDID case does not split an identity; different devices do")
    func udidCaseAndDistinctDevices() {
        let lower = DestinationIdentity(ResolvedDestination(requested: "x", device: device(udid: "abcd-1"), platform: "iOS"))
        let upper = DestinationIdentity(ResolvedDestination(requested: "x", device: device(udid: "ABCD-1"), platform: "iOS"))
        let other = DestinationIdentity(ResolvedDestination(requested: "x", device: device(udid: "ABCD-2"), platform: "iOS"))
        #expect(lower.lockKey == upper.lockKey)
        #expect(lower.lockKey != other.lockKey)
    }

    @Test("A destination with no device keys on its whitespace-normalised specifier; no destination is its own identity")
    func unpinnedAndNone() {
        let a = DestinationIdentity(ResolvedDestination(requested: "platform=macOS, arch=arm64", device: nil))
        let b = DestinationIdentity(ResolvedDestination(requested: " arch = arm64, platform=macos ", device: nil))
        #expect(a == b)
        #expect(a.lockKey == "destination:arch=arm64,platform=macos")
        #expect(DestinationIdentity(nil) == .none)
        #expect(a.lockKey != DestinationIdentity.none.lockKey)
    }

    @Test("Two commands resolving one device through different requests contend on one lock")
    func sameDeviceContendsAcrossSpellings() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = device(udid: "AAAA-BBBB")
        let runCtx = context(ResolvedDestination(requested: "auto", device: sim, platform: "iOS"), root: root)
        let dryCtx = context(
            ResolvedDestination(requested: "platform=iOS Simulator,name=iPhone 17 Pro", device: sim, platform: "iOS"), root: root
        )
        let held = try DestinationLock.acquire(context: runCtx, runDirectory: root.appendingPathComponent(".mutantkit"))
        defer { held.lock.release() }
        #expect(throws: RunIsolationLockError.self) {
            try DestinationLock.acquire(context: dryCtx, runDirectory: root.appendingPathComponent(".mutantkit"))
        }
    }

    @Test("Different devices in one project do not contend")
    func differentDevicesDoNotContend() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".mutantkit")
        let first = try DestinationLock.acquire(context: pinned("U1", root: root), runDirectory: dir)
        defer { first.lock.release() }
        let second = try DestinationLock.acquire(context: pinned("U2", root: root), runDirectory: dir)
        second.lock.release()
    }
}
