import Foundation
import MutationModel
import SwiftCoreOperators
import SwiftFrontend

// ApplePlatformOperators is deliberately not imported here. The module does
// ship a type — LifecycleSuperCallRemovalOperator — but it is not registered:
// it has no RED tests proving its discovery logic, and its own doc comment
// explains why it must not be reachable until the fault study behind it is
// done. See that type's doc comment before registering it.

/// Every operator the tool knows about, and the rules for turning
/// `OperatorSettings` into the set that will actually run.
///
/// The registry is the only place that decides what "enabled" means. Discovery
/// receives a resolved list and asks no questions, so an operator can never
/// enable itself.
public struct MutationRegistry: Sendable {
    /// The operators compiled into this build, in a stable order.
    ///
    /// Adding an operator here is the entire wiring cost: the profile gate, the
    /// plan's descriptor list and `inspect` all read from this one array.
    public static let builtIn: [any MutationOperator] = [
        BoolLiteralInversionOperator(),
        LogicalConnectorReplacementOperator(),
        RelationalOperatorReplacementOperator(),
        TernaryBranchSwapOperator(),
        UnaryNotRemovalOperator(),
        ArithmeticOperatorReplacementOperator(),
        AssignmentOperatorReplacementOperator(),
        NilCoalescingFallbackOperator(),
        ReturnValueReplacementOperator(),
        ElseClauseDeletionOperator(),
        RangeBoundaryReplacementOperator(),
        SideEffectCallRemovalOperator()
    ]

    /// The outcome of applying settings to the registry.
    public struct Resolution: Sendable {
        /// Sorted by operator ID, so discovery order never depends on how the
        /// registry was constructed.
        public let enabledOperators: [any MutationOperator]
        /// Descriptors of `enabledOperators`, for embedding in the plan.
        public let descriptors: [OperatorDescriptor]
        public let profile: OperatorProfile
        /// Operators named in `enable`, which the profile's confidence floor
        /// does not apply to.
        public let explicitlyEnabledOperatorIDs: Set<String>

        public init(
            enabledOperators: [any MutationOperator],
            descriptors: [OperatorDescriptor],
            profile: OperatorProfile,
            explicitlyEnabledOperatorIDs: Set<String>
        ) {
            self.enabledOperators = enabledOperators
            self.descriptors = descriptors
            self.profile = profile
            self.explicitlyEnabledOperatorIDs = explicitlyEnabledOperatorIDs
        }
    }

    private let ordered: [any MutationOperator]

    /// The canonical schemata-support answer, derived directly from
    /// `SchemataLowererRegistry.builtIn` rather than from any operator's own
    /// declared `descriptor.schemataEligible` literal — see
    /// `effectiveDescriptor(for:)` and `OperatorDescriptor.schemataEligible`'s
    /// own doc comment for why a second, hand-maintained copy of this fact
    /// must never exist. Reads the lowerers' own `supportedOperatorIDs`
    /// directly rather than constructing a full `SchemataLowererRegistry`
    /// (whose own `init` also validates no two lowerers claim the same
    /// operator or `lowererID` — a real invariant, but one a display/
    /// serialization fact has no need to re-validate on every call; see
    /// `MutationRegistryTests`'s own "Schemata eligibility" section for the
    /// test that keeps that invariant checked anyway).
    private static let schemataSupportedOperatorIDs: Set<String> = Set(
        SchemataLowererRegistry.builtIn.flatMap(\.descriptor.supportedOperatorIDs)
    )

    /// The descriptor `MutationRegistry` actually hands to every external
    /// consumer (`allDescriptors`, `resolve(_:).descriptors`, and therefore
    /// every `MutationPlan`) — `candidate.descriptor` with
    /// `schemataEligible` overwritten by the real
    /// `SchemataLowererRegistry`-derived answer, never the operator's own
    /// declared literal.
    private static func effectiveDescriptor(for candidate: any MutationOperator) -> OperatorDescriptor {
        candidate.descriptor.withSchemataEligible(
            schemataSupportedOperatorIDs.contains(candidate.descriptor.id)
        )
    }

    public init(operators: [any MutationOperator] = MutationRegistry.builtIn) {
        var seen: Set<String> = []
        for candidate in operators {
            let id = candidate.descriptor.id
            precondition(seen.insert(id).inserted, "Two operators claim the ID '\(id)'.")
        }
        ordered = operators.sorted { $0.descriptor.id < $1.descriptor.id }
    }

    /// Every known operator's descriptor, enabled or not. What `inspect` lists.
    public var allDescriptors: [OperatorDescriptor] {
        ordered.map { Self.effectiveDescriptor(for: $0) }
    }

    public func `operator`(withID id: String) -> (any MutationOperator)? {
        ordered.first { $0.descriptor.id == id }
    }

    /// Resolves the enabled operator set.
    ///
    /// Precedence, strongest last:
    /// 1. the profile admits a starting set (`OperatorProfile.admits`);
    /// 2. `enable` adds operators the profile rejected;
    /// 3. `disable` removes operators, and always wins — naming an operator in
    ///    both lists disables it, because the cost of accidentally running an
    ///    operator someone tried to turn off is higher than the reverse.
    ///
    /// An unknown ID in either list is an error rather than a no-op: a typo in
    /// `disable` would otherwise be discovered as a surprising bill an hour into
    /// a run.
    public func resolve(_ settings: OperatorSettings) throws -> Resolution {
        let known = Set(ordered.map { $0.descriptor.id })
        for id in settings.enable + settings.disable where !known.contains(id) {
            throw PlannerError.unknownOperator(id: id, known: known.sorted())
        }

        for id in settings.enable {
            guard let candidate = self.operator(withID: id) else { continue }
            if candidate.descriptor.requiresSymbolResolution {
                throw PlannerError.operatorRequiresSymbolResolution(id: id)
            }
        }

        var enabled: Set<String> = []
        for candidate in ordered {
            let descriptor = candidate.descriptor
            // An operator that needs type or symbol information cannot get it
            // from syntax alone, so no profile — not even `experimental` — may
            // switch it on by itself.
            guard !descriptor.requiresSymbolResolution else { continue }
            if settings.profile.admits(descriptor) { enabled.insert(descriptor.id) }
        }
        enabled.formUnion(settings.enable)
        enabled.subtract(settings.disable)

        let selected = ordered.filter { enabled.contains($0.descriptor.id) }

        return Resolution(
            enabledOperators: selected,
            descriptors: selected.map { Self.effectiveDescriptor(for: $0) },
            profile: settings.profile,
            explicitlyEnabledOperatorIDs: Set(settings.enable).subtracting(settings.disable)
        )
    }
}

public extension OperatorProfile {
    /// The confidence a single mutation site must reach for this profile to run
    /// it, or `nil` if the profile filters at the operator level only.
    ///
    /// This exists because an operator may lower its confidence for a specific
    /// site (`MutationCandidate.confidenceOverride`). `admits(_:)` sees only the
    /// operator's declared confidence, so without a site-level floor a
    /// `conservative` run would still execute the low-confidence sites of a
    /// high-confidence operator.
    ///
    /// `default` and `experimental` impose no floor: both already accept
    /// operators whose declared confidence is below `high`, so filtering their
    /// sites by confidence would contradict the operator-level decision.
    var siteConfidenceFloor: MutationConfidence? {
        switch self {
        case .conservative: .high
        case .default, .experimental: nil
        }
    }
}
