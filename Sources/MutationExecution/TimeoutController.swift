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

    /// The limit for one mutant's test run. Test *selection* is unaffected —
    /// callers still run only `selectedTests` when they have a known,
    /// non-empty set — this only decides how long that run is allowed to
    /// take, and for now always answers with the whole-suite-scaled
    /// `mutantLimitSeconds`, the same number every mutant gets regardless of
    /// selection width.
    ///
    /// A `10...30` second, `selectedTests.count`-scaled clamp lived here
    /// previously — the intent being that a confirmed hang held by only a
    /// handful of selected tests should cost far less than the whole-suite
    /// number before it is declared hung. Measured against a real, large
    /// production iOS app's run, it proved uncalibrated for
    /// Xcode/Simulator's fixed per-invocation overhead: a 129-test
    /// selection and an 8-test selection both hit the same 30s ceiling
    /// and were killed and misclassified `verifiedTimeout`, even though
    /// the 129-test case alone needs ~100s (this project's whole suite
    /// takes ~100s) and the 8-test case's true cost was never
    /// distinguished from a real hang. `count * 5` does not model that
    /// fixed overhead, and the 30s ceiling saturates for any selection
    /// past 6 tests regardless of how much larger it gets — not a value
    /// to bump (30 → 120 would not have saved the 129-test case either),
    /// a model to replace. Reverting to the safe, whole-suite number
    /// here — the same fallback this function already used for
    /// `nil`/empty selections — until a properly calibrated replacement
    /// exists.
    public func mutantLimitSeconds(selectedTests _: Set<TestIdentifier>?) -> Double {
        mutantLimitSeconds
    }

    public var terminationGracePeriodSeconds: Double { settings.terminationGracePeriodSeconds }
}
