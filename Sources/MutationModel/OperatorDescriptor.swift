import Foundation

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
    /// Whether Phase 4 may batch this operator into a schemata build. Every
    /// operator starts `false` and only earns `true` by passing the differential
    /// test against isolated execution.
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
}

/// Named bundles of operators, matching the run profiles in the design.
public enum OperatorProfile: String, Codable, Sendable, CaseIterable {
    /// Pull requests: high confidence only, cheap and actionable.
    case conservative
    /// Nightly: everything marked `defaultEnabled`.
    case `default`
    /// Weekly: everything, including operators known to be noisy.
    case experimental

    public func admits(_ descriptor: OperatorDescriptor) -> Bool {
        switch self {
        case .conservative:
            descriptor.defaultEnabled && descriptor.confidence == .high
        case .default:
            descriptor.defaultEnabled
        case .experimental:
            true
        }
    }
}
