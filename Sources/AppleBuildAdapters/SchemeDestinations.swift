import Foundation
import MutationExecution

/// The simulator devices one scheme can actually build and test on: the
/// *Available destinations* of `xcodebuild -showdestinations -scheme <scheme>`.
///
/// A device that exists in the simulator catalog is not thereby a destination
/// of the scheme (platform, SDK or deployment-target mismatch). Destination
/// resolution takes this set so it picks only among devices the scheme
/// supports and fails explicitly when there are none, instead of handing
/// `xcodebuild` a UDID it will refuse.
public struct SchemeDestinations: Sendable, Equatable {
    public let scheme: String
    /// Uppercased device identifiers of every available destination.
    public let identifiers: Set<String>

    public init(scheme: String, identifiers: some Sequence<String>) {
        self.scheme = scheme
        self.identifiers = Set(identifiers.map { $0.uppercased() })
    }

    public func supports(udid: String) -> Bool {
        identifiers.contains(udid.uppercased())
    }

    /// Parses `-showdestinations` output. Only lines in the *Available*
    /// section count: the *Ineligible* section lists devices the scheme
    /// refuses (with an `error:` field), and a placeholder entry carries no
    /// device identifier a catalog could match.
    /// `nil` when no *Available destinations* header is present: unrecognised
    /// output is "unknown", not "the scheme supports nothing".
    public static func parse(scheme: String, output: String) -> SchemeDestinations? {
        var sawAvailable = false
        var inAvailable = false
        var identifiers: [String] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Available destinations") {
                inAvailable = true
                sawAvailable = true
            } else if line.hasPrefix("Ineligible destinations") {
                inAvailable = false
            } else if inAvailable, line.hasPrefix("{"), let id = field("id", inLine: line) {
                identifiers.append(id)
            }
        }
        return sawAvailable ? SchemeDestinations(scheme: scheme, identifiers: identifiers) : nil
    }

    private static func field(_ key: String, inLine line: String) -> String? {
        let body = line.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
        for component in body.split(separator: ",") {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(key + ":") {
                return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Asks `xcodebuild` for the scheme's available destinations. `nil` when
    /// that cannot be established (the listing fails): "unknown" is not
    /// "empty", and `doctor`'s Destinations check reports the failure itself.
    static func load(scheme: String, projectArguments: [String], in directory: URL) async -> SchemeDestinations? {
        let result = try? await ProcessSupervisor.run(
            executable: ToolPaths.xcodebuild,
            arguments: projectArguments + ["-showdestinations", "-scheme", scheme],
            workingDirectory: directory,
            timeoutSeconds: 180
        )
        guard let result, result.succeeded else { return nil }
        return parse(scheme: scheme, output: String(decoding: result.standardOutput, as: UTF8.self))
    }
}
