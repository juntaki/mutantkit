import Foundation

/// What one invocation's destination *is*, as a resource that can be
/// contended over. The single name used for the run/dry-run lock key and any
/// preflight that must agree on "same device".
///
/// Derived only from a `ResolvedDestination` (through
/// `ResolvedInvocationContext.destinationIdentity`), never from the raw
/// `project.destination` text: `auto`, `name=X`, `id=<udid>` and a stale
/// `platform=` label all resolve to the same simulator and therefore to the
/// same identity. The `platform=` label and the requested spelling are not
/// part of a simulator's identity; the UDID is.
public enum DestinationIdentity: Sendable, Hashable {
    /// A concrete simulator device.
    case simulator(udid: String)
    /// A destination with no device to pin (macOS, physical device, generic
    /// placeholder), keyed by its specifier normalised for whitespace.
    case unpinned(specifier: String)
    /// No destination at all (a plain SwiftPM macOS package).
    case none

    public init(_ resolved: ResolvedDestination?) {
        guard let resolved else {
            self = .none
            return
        }
        if let device = resolved.device {
            self = .simulator(udid: device.udid)
        } else {
            self = .unpinned(specifier: Self.normalizedSpecifier(resolved.requested))
        }
    }

    /// The stable string the run lock is keyed on.
    public var lockKey: String {
        switch self {
        case let .simulator(udid): "simulator:\(udid.uppercased())"
        case let .unpinned(specifier): "destination:\(specifier)"
        case .none: "none"
        }
    }

    /// Components trimmed, lowercased and sorted: `platform=macOS,arch=arm64`
    /// and `arch=arm64, platform=macos` name one destination.
    static func normalizedSpecifier(_ specifier: String) -> String {
        specifier.split(separator: ",")
            .map { component in
                component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .joined(separator: "=")
            }
            .sorted()
            .joined(separator: ",")
    }
}
