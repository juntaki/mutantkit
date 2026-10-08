import Foundation

extension AssertionKillAttribution {
    /// A test identifier split into the parts that decide whether two
    /// spellings name the same test: the path before the method (target,
    /// suites, class), the method name, and its parameter list.
    ///
    /// `Target/Class/method()`, `Class/method` and `Module.Class/method()` are
    /// one test written with different decoration. Nested suites, a method
    /// name shared by two types, and overloads or parameterized variants of
    /// one method are different tests and must not be conflated, because
    /// conflating them credits a kill to a test that was not selected.
    struct TestIdentifier: Equatable {
        let owners: [String]
        let method: String
        /// The text inside the parentheses; empty for `()` and for no list.
        let parameters: String

        init(_ identifier: String) {
            var components = identifier.split(separator: "/", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            var last = components.popLast() ?? identifier
            // A selection built from an identifier that already ended in `()`
            // once carried it twice (`method()()`). Only that exact doubled
            // empty list is read as one; any other list is left alone.
            while last.hasSuffix("()()") { last.removeLast(2) }
            if let open = last.firstIndex(of: "(") {
                method = String(last[..<open])
                var list = String(last[last.index(after: open)...])
                if list.hasSuffix(")") { list.removeLast() }
                parameters = list.trimmingCharacters(in: .whitespaces)
            } else {
                method = last
                parameters = ""
            }
            owners = components
        }

        /// Whether `self` and `other` can only be the same test. Conservative:
        /// any component present on both sides must agree, and an identifier
        /// that cannot be placed (no type at all on one side only) does not
        /// match. Dropping a leading target or suite on one side is tolerated,
        /// since result bundles and selections differ in how much of the path
        /// they spell; a component present on both sides that differs is
        /// never tolerated.
        func names(sameTestAs other: TestIdentifier) -> Bool {
            guard method == other.method, parameters == other.parameters else { return false }
            if owners.isEmpty || other.owners.isEmpty { return owners.isEmpty && other.owners.isEmpty }
            let target = (owners.count > other.owners.count ? owners : other.owners).first
            for (mine, theirs) in zip(owners.reversed(), other.owners.reversed())
                where !Self.sameComponent(mine, theirs, target: target) {
                return false
            }
            return true
        }

        /// Equal, or one carries a module prefix (`App.AddTests`) that the
        /// other lacks and the prefix is the module of the identifier's own
        /// target (`App` for `AppTests`). A dotted prefix that is not a module
        /// of that target may be an enclosing type, which is a different test.
        private static func sameComponent(_ lhs: String, _ rhs: String, target: String?) -> Bool {
            if lhs == rhs { return true }
            for (dotted, plain) in [(lhs, rhs), (rhs, lhs)] {
                guard let dot = dotted.lastIndex(of: "."), String(dotted[dotted.index(after: dot)...]) == plain else { continue }
                let module = String(dotted[..<dot])
                if let target, target == module || target == module + "Tests" { return true }
            }
            return false
        }
    }

    /// Whether `failing` names one of the `selected` tests, unambiguously.
    static func isSelected(_ failing: String, by selected: [TestIdentifier]) -> Bool {
        let identifier = TestIdentifier(failing)
        return selected.contains { identifier.names(sameTestAs: $0) }
    }
}
