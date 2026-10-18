@testable import CLI
import Foundation
import MutationModel
import MutationPlanner
import Testing

/// `default / stronger / all` become the canonical
/// profiles while `conservative` and `experimental` stay as legacy wire values
/// with their v1.x meaning. These gates pin what must NOT move: the legacy
/// selections, the config wire format and `configurationHash`.
@Suite("OperatorProfile tiers")
struct OperatorProfileTiersTests {
    private static func selected(_ profile: OperatorProfile) throws -> [String] {
        try MutationRegistry().resolve(OperatorSettings(profile: profile)).enabledOperators
            .map(\.descriptor.id).sorted()
    }

    private static func core(_ names: [String]) -> [String] {
        names.map { "swift.core.\($0)" }.sorted()
    }

    // MARK: - Selection

    @Test("conservative keeps selecting exactly the four high-confidence operators")
    func conservativeIsUnchanged() throws {
        #expect(try Self.selected(.conservative) == Self.core([
            "bool-literal-inversion", "logical-connector-replacement",
            "relational-operator-replacement", "ternary-branch-swap"
        ]))
    }

    @Test("default keeps selecting exactly the six operators it selected in v1.2")
    func defaultIsUnchanged() throws {
        #expect(try Self.selected(.default) == Self.core([
            "bool-literal-inversion", "logical-connector-replacement",
            "relational-operator-replacement", "ternary-branch-swap",
            "unary-not-removal", "return-value-replacement"
        ]))
    }

    @Test("all and the legacy experimental resolve identically")
    func allEqualsExperimental() throws {
        #expect(try Self.selected(.all) == Self.selected(.experimental))
        #expect(try Self.selected(.all) == MutationRegistry().allDescriptors
            .filter { !$0.requiresSymbolResolution }.map(\.id).sorted())
    }

    @Test("stronger selects the six default operators plus nil-coalescing-fallback")
    func strongerIsDefaultPlusNilCoalescing() throws {
        #expect(try Self.selected(.stronger) == Self.core([
            "bool-literal-inversion", "logical-connector-replacement",
            "relational-operator-replacement", "ternary-branch-swap",
            "unary-not-removal", "return-value-replacement", "nil-coalescing-fallback"
        ]))
    }

    @Test("every profile that admits an operator also admits it in the next tier")
    func tiersAreNested() throws {
        let default6 = Set(try Self.selected(.default))
        let stronger = Set(try Self.selected(.stronger))
        let all = Set(try Self.selected(.all))
        #expect(default6.isSubset(of: stronger))
        #expect(stronger.isSubset(of: all))
        #expect(stronger.subtracting(default6) == Set(OperatorProfile.strongerAdditionalOperatorIDs))
    }

    @Test("side-effect-call-removal and the other non-default operators stay out of stronger")
    func strongerExcludesTheRest() throws {
        let stronger = Set(try Self.selected(.stronger))
        for name in ["side-effect-call-removal", "else-clause-deletion", "arithmetic-operator-replacement",
                     "assignment-operator-replacement", "range-boundary-replacement"] {
            #expect(!stronger.contains("swift.core.\(name)"), "\(name)")
        }
    }

    @Test("Only conservative imposes a per-site confidence floor")
    func siteFloor() {
        #expect(OperatorProfile.conservative.siteConfidenceFloor == .high)
        for profile in OperatorProfile.allCases where profile != .conservative {
            #expect(profile.siteConfidenceFloor == nil, "\(profile.rawValue)")
        }
    }

    // MARK: - Wire format and hash

    /// Hashes captured from the v1.2.0 release before the
    /// enum changed. A drift here means existing plans no longer match their
    /// configuration.
    @Test("A v1.x config round-trips with its raw profile and its configurationHash unchanged",
          arguments: [
              ("conservative", "sha256:93a4061e8956bc1d787b20b767bd44cb7026139c6a686b2314d1003a07dcd534"),
              ("default", "sha256:5c4ecd20ff2e879874209efb59c5e4986a73f90e1b544a7c4312cabc4efb4ffa"),
              ("experimental", "sha256:fbebb21cb1cf9b221aa2418894bd9c3df7eb324251a265831d8581d0a26aec29")
          ])
    func legacyConfigRoundTripAndHash(raw: String, expectedHash: String) throws {
        let configuration = try ConfigurationLoader.parse(
            "version: 1\noperators:\n  profile: \(raw)\n", environment: [:]
        )
        #expect(configuration.operators.profile.rawValue == raw)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try String(decoding: encoder.encode(configuration), as: UTF8.self)
        #expect(json.contains("\"profile\":\"\(raw)\""))

        let redecoded = try JSONDecoder().decode(Configuration.self, from: encoder.encode(configuration))
        #expect(redecoded.configurationHash == configuration.configurationHash)
        #expect(configuration.configurationHash == expectedHash)
    }

    // MARK: - Canonical vs legacy presentation

    @Test("canonicalCases and legacyCases partition allCases")
    func casePartition() {
        #expect(OperatorProfile.canonicalCases == [.default, .stronger, .all])
        #expect(OperatorProfile.legacyCases == [.conservative, .experimental])
        #expect(Set(OperatorProfile.canonicalCases + OperatorProfile.legacyCases) == Set(OperatorProfile.allCases))
        #expect(OperatorProfile.allCases.count == 5)
    }

    @Test("operator-catalog shows only canonical tiers")
    func catalogUsesCanonicalTiers() {
        let tiers = Set(OperatorCatalogCommand.entries().compactMap(\.reachableProfile))
        #expect(tiers.isSubset(of: Set(OperatorProfile.canonicalCases)))
    }

    @Test("setup writes only the canonical default profile and does not advertise the legacy values")
    func setupTemplateIsCanonicalOnly() {
        let template = ConfigurationLoader.template(
            for: .swiftPackageMacOS, scheme: nil, destination: nil, testTargets: []
        )
        let profileLines = template.split(separator: "\n").filter { $0.contains("profile:") && !$0.contains("#") }
        #expect(profileLines.map { $0.trimmingCharacters(in: .whitespaces) }.contains("profile: default"))
        #expect(!template.contains("conservative"))
        #expect(!template.contains("experimental ="))
    }

    // MARK: - Acceptance of all five values

    @Test("MUTANTKIT_OPERATOR_PROFILE accepts the three canonical and two legacy values and rejects others",
          arguments: OperatorProfile.allCases)
    func environmentAcceptsEveryProfile(profile: OperatorProfile) throws {
        let configuration = try ConfigurationLoader.parse(
            "version: 1\n", environment: ["MUTANTKIT_OPERATOR_PROFILE": profile.rawValue]
        )
        #expect(configuration.operators.profile == profile)
    }

    @Test("MUTANTKIT_OPERATOR_PROFILE rejects an unknown value and lists all five")
    func environmentRejectsUnknown() {
        do {
            _ = try ConfigurationLoader.parse(
                "version: 1\n", environment: ["MUTANTKIT_OPERATOR_PROFILE": "bogus"]
            )
            Issue.record("expected an invalid environment value error")
        } catch {
            let message = "\(error)"
            for profile in OperatorProfile.allCases {
                #expect(message.contains(profile.rawValue), "\(profile.rawValue) missing from: \(message)")
            }
        }
    }

    @Test("The JSON Schema enum accepts exactly the five profile values")
    func schemaEnumMatchesProfiles() throws {
        let data = Data(ConfigurationJSONSchema.document.utf8)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let operators = try #require((root["properties"] as? [String: Any])?["operators"] as? [String: Any])
        let profile = try #require((operators["properties"] as? [String: Any])?["profile"] as? [String: Any])
        let values = try #require(profile["enum"] as? [String])
        #expect(Set(values) == Set(OperatorProfile.allCases.map(\.rawValue)))
    }
}
