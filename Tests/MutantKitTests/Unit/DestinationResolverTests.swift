@testable import AppleBuildAdapters
import Foundation
import Testing

/// Pins `DestinationResolver`'s decision logic against a hand-built device
/// list — no real simulator or `simctl` call involved, so the ambiguity and
/// "latest runtime" rules this exists to enforce are testable without a
/// machine-specific simulator inventory.
@Suite("Destination resolver")
struct DestinationResolverTests {
    private static func device(_ name: String, runtime: String, udid: String? = nil) -> SimulatorDevice {
        SimulatorDevice(
            udid: udid ?? "\(name)-\(runtime)".replacingOccurrences(of: " ", with: "-"),
            name: name,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-\(runtime)",
            state: "Shutdown"
        )
    }

    // MARK: - Non-simulator destinations pass through untouched

    @Test("A macOS destination is not resolved, and has no device")
    func macOSDestinationPassesThrough() throws {
        let resolved = try DestinationResolver.resolve("platform=macOS", against: [])
        #expect(resolved.device == nil)
        #expect(resolved.destinationArgument == "platform=macOS")
    }

    @Test("A generic placeholder is not resolved, and has no device")
    func genericPlaceholderPassesThrough() throws {
        let resolved = try DestinationResolver.resolve("generic/platform=iOS", against: [
            Self.device("iPhone 16", runtime: "26-5")
        ])
        #expect(resolved.device == nil)
    }

    // MARK: - Already pinned to id=

    @Test("An id= destination resolves to the matching device")
    func idDestinationResolvesDirectly() throws {
        let target = Self.device("iPhone 16", runtime: "26-5", udid: "ABCD")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,id=ABCD", against: [target]
        )
        #expect(resolved.device?.udid == "ABCD")
        #expect(resolved.destinationArgument == "platform=iOS Simulator,id=ABCD")
    }

    @Test("An id= destination naming a UDID nothing has is rejected")
    func idDestinationUnknownUDIDIsRejected() {
        #expect(throws: DestinationResolutionError.self) {
            try DestinationResolver.resolve(
                "platform=iOS Simulator,id=NOPE", against: [Self.device("iPhone 16", runtime: "26-5")]
            )
        }
    }

    // MARK: - name=, no explicit OS: resolves to the highest installed runtime overall

    @Test("A unique name resolves cleanly")
    func uniqueNameResolves() throws {
        let target = Self.device("Example iPad mini", runtime: "26-5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=Example iPad mini", against: [target]
        )
        #expect(resolved.device?.udid == target.udid)
    }

    @Test("A name matching devices under two runtimes resolves to the higher-version one")
    func nameUnderTwoRuntimesResolvesToLatest() throws {
        let older = Self.device("iPhone 16e", runtime: "26-3-1")
        let latest = Self.device("iPhone 16e", runtime: "26-5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e", against: [older, latest]
        )
        #expect(resolved.device?.udid == latest.udid)
    }

    /// The exact bug this exists to prevent: a name that only exists under
    /// an older runtime, while a *different* device name exists under the
    /// actual latest — silently picking the old-runtime device (what
    /// `SimulatorPool`'s own name-substring matching used to risk) would
    /// have been wrong. This must error, not guess.
    @Test("A name that exists only under an old runtime is a hard error, not a silent fallback")
    func nameOnlyUnderOldRuntimeIsRejected() {
        let oldOnly = Self.device("Example iPad mini", runtime: "26-3-1")
        let somethingElseIsLatest = Self.device("Other Device", runtime: "26-5")

        #expect(throws: DestinationResolutionError.self) {
            try DestinationResolver.resolve(
                "platform=iOS Simulator,name=Example iPad mini", against: [oldOnly, somethingElseIsLatest]
            )
        }
    }

    @Test("A name matching no device at all is a hard error")
    func nameNotFoundIsRejected() {
        #expect(throws: DestinationResolutionError.self) {
            try DestinationResolver.resolve(
                "platform=iOS Simulator,name=Does Not Exist", against: [Self.device("iPhone 16", runtime: "26-5")]
            )
        }
    }

    // MARK: - name= with an explicit OS

    @Test("An explicit OS resolves to that runtime specifically, even if it is not latest")
    func explicitOSResolvesToNamedRuntime() throws {
        let older = Self.device("iPhone 16e", runtime: "26-3-1")
        let latest = Self.device("iPhone 16e", runtime: "26-5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e,OS=26-3-1", against: [older, latest]
        )
        #expect(resolved.device?.udid == older.udid)
    }

    @Test("OS=latest is treated the same as no explicit OS")
    func osLatestIsTreatedAsImplicit() throws {
        let older = Self.device("iPhone 16e", runtime: "26-3-1")
        let latest = Self.device("iPhone 16e", runtime: "26-5")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e,OS=latest", against: [older, latest]
        )
        #expect(resolved.device?.udid == latest.udid)
    }

    // MARK: - Runtime version comparison is numeric, not lexicographic

    /// `iOS-26-10` must sort after `iOS-26-9` — a plain string comparison of
    /// the identifiers gets this backwards (`'1' < '9'`).
    @Test("Runtime version comparison is numeric: iOS-26-10 is newer than iOS-26-9")
    func versionComparisonIsNumericNotLexicographic() throws {
        let nine = Self.device("iPhone 16e", runtime: "26-9")
        let ten = Self.device("iPhone 16e", runtime: "26-10")
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=iPhone 16e", against: [nine, ten]
        )
        #expect(resolved.device?.udid == ten.udid)
    }

    // MARK: - Round trip

    @Test("A resolved destination survives JSON encoding")
    func resolvedDestinationRoundTrips() throws {
        let resolved = try DestinationResolver.resolve(
            "platform=iOS Simulator,name=X", against: [Self.device("X", runtime: "26-5")]
        )
        let data = try JSONEncoder().encode(resolved)
        let decoded = try JSONDecoder().decode(ResolvedDestination.self, from: data)
        #expect(decoded == resolved)
    }
}
