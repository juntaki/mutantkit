import Foundation

/// A run's record of how the simulator it tests on was prepared — carried in
/// the `RunManifest`, so `--replay` and post-hoc inspection can see not just
/// *which* device a run used but whether it was warm, cold, or never verified.
///
/// Lives in the model layer rather than `AppleBuildAdapters` because the run
/// manifest and the `ProjectAdapter` protocol (both lower-level than the Apple
/// adapters) need to reference it: the adapter produces it, the manifest
/// persists it, and neither should depend on the other's module for a plain
/// Codable record.
///
/// The previous design called `prepareSimulatorForRun()` for its side effect
/// and dropped the result with `try?`, so a device that silently failed
/// readiness was indistinguishable from a warm one in every record the run
/// left behind.
public struct SimulatorPreparationRecord: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, Sendable {
        /// No simulator destination to prepare (macOS host, package without a
        /// resolved simulator device).
        case notApplicable
        /// Device was already booted; `bootstatus` confirmed ready.
        case alreadyBooted
        /// Device was booted and verified ready this run.
        case prepared
        /// `bootstatus` could not confirm readiness. Under MutantKit's
        /// fail-closed policy a run whose resolved simulator lands here stops
        /// before the baseline rather than surfacing the failure mid-run as a
        /// stream of `.infrastructureFailure` verdicts.
        case failed
    }

    public let outcome: Outcome
    public let udid: String?
    public let name: String?
    /// Readiness detail: the failure reason when `outcome == .failed`, `nil`
    /// otherwise.
    public let detail: String?

    public init(outcome: Outcome, udid: String? = nil, name: String? = nil, detail: String? = nil) {
        self.outcome = outcome
        self.udid = udid
        self.name = name
        self.detail = detail
    }
}
