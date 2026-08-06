import Foundation

/// One function per new core operator (PR #6), each with a single,
/// deliberately-placed mutation site. The expected outcomes are asserted by
/// `CoreOperatorExpansionAcceptanceTests`, which runs the real MutantKit CLI
/// against this package -- changing this file changes that expectation.
public enum Ops {
    /// `swift.core.ternary-branch-swap`. Tested at both outcomes, so the
    /// swapped-branches mutant fails at least one assertion.
    public static func label(forScore score: Int) -> String {
        score >= 60 ? "pass" : "fail"
    }

    /// `swift.core.unary-not-removal`. Tested at both a `true` and `false`
    /// input, so the mutant that drops the negation fails one assertion.
    public static func isInactive(_ active: Bool) -> Bool {
        !active
    }

    /// `swift.core.nil-coalescing-fallback`. Tested with a non-nil name --
    /// exactly the case the mutant (which forces the fallback
    /// unconditionally) cannot pass.
    public static func displayName(_ name: String?) -> String {
        name ?? "Anonymous"
    }

    /// `swift.core.return-value-replacement`. `return 0` is already the
    /// neutral value and is not a mutation site; `return 100` is the one
    /// candidate, mutated to `return 0`.
    public static func bonus(forTier tier: Int) -> Int {
        if tier == 3 {
            return 100
        }
        return 0
    }

    /// `swift.core.arithmetic-operator-replacement` (experimental only).
    /// Plain `Int` arithmetic: the `+` -> `-` mutant type-checks and builds
    /// fine, so this mutant reaches a real kill/survive verdict.
    public static func sum(_ a: Int, _ b: Int) -> Int {
        a + b
    }

    /// `swift.core.arithmetic-operator-replacement` (experimental only). A
    /// generic `Numeric` bound has no `/`, so mutating `*` to `/` does not
    /// type-check -- a genuine build failure from the full pipeline,
    /// corroborating `CoreOperatorCompileViabilityAcceptanceTests`'s
    /// isolated `swiftc -typecheck` finding with an actual `mutantkit run`.
    public static func scale<T: Numeric>(_ value: T, by factor: T) -> T {
        value * factor
    }

    /// `swift.core.assignment-operator-replacement` (experimental only).
    /// Plain `Int` compound assignment: the `+=` -> `-=` mutant type-checks
    /// and builds fine.
    public static func accumulate(_ total: inout Int, by delta: Int) {
        total += delta
    }

    /// `swift.core.else-clause-deletion` (experimental only). The `if`/`else`
    /// is not the last statement of the function (an explicit `return`
    /// follows), so it is a safe position. Both branches append an entry
    /// regardless of outcome, so deleting `else` leaves `notes` missing its
    /// entry on the invalid path -- a real difference from "nothing
    /// happened", not an equivalent mutant. Uses a `Bool` parameter rather
    /// than a comparison so this site is not incidentally also a
    /// `relational-operator-replacement` candidate.
    public static func validate(_ isValid: Bool, notes: inout [String]) -> Bool {
        if isValid {
            notes.append("ok")
        } else {
            notes.append("warning")
        }
        return isValid
    }

    /// `swift.core.range-boundary-replacement` (experimental only). `Array`'s
    /// generic `Sequence` initializer accepts `Range<Int>` and
    /// `ClosedRange<Int>` equally, so both `Array(0..<count)` and the
    /// mutant's `Array(0...count)` type-check and build -- no crash, just a
    /// different (and testably wrong) element count, since including `count`
    /// itself adds one more element. Uses `.count` rather than an
    /// accumulating loop so this site is not incidentally also an
    /// `assignment-operator-replacement` candidate.
    public static func elementCount(upTo count: Int) -> Int {
        Array(0..<count).count
    }
}
