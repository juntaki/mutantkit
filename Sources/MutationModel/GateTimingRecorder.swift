import Foundation

/// Records phase-level timing spans during a run — Gate 3 diagnostic
/// instrumentation (`Research/benchmarks/gate3-ios-schemata-2026-08-23`),
/// added to fully account for a schemata-vs-isolated wall-clock gap that
/// two prior hypotheses (chunk-build cost, missing token test-batching)
/// were checked against and found not to dominate. Not a permanent
/// feature: every call site recording a span is a cheap actor-isolated
/// array append, never worth removing on its own, but nothing reads
/// `shared`'s snapshot unless a caller explicitly asks for it (see
/// `RunCommand`'s `MUTANTKIT_GATE3_TIMING_OUTPUT` env var) — every other
/// run pays a negligible, unobserved cost.
///
/// A monotonic `ContinuousClock`, not `Date`: wall-clock time can jump
/// (NTP adjustment, sleep/wake) in ways a diagnostic meant to reconstruct
/// exactly where ~1195 real seconds went must not be vulnerable to.
public actor GateTimingRecorder {
    public struct Span: Codable, Sendable {
        public let name: String
        public let startOffsetSeconds: Double
        public let durationSeconds: Double
        public let chunkID: String?
        public let mutationID: String?
    }

    /// One recorder for the whole process — spans from every layer
    /// (`SchemataRunOrchestration`, `SchemataMutationRunner`,
    /// `XcodeBuildAdapter`, `XcodeTargetResolver`) land in the same
    /// timeline, keyed by a shared origin, without threading a recorder
    /// instance through every intervening call site or protocol
    /// conformance (`SchemataBuildable`/`SchemataTestable` — implemented by
    /// more than one adapter, and by test doubles this instrumentation must
    /// not have to touch).
    public static let shared = GateTimingRecorder()

    /// `nonisolated let`, deliberately: both are immutable, `Sendable`
    /// value types, so reading them never needs to hop onto this actor's
    /// executor — required for `now()` below to stay synchronous and
    /// genuinely free of scheduling skew.
    private nonisolated let clock: ContinuousClock
    private nonisolated let origin: ContinuousClock.Instant
    private var spans: [Span] = []

    public init() {
        let clock = ContinuousClock()
        self.clock = clock
        origin = clock.now
    }

    /// The instant a caller should capture *before* the work it wants
    /// timed, then pass back into `record(_:chunkID:mutationID:start:)`
    /// once that work finishes. `nonisolated` and synchronous on purpose:
    /// capturing "now" must never hop onto this actor's executor first,
    /// which would itself skew the very timing being measured.
    public nonisolated func now() -> ContinuousClock.Instant { clock.now }

    /// Records one span running from `start` to now (or to `end`, when a
    /// caller captured it separately — e.g. to record a span that failed,
    /// where the caller already has an `end` from a `catch` block).
    public func record(_ name: String, chunkID: String? = nil, mutationID: String? = nil, start: ContinuousClock.Instant, end: ContinuousClock.Instant? = nil) {
        let finish = end ?? clock.now
        spans.append(Span(
            name: name,
            startOffsetSeconds: origin.duration(to: start).doubleSeconds,
            durationSeconds: start.duration(to: finish).doubleSeconds,
            chunkID: chunkID,
            mutationID: mutationID
        ))
    }

    /// Every span recorded so far, in recording order — not sorted by
    /// `startOffsetSeconds`, since concurrent spans (a future
    /// `execution.workers > 1` run) would otherwise interleave in a way
    /// that hides which spans genuinely overlapped versus which merely
    /// happened to record close together.
    public func snapshot() -> [Span] { spans }

    /// Writes `snapshot()` to `path` as pretty-printed, sorted-key JSON —
    /// deterministic byte output for the same span set, easier to diff
    /// across re-runs.
    public func write(to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(spans).write(to: path, options: .atomic)
    }
}

extension Duration {
    /// `Duration` has no built-in `Double` conversion — its own
    /// `components` (whole seconds + attoseconds) is the only lossless
    /// representation, so this reassembles a `Double` from those rather
    /// than going through `TimeInterval` conversions this SDK does not
    /// expose for `Duration` directly.
    var doubleSeconds: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
