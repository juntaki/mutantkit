/// One candidate per default-enabled, schemata-eligible operator — see
/// this fixture's own Package.swift comment. Every function here is
/// exercised by a dedicated test that kills every mutant a schemata run
/// could produce from it.
public enum MatrixWidget {
    /// bool-literal-inversion candidate.
    public static func isFeatureEnabled() -> Bool {
        true
    }

    /// relational-operator-replacement candidate.
    public static func isAdult(age: Int) -> Bool {
        age >= 18
    }

    /// logical-connector-replacement candidate.
    public static func bothRequired(a: Bool, b: Bool) -> Bool {
        a && b
    }

    /// unary-not-removal candidate.
    public static func isInvalid(flag: Bool) -> Bool {
        !flag
    }

    /// return-value-replacement candidate.
    public static func greeting() -> String {
        "hello"
    }

    /// ternary-branch-swap candidate.
    public static func label(flag: Bool) -> String {
        flag ? "yes" : "no"
    }
}
