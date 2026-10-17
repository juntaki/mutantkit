import Foundation
import MutationModel
import MutationPlanner
import Testing

/// The operator matrix is
/// generated from the registries the planner and the schemata backend really
/// use, never typed by hand, and the checked-in fixture plus the public
/// operator docs are held to it.
///
/// Why a test and not a table in a README: "is it 6, 12 or 13 operators" kept
/// coming back because each answer came from a different hand-maintained list.
/// Here the registry is the only source. If this suite is red, an operator
/// was added, removed, retiered or given a schemata lowerer, and the fixture
/// (and for a new operator, `docs/operators.md`) has not caught up.
///
/// To refresh the checked-in fixture after an intended change:
/// `MUTANTKIT_REGENERATE_OPERATOR_MATRIX=1 swift test --filter OperatorParityMatrixTests`
/// and review the diff.
@Suite("Operator parity matrix")
struct OperatorParityMatrixTests {
    /// One row of the matrix. Only facts the code can state are columns; the
    /// evidence columns the parity work adds later (differential, corpus) are
    /// appended by the phases that produce that evidence, not guessed here.
    struct Row: Equatable {
        let id: String
        let version: Int
        let category: String
        let confidence: MutationConfidence
        /// The most restrictive canonical profile that reaches the operator.
        let tier: OperatorProfile
        let schemata: Bool
        let requiresSymbolResolution: Bool
    }

    // MARK: - Generation (single source: the registries)

    static func rows() -> [Row] {
        MutationRegistry().allDescriptors
            .sorted { $0.id < $1.id }
            .map { descriptor in
                Row(
                    id: descriptor.id,
                    version: descriptor.version,
                    category: descriptor.category,
                    confidence: descriptor.confidence,
                    tier: OperatorProfile.canonicalCases.first { $0.admits(descriptor) } ?? .all,
                    schemata: descriptor.schemataEligible,
                    requiresSymbolResolution: descriptor.requiresSymbolResolution
                )
            }
    }

    /// The checked-in form of a row. Plain strings, so the fixture does not
    /// move when an enum case is renamed without its raw value changing.
    struct Entry: Codable, Equatable {
        let id: String
        let version: Int
        let category: String
        let confidence: String
        let tier: String
        let schemata: Bool
        let requiresSymbolResolution: Bool
    }

    static func entries() -> [Entry] {
        rows().map {
            Entry(
                id: $0.id,
                version: $0.version,
                category: $0.category,
                confidence: $0.confidence.rawValue,
                tier: $0.tier.rawValue,
                schemata: $0.schemata,
                requiresSymbolResolution: $0.requiresSymbolResolution
            )
        }
    }

    static let coreIDPrefix = "swift.core."

    // MARK: - Locations

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/MutantKitTests/Regression/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var matrixURL: URL {
        repositoryRoot.appendingPathComponent("Tests/MutantKitTests/Fixtures/OperatorMatrix/operator-matrix.json")
    }

    private static var operatorsDocURL: URL {
        repositoryRoot.appendingPathComponent("docs/operators.md")
    }

    // MARK: - Gates

    @Test("The checked-in matrix equals the one generated from the registries")
    func checkedInMatrixMatchesRegistries() throws {
        let generated = Self.entries()

        if ProcessInfo.processInfo.environment["MUTANTKIT_REGENERATE_OPERATOR_MATRIX"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try (encoder.encode(generated) + Data("\n".utf8)).write(to: Self.matrixURL, options: .atomic)
        }

        let checkedIn = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: Self.matrixURL))
        let byID = { (entries: [Entry]) in Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }) }
        let expected = byID(checkedIn)
        let actual = byID(generated)
        let changed = actual.keys.filter { expected[$0] != nil && expected[$0] != actual[$0] }.sorted()
        #expect(
            checkedIn == generated,
            "Operator matrix fixture is stale (added: \(Set(actual.keys).subtracting(expected.keys).sorted()), removed: \(Set(expected.keys).subtracting(actual.keys).sorted()), changed: \(changed)); regenerate it (see this suite's doc comment) and review the diff."
        )
    }

    /// The count that went wrong before ("13" counted `unary-minus-removal`,
    /// which has no descriptor). Pinned to the IDs rather than a bare number so
    /// a failure names the operator that moved.
    @Test("The core operator set is exactly the twelve the catalog of record names")
    func coreOperatorSetIsPinned() {
        let core = Set(Self.rows().map(\.id).filter { $0.hasPrefix(Self.coreIDPrefix) })
        let expected = Set([
            "bool-literal-inversion",
            "relational-operator-replacement",
            "logical-connector-replacement",
            "ternary-branch-swap",
            "unary-not-removal",
            "return-value-replacement",
            "arithmetic-operator-replacement",
            "assignment-operator-replacement",
            "nil-coalescing-fallback",
            "else-clause-deletion",
            "range-boundary-replacement",
            "side-effect-call-removal"
        ].map { Self.coreIDPrefix + $0 })

        #expect(core == expected, "added: \(core.subtracting(expected).sorted()), removed: \(expected.subtracting(core).sorted())")
    }

    @Test("docs/operators.md lists every registered operator")
    func publicDocsListEveryRegisteredOperator() throws {
        let docs = try String(contentsOf: Self.operatorsDocURL, encoding: .utf8)
        let missing = Self.rows().map(\.id).filter { !docs.contains("`\($0)`") }
        #expect(missing.isEmpty, "docs/operators.md does not mention: \(missing)")
    }

    @Test("Every schemata-eligible descriptor is backed by a registered lowerer, and only those")
    func schemataColumnEqualsLowererRegistry() {
        let lowered = Set(SchemataLowererRegistry.builtIn.flatMap(\.descriptor.supportedOperatorIDs))
        let eligible = Set(Self.rows().filter(\.schemata).map(\.id))
        #expect(eligible == lowered)
    }
}
