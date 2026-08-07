import Foundation
import MutationModel

/// Hands out the wall-clock limits a run is allowed to spend.
///
/// A mutant that deletes a `continuation.resume()` or inverts a loop condition
/// does not fail — it hangs, and nothing in the test runner will end it. These
/// numbers are the only reason the tool always terminates.
///
/// The value is immutable and the baseline is folded in by producing a new one,
/// so the limit a worker reads mid-run cannot be the limit some other worker was
/// in the middle of changing.
public struct TimeoutController: Sendable {
    public let settings: TimeoutSettings
    /// How long the unmutated suite took. `nil` until the baseline has run.
    public let baselineDurationSeconds: Double?

    public init(settings: TimeoutSettings, baselineDurationSeconds: Double? = nil) {
        self.settings = settings
        self.baselineDurationSeconds = baselineDurationSeconds
    }

    /// The same controller with a measured baseline, which is what makes the
    /// adaptive strategy adaptive.
    public func recordingBaseline(durationSeconds: Double) -> TimeoutController {
        TimeoutController(settings: settings, baselineDurationSeconds: durationSeconds)
    }

    public var baselineLimitSeconds: Double { settings.baselineSeconds }

    /// The limit for one mutant's test run.
    public var mutantLimitSeconds: Double {
        // Before the baseline has been measured there is nothing to scale from,
        // so the configured ceiling is the only defensible bound. In practice
        // the runner always has a baseline by the time it asks.
        guard let baselineDurationSeconds else { return settings.mutant.maximumSeconds }
        return settings.mutant.resolve(baselineDuration: baselineDurationSeconds)
    }

    public var terminationGracePeriodSeconds: Double { settings.terminationGracePeriodSeconds }
}
