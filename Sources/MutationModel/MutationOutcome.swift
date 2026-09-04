
/// What happened to one mutant.
///
/// Deliberately not collapsed into pass/fail. Most of the damage a mutation
/// tool does comes from folding an *unknown* into `survived`: a mutation that
/// never reached the source, a build that never happened, or a test harness that
/// fell over all look like "the tests didn't catch it" if you only track a
/// boolean. Each of those is its own case here, and only two of them are allowed
/// near the score's denominator.
public enum MutationOutcome: String, Codable, Sendable, CaseIterable {
    /// A test assertion failed. The mutation was caught.
    case killedByAssertion
    /// The process crashed, trapped, or exited non-zero outside an assertion.
    case killedByCrash
    /// Timed out, then timed out again the same way in an independent, fresh
    /// rebuild. A mutation-testing project found — the hard way — that a
    /// mutant's crash-vs-hang manifestation is not stable across execution
    /// context (a concurrent worker pool vs. running alone) or even across
    /// otherwise-identical machines, but *whether it is caught at all* was
    /// stable across every condition tried. This is the timeout side of that:
    /// a hang reproducible on demand is exactly as much a real kill as a
    /// crash confirmed the same way, so it counts as one. See `.timedOut`
    /// and `confirmTimedOutMutants`.
    case verifiedTimeout
    /// Tests ran, covered the code, and all passed. A real gap.
    case survived
    /// Tests ran and passed, but nothing executed the mutated line.
    case noCoverage
    /// The mutant did not compile. Not a test-quality signal.
    case unviable
    /// Exceeded the timeout, unconfirmed. Often an infinite loop the mutation
    /// introduced; not evidence about the test suite either way until an
    /// independent rebuild either reproduces it (`.verifiedTimeout`) or
    /// doesn't (`.flaky`/`.infrastructureFailure`). Reachable as a terminal
    /// state only when `confirmTimedOutMutants` is off.
    case timedOut
    /// Repeated runs disagreed. Excluded until it stabilizes.
    case flaky
    /// The anchor did not match, so no edit was made. The case that must never
    /// be laundered into `survived`.
    case notApplied
    /// The unmutated baseline did not behave as recorded. Nothing downstream is trustworthy.
    case baselineMismatch
    /// Simulator, toolchain, or disk failure. Our problem, not the suite's.
    case infrastructureFailure
    /// Excluded by budget, profile, or configuration before execution.
    case skipped

    /// Whether the suite caught the mutation at all — independent of *how*.
    ///
    /// This is the axis a mutation score is allowed to depend on.
    /// `.manifestation` is the axis it is not: a project found, empirically,
    /// that the same mutant on the same commit can report `killedByCrash` on
    /// one machine and `killedByAssertion` on another, or `killedByCrash`
    /// then `.timedOut` on back-to-back runs of the same machine — while
    /// never once reporting `.survived`. A score that moved with
    /// manifestation would be measuring the environment, not the test suite.
    public enum Detection: String, Codable, Sendable {
        /// The suite caught it, however it happened to show up.
        case detected
        /// The suite ran, covered the mutation, and did not catch it.
        case survived
        /// Neither proven: a build/infra problem, a plan/integrity issue, an
        /// unconfirmed timeout, or a result excluded before it could be
        /// scored either way.
        case indeterminate
    }

    /// How a detected (or not-yet-resolved) mutation showed up. Diagnostic —
    /// never an input to scoring. See `Detection`.
    public enum Manifestation: String, Codable, Sendable {
        case assertionFailure
        case crash
        case verifiedTimeout
        case flakyFailure
        case infrastructureFailure
    }

    /// The scoring-relevant classification. See `Detection`.
    public var detection: Detection {
        switch self {
        case .killedByAssertion, .killedByCrash, .verifiedTimeout: .detected
        case .survived: .survived
        case .noCoverage, .unviable, .timedOut, .flaky, .notApplied, .baselineMismatch, .infrastructureFailure, .skipped:
            .indeterminate
        }
    }

    /// The diagnostic-only classification. `nil` where no manifestation
    /// applies (`.survived`, `.noCoverage`, an unconfirmed `.timedOut`, etc).
    /// See `Manifestation`.
    public var manifestation: Manifestation? {
        switch self {
        case .killedByAssertion: .assertionFailure
        case .killedByCrash: .crash
        case .verifiedTimeout: .verifiedTimeout
        case .flaky: .flakyFailure
        case .infrastructureFailure: .infrastructureFailure
        case .survived, .noCoverage, .unviable, .timedOut, .notApplied, .baselineMismatch, .skipped: nil
        }
    }

    /// Killed mutants: numerator of both scores. Equivalent to
    /// `detection == .detected`; kept as its own property because it predates
    /// `Detection` and is the more familiar name at most call sites.
    public var isKilled: Bool { detection == .detected }

    /// Outcomes that say something about test quality and therefore belong in a
    /// denominator. Everything else is a fact about the *tool run*, not the suite.
    public var isScorable: Bool {
        switch detection {
        case .detected, .survived: true
        case .indeterminate: self == .noCoverage
        }
    }

    /// Outcomes that mean the run itself is broken, not merely inconclusive.
    /// Any of these forces a fail-closed result with no score.
    public var isIntegrityViolation: Bool {
        switch self {
        case .notApplied, .baselineMismatch: true
        default: false
        }
    }

    /// Whether reaching this outcome required a test to actually run, as
    /// opposed to being decided before or without one (no coverage, a build
    /// failure, an anchor that never applied, an environment problem).
    ///
    /// Deliberately independent of `MutationResult.testSummary`: some test
    /// adapters (serial SwiftPM execution in particular) can produce a real
    /// pass/fail signal used to reach one of these outcomes without also
    /// producing a per-test summary. Counting `executed` from `testSummary`
    /// alone would undercount — a mutant that was genuinely tested would be
    /// reported as if it never ran.
    public var impliesTestWasExecuted: Bool {
        switch self {
        case .killedByAssertion, .killedByCrash, .verifiedTimeout, .survived, .timedOut, .flaky:
            true
        case .noCoverage, .unviable, .notApplied, .baselineMismatch, .infrastructureFailure, .skipped:
            false
        }
    }

    /// Outcomes safe to reuse across runs from the cross-run result cache.
    ///
    /// An allow-list, not a deny-list: caching is opt-in for the verdicts
    /// that are a definitive, environment-independent statement about the
    /// tests, and everything else is left out. `.flaky` and an unconfirmed
    /// `.timedOut` are exactly the cases that look like a real verdict but
    /// move with the environment, so they are never cached even though the
    /// old deny-list happily stored them. `.unviable`, `.notApplied`,
    /// `.baselineMismatch`, `.infrastructureFailure` and `.skipped` are
    /// facts about this run or this plan, not about the suite, so they are
    /// out too. What remains is what a re-run on an identical tree is
    /// expected to reproduce:
    /// `.survived`, `.noCoverage`, `.killedByAssertion`, `.killedByCrash`
    /// (a crash confirmed, or observed when crash confirmation is off and a
    /// single crash is by config a trusted kill), and `.verifiedTimeout`.
    public var isCacheableResult: Bool {
        switch self {
        case .survived, .noCoverage, .killedByAssertion, .killedByCrash, .verifiedTimeout:
            true
        case .unviable, .timedOut, .flaky, .notApplied, .baselineMismatch,
             .infrastructureFailure, .skipped:
            false
        }
    }

    public var displayName: String {
        switch self {
        case .killedByAssertion: "killed (assertion)"
        case .killedByCrash: "killed (crash)"
        case .verifiedTimeout: "killed (verified timeout)"
        case .survived: "survived"
        case .noCoverage: "no coverage"
        case .unviable: "unviable"
        case .timedOut: "timed out"
        case .flaky: "flaky"
        case .notApplied: "not applied"
        case .baselineMismatch: "baseline mismatch"
        case .infrastructureFailure: "infrastructure failure"
        case .skipped: "skipped"
        }
    }
}

// MARK: - Scores

/// The two scores, kept separate because they answer different questions.
///
/// `tested` answers "of the code my tests actually run, how much do they check?"
/// `effective` answers "of the code I asked to be mutated, how much is checked?"
/// Reporting only one of these is how a suite with poor coverage comes to look
/// excellent.
public struct MutationScore: Codable, Sendable, Hashable {
    public let killed: Int
    public let survived: Int
    public let noCoverage: Int
    /// Counted and displayed, never in a denominator.
    public let excluded: [String: Int]

    public init(killed: Int, survived: Int, noCoverage: Int, excluded: [String: Int]) {
        self.killed = killed
        self.survived = survived
        self.noCoverage = noCoverage
        self.excluded = excluded
    }

    /// killed / (killed + survived) — nil rather than 0 when nothing was tested,
    /// because "no data" and "everything survived" are different findings.
    public var tested: Double? {
        let denominator = killed + survived
        guard denominator > 0 else { return nil }
        return Double(killed) / Double(denominator)
    }

    /// killed / (killed + survived + noCoverage)
    public var effective: Double? {
        let denominator = killed + survived + noCoverage
        guard denominator > 0 else { return nil }
        return Double(killed) / Double(denominator)
    }

    /// Tallies by `Detection`, not by an enumerated case list — so a new
    /// manifestation of an already-detected mutant (a new confirmed-crash or
    /// confirmed-timeout variant, say) counts as killed by construction,
    /// rather than by remembering to add it here too.
    public static func tally(_ outcomes: [MutationOutcome]) -> MutationScore {
        var killed = 0, survived = 0, noCoverage = 0
        var excluded: [String: Int] = [:]

        for outcome in outcomes {
            switch outcome.detection {
            case .detected: killed += 1
            case .survived: survived += 1
            case .indeterminate:
                if outcome == .noCoverage {
                    noCoverage += 1
                } else {
                    excluded[outcome.rawValue, default: 0] += 1
                }
            }
        }

        return MutationScore(killed: killed, survived: survived, noCoverage: noCoverage, excluded: excluded)
    }
}
