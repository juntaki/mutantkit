import Foundation

public enum Spin {
    /// Returns immediately — but only because `ready` defaults to `true`.
    ///
    /// Inverting that literal makes `!ready` permanently true and the loop never
    /// exits. The mutation is deliberate and its outcome is asserted: the tool has
    /// to notice, bound it, and kill everything it started.
    ///
    /// A default argument rather than a `let` inside the body, so the compiler has
    /// no constant to fold and no always-false condition to warn about — the
    /// fixture must hang at runtime, not be optimized into terminating.
    public static func settle(ready: Bool = true) -> Int {
        var spins = 0
        while !ready {
            // Wrapping, so the hang is a hang. A trapping overflow would end the
            // process on its own after a few hundred years of CPU time, but more
            // importantly it would make the mutant's fate depend on arithmetic
            // rather than on the supervisor doing its job.
            spins &+= 1
        }
        return spins
    }

    /// Boundary-tested, so its mutants die quickly. Present as a control: if the
    /// hanging mutant took the whole run down with it, these would not be
    /// classified at all.
    public static func isPositive(_ number: Int) -> Bool {
        number > 0
    }
}
