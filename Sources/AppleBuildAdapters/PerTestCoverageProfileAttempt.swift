import MutationExecution

/// The result of attempting an authoritative per-test coverage profile.
///
/// A fast profiler must either provide the complete map or decline so the
/// serial reference profiler can produce it. Partial attribution is never a
/// representable result.
enum PerTestCoverageProfileAttempt: Sendable {
    case complete(PerTestCoverageMap)
    case unavailable(reason: String)
}
