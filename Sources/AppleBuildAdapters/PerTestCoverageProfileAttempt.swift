import MutationExecution

/// The result of attempting an authoritative per-test coverage profile.
///
/// A fast profiler must either provide the complete map or decline so the
/// serial reference profiler can produce it. Partial attribution is never a
/// representable result.
enum PerTestCoverageProfileAttempt: Sendable {
    case complete(PerTestCoverageMap)
    case unavailable(reason: String)

    /// The fast-then-serial fallback both adapters implement
    /// `TestSelecting.measurePerTestCoverage` as: take the fast profiler's
    /// map when it has one, otherwise fall back to the serial reference
    /// profiler.
    ///
    /// Written once rather than per adapter because the order is the
    /// contract this type's own doc comment states — a fast profiler may
    /// decline, but must never be allowed to answer with less than the
    /// complete map. An adapter that inlined the fallback itself could
    /// quietly stop honouring that, and the two adapters could stop
    /// honouring it differently.
    static func resolve(
        fast: () async -> PerTestCoverageProfileAttempt,
        serial: () async -> PerTestCoverageMap?
    ) async -> PerTestCoverageMap? {
        switch await fast() {
        case let .complete(map): map
        case .unavailable: await serial()
        }
    }
}
