/// The tests a project is configured to run, as one enumeration proved them, or an explicit statement
/// that it could not.
///
/// Per-test coverage narrows a mutant's test selection to the tests that reached its line. That is only
/// sound when the list the narrowing started from is the whole list: a test the enumeration silently
/// dropped is neither covered nor unattributed, so it can be left out of every selection (a surviving
/// mutant only it would have killed) or leave a line looking unreached. An inventory is therefore either
/// `complete` or `unknown` with the reason, and every consumer treats `unknown` as "no attribution
/// possible": the coverage-blind, run-the-whole-suite behaviour. There is no partial inventory.
public enum TestInventory: Sendable, Equatable {
    /// Every entry the enumeration produced was recognised, its output was captured in full, and
    /// (when targets are configured) each configured target contributed at least one test.
    case complete(Set<TestIdentifier>)
    /// The enumeration could not be proven complete. Never an empty `complete`.
    case unknown(Reason)

    public enum Reason: Sendable, Equatable {
        /// The enumerating process did not launch, timed out, or exited unsuccessfully.
        case enumerationFailed(String)
        /// The process ran but its captured output is not whole (`ProcessResult.outputComplete == false`).
        case outputTruncated
        /// The document as a whole could not be read.
        case malformedDocument
        /// Some entries were not recognised; `sample` is the first, for the diagnosis.
        case unrecognizedEntries(count: Int, sample: String)
        /// The enumeration was readable and recognised nothing.
        case noTests
        /// Configured test targets that contributed no test, so the enumeration does not cover the
        /// configured universe.
        case configuredTargetsMissing([String])
    }

    /// The proven test set, or `nil` for `unknown`.
    public var tests: Set<TestIdentifier>? {
        if case let .complete(tests) = self { return tests }
        return nil
    }

    /// Why the inventory is unknown, or `nil` for `complete`.
    public var unknownReason: Reason? {
        if case let .unknown(reason) = self { return reason }
        return nil
    }

    /// Restricts a complete inventory to the configured targets (empty = no restriction configured) and
    /// requires each configured target to be present: a configured target with no enumerated test means
    /// the enumeration missed it (or the configuration names a target that does not exist), and either
    /// way narrowing on the rest would be a claim about a universe that was not enumerated.
    public func reconciled(withConfiguredTargets configured: [String]) -> TestInventory {
        guard case let .complete(tests) = self, !configured.isEmpty else { return self }
        let allowed = Set(configured)
        let scoped = tests.filter { allowed.contains($0.target) }
        let missing = configured.filter { target in !scoped.contains { $0.target == target } }
        if !missing.isEmpty { return .unknown(.configuredTargetsMissing(Array(Set(missing)).sorted())) }
        return .complete(scoped)
    }

    /// Builds an inventory from recognised tests and the entries that were not.
    public static func make(recognized: [TestIdentifier], unrecognized: [String]) -> TestInventory {
        if let first = unrecognized.first {
            return .unknown(.unrecognizedEntries(count: unrecognized.count, sample: first))
        }
        return recognized.isEmpty ? .unknown(.noTests) : .complete(Set(recognized))
    }

    /// Classifies a finished enumeration process before its output is parsed.
    public static func gate(_ result: ProcessResult) -> Reason? {
        if result.timedOut { return .enumerationFailed("timed out") }
        guard result.succeeded else { return .enumerationFailed("did not succeed") }
        guard result.outputComplete else { return .outputTruncated }
        return nil
    }
}
