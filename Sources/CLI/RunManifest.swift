import AppleBuildAdapters
import Foundation
import MutationModel

/// Everything a faithful re-execution of one run needs to reproduce its
/// conditions exactly, rather than re-measuring them against whatever the
/// current environment happens to answer.
///
/// `mutantkit reproduce --run` deliberately re-measures: a fresh baseline, a
/// freshly resolved destination, the timeout `mutantkit.yml` currently
/// specifies. That is the right tool for "does this mutation still get
/// caught, right now." It is the wrong tool for "what exactly did the
/// original run see" — a resolved destination can differ if the machine's
/// simulator inventory changed, and `reproduce`'s `TimeoutController` never
/// records a baseline at all (see `ReproduceCommand`), so it silently uses
/// the flat ceiling instead of the adaptive limit the original run computed.
/// `RunManifest` is the record that lets `--replay` (see `ReproduceCommand`)
/// close both gaps: the same resolved device, the same effective timeout,
/// the same scheme/targets/arguments, no re-derivation involved.
public struct RunManifest: Codable, Sendable {
    public let planID: String
    public let workUnitID: String
    public let startedAt: Date
    /// The destination this run resolved to, once, at the start — see
    /// `DestinationResolver`. `nil` for a kind with no destination to
    /// resolve (a Swift package on macOS).
    public let resolvedDestination: ResolvedDestination?
    public let scheme: String?
    public let testTargets: [String]
    public let extraTestArguments: [String]
    /// The effective per-mutant timeout this run actually used —
    /// `TimeoutController.mutantLimitSeconds` after the baseline was
    /// measured, not the configured strategy/multiplier a reader would have
    /// to recompute by hand and could get wrong if the baseline duration
    /// were not recorded alongside it.
    public let mutantTimeoutSeconds: Double
    public let baselineTimeoutSeconds: Double
    public let toolchain: ToolchainFingerprint
    public let configurationHash: String
    /// The machine's state when this manifest was written — see
    /// `ResourceSnapshot`. `nil` only if capturing it itself failed.
    public let resourceSnapshot: ResourceSnapshot?
    /// How the run's resolved simulator was prepared, if it has one — see
    /// `SimulatorPreparationRecord`. `nil` on manifests written before this
    /// field existed (decoded as absence), and for runs whose destination was
    /// never a simulator.
    public let simulatorPreparation: SimulatorPreparationRecord?

    public init(
        planID: String,
        workUnitID: String,
        startedAt: Date,
        resolvedDestination: ResolvedDestination?,
        scheme: String?,
        testTargets: [String],
        extraTestArguments: [String],
        mutantTimeoutSeconds: Double,
        baselineTimeoutSeconds: Double,
        toolchain: ToolchainFingerprint,
        configurationHash: String,
        resourceSnapshot: ResourceSnapshot? = nil,
        simulatorPreparation: SimulatorPreparationRecord? = nil
    ) {
        self.planID = planID
        self.workUnitID = workUnitID
        self.startedAt = startedAt
        self.resolvedDestination = resolvedDestination
        self.scheme = scheme
        self.testTargets = testTargets
        self.extraTestArguments = extraTestArguments
        self.mutantTimeoutSeconds = mutantTimeoutSeconds
        self.baselineTimeoutSeconds = baselineTimeoutSeconds
        self.toolchain = toolchain
        self.configurationHash = configurationHash
        self.resourceSnapshot = resourceSnapshot
        self.simulatorPreparation = simulatorPreparation
    }

    /// `.mutantkit/run-manifest-<workUnitID>.json` — one per work unit, like the
    /// checkpoint, overwritten by each fresh run. Unlike the checkpoint, this
    /// is not fingerprinted: a manifest describing a stale run is still
    /// useful evidence of what that run saw, and `--replay` is an explicit,
    /// deliberate request to reproduce exactly that — including if the
    /// environment has since moved on. That is the entire feature.
    public static func url(runDirectory: URL, workUnitID: String) -> URL {
        runDirectory.appendingPathComponent("run-manifest-\(workUnitID).json")
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> RunManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RunManifest.self, from: Data(contentsOf: url))
    }
}
