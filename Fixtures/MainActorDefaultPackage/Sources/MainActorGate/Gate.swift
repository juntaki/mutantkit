/// Main-actor isolated by the target's default isolation — see this
/// fixture's own Package.swift comment.
public enum Gate {
    /// bool-literal-inversion candidate, in main-actor isolated code.
    public static func isOpen() -> Bool {
        true
    }

    /// relational-operator-replacement candidates, off the main actor: a
    /// mutated call site here can only reach a `nonisolated` runtime
    /// function. Tested at 17 and 19, never at the boundary, so `>=` → `>`
    /// survives while `>=` → `<` dies.
    nonisolated public static func isAdult(age: Int) -> Bool {
        age >= 18
    }
}
