import Foundation

/// Which platform slice of `MutantKitSchemataRuntime` a schemata chunk build
/// needs to link. A chunk built for the iOS Simulator must link a
/// simulator-built archive; handing it the macOS archive `swift build`
/// produces fails at the linker with
/// "building for 'iOS-simulator', but linking in object file ... built for 'macOS'".
///
/// The raw value is the SDK canonical name (`xcrun --sdk <name>`), which is
/// also the subdirectory `scripts/build-schemata-runtime.sh` writes into.
public enum SchemataRuntimePlatform: String, Sendable, Equatable, Hashable, CaseIterable {
    case macOS = "macosx"
    case iOSSimulator = "iphonesimulator"

    /// The platform a build for `destination` links against, or `nil` for a
    /// destination this runtime has no archive for.
    ///
    /// Fails closed on purpose. A physical iOS device, Mac Catalyst, or a
    /// tvOS/watchOS/visionOS destination is *not* silently mapped onto the
    /// nearest available slice: that is precisely the bug this type exists
    /// to prevent, and it would surface as an opaque `ld:` error inside
    /// someone else's build log rather than a MutantKit configuration error.
    ///
    /// Parses the real Xcode destination grammar deliberately, not by
    /// guessing: a destination is a comma-separated `key=value` list,
    /// optionally prefixed with Xcode's `generic/` build-only placeholder
    /// form (`generic/platform=iOS Simulator`, `generic/platform=macOS`) —
    /// that prefix only ever attaches to the `platform` key itself, so both
    /// forms are handled by extracting `platform` (falling back to
    /// `generic/platform`) once, rather than special-casing the Simulator
    /// shape with a whole-string substring test and leaving the generic
    /// macOS shape to fall through `DestinationResolver.field(named:
    /// "platform", ...)`, which does not recognise the `generic/` prefix at
    /// all — a destination-string-shape regression an earlier draft of this
    /// resolver had, caught in adversarial review before it shipped.
    public static func resolve(destination: String) -> SchemataRuntimePlatform? {
        guard let platform = platformValue(inDestination: destination) else { return nil }

        if platform.localizedCaseInsensitiveContains("iOS Simulator") {
            return .iOSSimulator
        }
        guard platform.localizedCaseInsensitiveCompare("macOS") == .orderedSame else { return nil }
        // `platform=macOS,variant=Mac Catalyst` builds for `-macabi`, whose
        // objects are NOT interchangeable with plain macOS ones — same class
        // of linker mismatch, different words. Explicitly unsupported.
        if let variant = DestinationResolver.field(named: "variant", inDestination: destination),
           variant.localizedCaseInsensitiveContains("Catalyst") {
            return nil
        }
        return .macOS
    }

    private static func platformValue(inDestination destination: String) -> String? {
        DestinationResolver.field(named: "platform", inDestination: destination)
            ?? DestinationResolver.field(named: "generic/platform", inDestination: destination)
    }
}
