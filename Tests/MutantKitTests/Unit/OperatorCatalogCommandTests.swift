@testable import CLI
import Foundation
import MutationModel
import MutationPlanner
import SwiftCoreOperators
import Testing

/// `mutantkit operator-catalog` exists to never drift from
/// `MutationRegistry.builtIn` — the whole point is that its output is
/// generated from the same registry `plan`/`run` resolve against, not a
/// second, hand-maintained list. These tests pin that property directly: the
/// first one would fail the moment someone adds an operator to the registry
/// without it appearing here, which is exactly the failure mode a
/// hand-copied README table cannot catch.
@Suite("OperatorCatalogCommand")
struct OperatorCatalogCommandTests {
    // MARK: - No drift from the registry

    /// If this test is red, either an operator was added to
    /// `MutationRegistry.builtIn` and the catalog didn't pick it up (the
    /// regression this command exists to make impossible), or one was
    /// removed and this list needs updating — either way, the failure is
    /// exactly the signal this command is for.
    @Test("The default table lists every operator currently registered")
    func defaultListMatchesRegistry() {
        let registryIDs = Set(MutationRegistry.builtIn.map(\.descriptor.id))
        let entries = OperatorCatalogCommand.entries()
        let entryIDs = Set(entries.map(\.id))

        #expect(entryIDs == registryIDs)
        #expect(entries.count == MutationRegistry.builtIn.count, "no duplicate or dropped entries")
    }

    /// The rendered table must actually contain every ID, not just the
    /// structured data behind it — a rendering bug that silently dropped a
    /// row would defeat the whole point just as badly as a data bug would.
    @Test("The rendered table contains every registered operator ID")
    func renderedTableContainsEveryID() {
        let entries = OperatorCatalogCommand.entries()
        let table = OperatorCatalogCommand.renderTable(entries)

        for descriptor in MutationRegistry.builtIn.map(\.descriptor) {
            #expect(table.contains(descriptor.id), "missing \(descriptor.id) from rendered table")
        }
    }

    // MARK: - Single-operator lookup

    @Test("A real operator ID resolves to the registry's own descriptor")
    func lookupKnownOperator() throws {
        let descriptor = BoolLiteralInversionOperator.descriptor
        let entry = try #require(OperatorCatalogCommand.entry(for: descriptor.id))

        #expect(entry.id == descriptor.id)
        #expect(entry.category == descriptor.category)
        #expect(entry.summary == descriptor.summary)
        #expect(entry.defaultEnabled == descriptor.defaultEnabled)
        #expect(entry.confidence == descriptor.confidence)
        #expect(entry.faultEvidence == descriptor.faultEvidence)
    }

    @Test("Detail rendering surfaces the operator's fault evidence")
    func detailRenderingIncludesFaultEvidence() throws {
        let entry = try #require(OperatorCatalogCommand.entry(for: "swift.core.bool-literal-inversion"))
        let detail = OperatorCatalogCommand.renderDetail(entry)

        #expect(detail.contains(entry.id))
        #expect(detail.contains("conservative"))
        for evidence in entry.faultEvidence {
            #expect(detail.contains(evidence.split(separator: "\n").first.map(String.init) ?? evidence))
        }
    }

    // MARK: - Unknown ID

    @Test("An unknown operator ID resolves to nothing")
    func lookupUnknownOperator() {
        #expect(OperatorCatalogCommand.entry(for: "no.such.operator") == nil)
    }

    // MARK: - reachableProfile

    /// Conservative-profile operators are, by construction, also reachable
    /// by `default` and `experimental` (`OperatorProfile.admits` is
    /// cumulative) — so the *most restrictive* profile that admits an
    /// operator is the one this command should show, and it has to agree
    /// with `OperatorProfile.admits` itself rather than a second opinion.
    @Test("reachableProfile is the most restrictive profile that actually admits the operator")
    func reachableProfileAgreesWithAdmits() throws {
        let order: [OperatorProfile] = [.conservative, .default, .experimental]

        for descriptor in MutationRegistry.builtIn.map(\.descriptor) {
            let entry = try #require(OperatorCatalogCommand.entry(for: descriptor.id))
            let reachable = try #require(entry.reachableProfile, "no builtIn operator requires symbol resolution today")

            // `reachable` itself must actually admit the descriptor...
            #expect(reachable.admits(descriptor))

            // ...and no profile stricter than `reachable` may also admit it,
            // or `reachable` would not be the *most* restrictive one.
            let strictIndex = try #require(order.firstIndex(of: reachable))
            for stricter in order.prefix(strictIndex) {
                #expect(!stricter.admits(descriptor), "\(stricter) admits \(descriptor.id) but reachableProfile reports \(reachable)")
            }
        }
    }

    // MARK: - JSON

    @Test("--json list output is valid JSON with the expected shape")
    func jsonListIsValidAndShaped() throws {
        let entries = OperatorCatalogCommand.entries()
        let json = try OperatorCatalogCommand.jsonString(entries)

        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        let array = try #require(decoded)

        #expect(array.count == entries.count)
        let first = try #require(array.first)
        for key in ["id", "category", "version", "summary", "defaultEnabled", "confidence",
                    "reachableProfile", "schemataEligible", "requiresSymbolResolution", "faultEvidence"] {
            #expect(first[key] != nil, "missing key '\(key)' in JSON entry")
        }
    }

    @Test("--json detail output is valid JSON for a single operator")
    func jsonDetailIsValidAndShaped() throws {
        let entry = try #require(OperatorCatalogCommand.entry(for: "swift.core.bool-literal-inversion"))
        let json = try OperatorCatalogCommand.jsonString(entry)

        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let object = try #require(decoded)

        #expect(object["id"] as? String == "swift.core.bool-literal-inversion")
        #expect(object["confidence"] as? String == "high")
        #expect(object["reachableProfile"] as? String == "conservative")
    }
}
