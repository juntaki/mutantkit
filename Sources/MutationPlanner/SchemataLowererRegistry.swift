import MutationModel
import SwiftCoreOperators
import SwiftFrontend

/// Every `SchemataLowerer` this build knows about, and the checks that make
/// "which lowerer handles this operator" a well-defined question before
/// `SchemataChunkPlanner` ever has to ask it.
///
/// Deferred at S1 (ADR-0003 addendum 1) until a second lowerer existed to
/// make a registry meaningful — this is that moment.
public struct SchemataLowererRegistry: Sendable {
    /// The lowerers compiled into this build — the entire per-operator
    /// schemata scoring gate (see `SchemataChunkPlanner`'s own doc
    /// comment): an operator with no lowerer here always falls back to
    /// isolated mode. `RelationalOperatorReplacementSchemataLowerer`
    /// promoted here after: the `__mkPair<T>` heterogeneous-operand fix,
    /// the multi-process proof-chain fix, and the no-HIT/no-STARTUP
    /// isolated-fallback routing fix, each independently verified against
    /// a real ~116-mutation Expansion run (swift-numerics/IntegerUtilities,
    /// swift-syntax) with isolated/schemata disagreement = 0.
    /// `LogicalConnectorReplacementSchemataLowerer` promoted here after a
    /// workers=5 expansion run showed a verifiedTimeout/flaky disagreement
    /// on one swift-syntax mutation; a workers=2 rerun on the identical
    /// corpus/plan/timeout (swift-numerics 13 mutations, swift-syntax 6
    /// mutations) came back disagreement = 0, attributing the workers=5
    /// failure to CI-runner resource contention, not a lowerer bug.
    /// `UnaryNotRemovalSchemataLowerer` promoted here after a workers=2
    /// expansion run on the same corpus (swift-numerics 2 mutations,
    /// swift-syntax 4 mutations) came back disagreement = 0, integrity
    /// violations = 0, and every candidate discovered/classified/reported —
    /// workers=2 used from the start, having already learned workers=5
    /// produces resource-contention false positives on this corpus.
    /// `ReturnValueReplacementSchemataLowerer` promoted here after a
    /// workers=2 expansion run on the same corpus (swift-numerics 1
    /// mutation, swift-syntax 4 mutations) came back disagreement = 0,
    /// integrity violations = 0, and every candidate discovered/classified/
    /// reported.
    public static let builtIn: [any SchemataLowerer] = [
        BoolLiteralSchemataLowerer(),
        RelationalOperatorReplacementSchemataLowerer(),
        LogicalConnectorReplacementSchemataLowerer(),
        UnaryNotRemovalSchemataLowerer(),
        ReturnValueReplacementSchemataLowerer()
    ]

    public enum RegistrationError: Error, Equatable, CustomStringConvertible {
        /// Two lowerers in the list share a `lowererID` — an entry's own
        /// `SchemataPlanEntry.placement` could not tell them apart.
        case duplicateLowererID(String)
        /// Two lowerers both declare the same operator ID as supported —
        /// which one a chunk plan should route that operator's points to
        /// would be ambiguous, decided by array order rather than a real
        /// rule. Registering the operator with two lowerers is always a
        /// build-time mistake, never a legitimate configuration.
        case ambiguousOperatorRegistration(operatorID: String, first: String, second: String)

        public var description: String {
            switch self {
            case let .duplicateLowererID(id):
                "two lowerers both claim lowererID \(id)"
            case let .ambiguousOperatorRegistration(operatorID, first, second):
                "operator \(operatorID) is claimed by both lowerers \(first) and \(second)"
            }
        }
    }

    private let byOperatorID: [String: any SchemataLowerer]

    public init(lowerers: [any SchemataLowerer] = SchemataLowererRegistry.builtIn) throws {
        var seenLowererIDs: Set<String> = []
        var routing: [String: any SchemataLowerer] = [:]
        for lowerer in lowerers {
            let descriptor = lowerer.descriptor
            guard seenLowererIDs.insert(descriptor.lowererID).inserted else {
                throw RegistrationError.duplicateLowererID(descriptor.lowererID)
            }
            for operatorID in descriptor.supportedOperatorIDs {
                if let existing = routing[operatorID] {
                    throw RegistrationError.ambiguousOperatorRegistration(
                        operatorID: operatorID, first: existing.descriptor.lowererID, second: descriptor.lowererID
                    )
                }
                routing[operatorID] = lowerer
            }
        }
        byOperatorID = routing
    }

    /// The lowerer registered for `operatorID`, `nil` if none is —
    /// `SchemataChunkPlanner` reads a `nil` here as
    /// `.operatorNotYetLowered`, the same isolated-fallback reason
    /// `BoolLiteralSchemataLowerer.analyze` itself returns for a foreign
    /// operator ID.
    public func lowerer(forOperatorID operatorID: String) -> (any SchemataLowerer)? {
        byOperatorID[operatorID]
    }
}
