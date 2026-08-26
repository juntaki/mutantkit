import Foundation

/// Phase B3.6 (rigorous-benchmark program): a permanent guard against the
/// exact failure mode this program found empirically in Phase B3 —
/// swift-mutation-testing's own `--sources-path` silently discovering zero
/// mutants when given a file instead of a directory, with no error at all
/// (`SwiftMutationTestingBenchmarkTool`, fixed in commit `10cd0a3`). That
/// was caught only because the resulting "0 discovered, fast wall time" was
/// investigated by hand rather than accepted at face value.
///
/// Extends `BenchmarkGate`'s own Phase C13 principle — "a wrong answer must
/// never look like a fast win" — to the raw-throughput lane specifically: a
/// run that exited cleanly and reported zero mutants for a non-trivially
/// scoped project is never a real, fast, successful throughput number. It
/// is invalid until a fixture explicitly says zero was expected.
public enum BenchmarkValidityGuard {
    /// - Parameters:
    ///   - tool: the tool name, for the violation's own message only.
    ///   - toolExitedSuccessfully: the process exited cleanly (`exitCode ==
    ///     0`) and was not killed by a forced timeout — a crash or timeout
    ///     is a real, different, already-visible failure mode
    ///     (`ToolExecutionResult.timedOut`/non-zero `exitCode`), not this
    ///     guard's concern.
    ///   - requestedScopeIsNonEmpty: this invocation asked the tool to
    ///     consider at least one real source file/pattern. A genuinely
    ///     scopeless invocation (no scope requested at all) is not this
    ///     guard's concern — there is nothing to have silently missed.
    ///   - discoveredCount: how many mutants this specific run's own
    ///     normalized report actually contains.
    ///   - zeroMutantsExpected: `true` only when a fixture/corpus
    ///     explicitly documents that this exact (project, scope)
    ///     combination is expected to yield no mutants (e.g. a
    ///     deliberately mutation-free file) — never inferred, always
    ///     stated by the caller who built that fixture.
    public static func validate(
        tool: String, toolExitedSuccessfully: Bool, requestedScopeIsNonEmpty: Bool,
        discoveredCount: Int, zeroMutantsExpected: Bool
    ) -> BenchmarkViolation? {
        guard requestedScopeIsNonEmpty, toolExitedSuccessfully, discoveredCount == 0, !zeroMutantsExpected else {
            return nil
        }
        return BenchmarkViolation(
            "\(tool): exited successfully but discovered 0 mutants for a non-empty requested scope — "
                + "this run is invalid, not a fast result. A wrong/empty answer must never be reported as "
                + "a real throughput number; check the adapter's own scope-passing flags (e.g. file-vs-"
                + "directory arguments) before trusting any timing from this run."
        )
    }
}
