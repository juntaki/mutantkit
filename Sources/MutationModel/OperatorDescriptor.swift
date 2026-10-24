/// Static metadata describing a mutation operator.
///
/// Embedded into every plan and result so that a report stays interpretable
/// after the operator itself has changed. `version` is an ID input: bumping it
/// deliberately invalidates old IDs, caches and golden results, because a
/// changed operator no longer produces the same mutation.
public struct OperatorDescriptor: Codable, Sendable, Hashable {
    /// Stable reverse-DNS-ish ID, e.g. `swift.core.bool-literal-inversion`.
    public let id: String
    public let version: Int
    public let category: String
    /// One line, shown by `inspect` to explain what this operator does.
    public let summary: String
    public let defaultEnabled: Bool
    public let confidence: MutationConfidence
    /// Whether Phase 4 may batch this operator into a schemata build.
    ///
    /// This is *effective, serialized* metadata, not a value an operator's
    /// own source file gets to declare authoritatively: `MutationRegistry`
    /// overwrites whatever an operator's own `static let descriptor`
    /// literal says with the true answer — whether `SchemataLowererRegistry`
    /// actually has a lowerer registered for this operator's ID — for every
    /// descriptor it hands out (`allDescriptors`, `resolve(_:).descriptors`,
    /// and therefore every `MutationPlan` these end up embedded in). An
    /// operator's own `descriptor` still needs *some* literal here (this
    /// initializer has no other default), but that literal is never read as
    /// the runtime answer once it passes through `MutationRegistry` — see
    /// that type's own `effectiveDescriptor(for:)` for where the real
    /// answer comes from. This field used to be read directly instead
    /// of through that resolver, and the two drifted: 6 lowerers were
    /// promoted into `SchemataLowererRegistry.builtIn` over several
    /// sessions without this field ever being touched in any of those
    /// commits.
    public let schemataEligible: Bool
    /// `true` means the operator needs type/symbol information it cannot get
    /// from syntax alone; such operators stay disabled until Phase 5 wires up an
    /// index.
    public let requiresSymbolResolution: Bool
    /// Citations to real bug-fix commits or issues justifying this operator.
    /// Apple-specific operators must not ship with this empty.
    public let faultEvidence: [String]

    public init(
        id: String,
        version: Int,
        category: String,
        summary: String,
        defaultEnabled: Bool,
        confidence: MutationConfidence,
        schemataEligible: Bool = false,
        requiresSymbolResolution: Bool = false,
        faultEvidence: [String] = []
    ) {
        self.id = id
        self.version = version
        self.category = category
        self.summary = summary
        self.defaultEnabled = defaultEnabled
        self.confidence = confidence
        self.schemataEligible = schemataEligible
        self.requiresSymbolResolution = requiresSymbolResolution
        self.faultEvidence = faultEvidence
    }

    /// A copy with `schemataEligible` replaced — every other field
    /// unchanged. The one place this exists to serve is
    /// `MutationRegistry.effectiveDescriptor(for:)`, overwriting an
    /// operator's own declared literal with the real answer from
    /// `SchemataLowererRegistry` before this descriptor is ever handed to
    /// an external consumer.
    public func withSchemataEligible(_ schemataEligible: Bool) -> OperatorDescriptor {
        OperatorDescriptor(
            id: id, version: version, category: category, summary: summary,
            defaultEnabled: defaultEnabled, confidence: confidence,
            schemataEligible: schemataEligible,
            requiresSymbolResolution: requiresSymbolResolution, faultEvidence: faultEvidence
        )
    }
}

/// Named bundles of operators.
///
/// Three profiles are canonical (`canonicalCases`): `default`, `stronger` and
/// `all`. `conservative` and `experimental` are v1.x wire values kept as
/// *legacy cases*, not aliases: a config written against v1.x must keep both
/// its meaning and its `configurationHash` (which hashes the resolved
/// settings, so re-encoding `conservative` as `default` would change it and
/// widen the selection from four operators to six).
///
/// A profile is an adoption policy, deliberately separate from
/// `MutationConfidence`, which describes one mutation's likelihood of being
/// meaningful. Neither is derived from the other.
public enum OperatorProfile: String, Codable, Sendable, CaseIterable {
    /// Nightly: everything marked `defaultEnabled`.
    case `default`
    /// `default` plus the operators in `strongerAdditionalOperatorIDs`: useful
    /// but costlier or less settled operators that the baseline evidence has
    /// moved up from `all`.
    case stronger
    /// Everything, including operators known to be noisy.
    case all

    /// Legacy v1.x value. Pull requests: `defaultEnabled` and high confidence
    /// only. Not an alias of `default` -- it selects fewer operators.
    case conservative
    /// Legacy v1.x value. Selects exactly what `all` selects; the wire value
    /// stays `experimental` so existing configs and hashes do not change.
    case experimental

    /// The profiles documented, generated by `setup` and shown as tiers.
    public static let canonicalCases: [OperatorProfile] = [.default, .stronger, .all]

    /// Accepted when reading but never written by `setup` or shown as a tier.
    public static let legacyCases: [OperatorProfile] = [.conservative, .experimental]

    /// Operators `stronger` admits on top of `defaultEnabled`. Kept as a list
    /// of IDs here, not a field on `OperatorDescriptor`: a descriptor is
    /// serialized into every plan, so a tier field would change plan content
    /// for operators whose behavior did not change.
    ///
    /// `swift.core.nil-coalescing-fallback`: Stage 1 operator-parity baseline
    /// (8 corpora): 59 of 64 mutants scorable, no flaky, timed-out or
    /// non-materialized mutants, and 25 of its 26 survivors were hand-judged
    /// meaningful. It stays out of `default`; its schemata lowerer lets a
    /// `stronger` run build its sites in shared chunks instead of one by one.
    public static let strongerAdditionalOperatorIDs: Set<String> = [
        "swift.core.nil-coalescing-fallback"
    ]

    public var isLegacy: Bool { Self.legacyCases.contains(self) }

    public func admits(_ descriptor: OperatorDescriptor) -> Bool {
        switch self {
        case .conservative:
            descriptor.defaultEnabled && descriptor.confidence == .high
        case .default:
            descriptor.defaultEnabled
        case .stronger:
            descriptor.defaultEnabled || Self.strongerAdditionalOperatorIDs.contains(descriptor.id)
        case .all, .experimental:
            true
        }
    }
}
