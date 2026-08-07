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
    /// The lowerers compiled into this build. Only one exists today; the
    /// list is where a future operator's lowerer gets wired in, the same
    /// role `MutationRegistry.builtIn` plays for `MutationOperator`s.
    public static let builtIn: [any SchemataLowerer] = [
        BoolLiteralSchemataLowerer(),
        // TEMPORARY, this branch only — never merged to main. Registered
        // here purely so `smoke/relational-schemata-measurement`'s CI
        // workflow can run a real `execution.strategy: schemata` comparison
        // against real external projects. The real promotion commit (a
        // separate, small, reviewed change) is what actually adds this line
        // for good, once real measurement here justifies it.
        RelationalOperatorReplacementSchemataLowerer()
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
