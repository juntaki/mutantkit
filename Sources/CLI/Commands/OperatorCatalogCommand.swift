import ArgumentParser
import Foundation
import MutationModel
import MutationPlanner

/// Lists every mutation operator this binary ships, read straight from
/// `MutationRegistry` — the same registry `plan`/`run` resolve against to
/// decide what actually executes.
///
/// Muter ships `muter operator <name>`/`muter operator all`, but that command
/// prints hand-written prose baked into a `switch` over `MutationOperator.Id`
/// in `Sources/muterCore/CLICommands/Operator.swift` — one case per operator,
/// authored separately from the operator itself. Nothing forces the two to
/// stay in sync; an operator's behaviour can change without its `documentation`
/// case being touched.
///
/// This command has no such switch. `OperatorCatalogEntry` is built entirely
/// from `OperatorDescriptor` — the struct `MutationRegistry.resolve` reads to
/// decide what "enabled" means (see `MutationRegistry.swift`) and the struct
/// every operator's own source file declares as `static let descriptor`. If a
/// new operator is added to `MutationRegistry.builtIn` and forgotten here, it
/// still shows up: there is nothing else to forget. That is the actual
/// difference from a hand-maintained README table or a hand-maintained
/// `switch` — not more prose, a structurally shared source of truth.
///
/// Named `operator-catalog`, not `operators`: `operators:` is already a
/// `mutantkit.yml` settings key (`profile`/`enable`/`disable`, see
/// `OperatorSettings`), so a command named `operators` would misread as "show
/// or change my operator settings" rather than "show me what operators
/// exist". `operator-catalog` reuses this project's own name for the
/// concept and cannot be misread either way.
struct OperatorCatalogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "operator-catalog",
        abstract: "List MutantKit's mutation operators, generated from the registry the planner actually uses.",
        discussion: """
        With no argument, prints every registered operator: ID, the most \
        restrictive profile that reaches it, confidence, and its one-line \
        summary. With an operator ID, prints full detail for that operator \
        alone, including its fault-evidence rationale.

        Corpus-measured evidence — kill rates, promotion history, provisional \
        status — is not tracked in the registry this command reads, only in \
        the project README's Operators table. This command does not repeat \
        that evidence; it shows what the registry actually carries.
        """
    )

    @Argument(help: "Show full detail for one operator ID instead of the summary table.")
    var operatorID: String?

    @Flag(name: .long, help: "Emit machine-readable JSON instead of a table.")
    var json = false

    func run() throws {
        let registry = MutationRegistry()

        if let operatorID {
            guard let entry = Self.entry(for: operatorID, registry: registry) else {
                let known = registry.allDescriptors.map(\.id).sorted().joined(separator: "\n  ")
                print("No operator '\(operatorID)'. Known operators:\n  \(known)")
                throw ExitCode(MutantKitExit.operationalError)
            }
            if json {
                print(try Self.jsonString(entry))
            } else {
                print(Self.renderDetail(entry))
            }
            return
        }

        let entries = Self.entries(registry: registry)
        if json {
            print(try Self.jsonString(entries))
        } else {
            print(Self.renderTable(entries))
        }
    }

    // MARK: - Data (testable independently of stdout)

    /// Every registered operator, in the registry's own order. Iterating
    /// `registry.allDescriptors` — not a literal list maintained here — is
    /// what makes this command unable to drift from `MutationRegistry.builtIn`.
    static func entries(registry: MutationRegistry = MutationRegistry()) -> [OperatorCatalogEntry] {
        registry.allDescriptors.map(OperatorCatalogEntry.init)
    }

    static func entry(for operatorID: String, registry: MutationRegistry = MutationRegistry()) -> OperatorCatalogEntry? {
        registry.allDescriptors.first { $0.id == operatorID }.map(OperatorCatalogEntry.init)
    }

    // MARK: - Rendering (testable independently of stdout)

    static func renderTable(_ entries: [OperatorCatalogEntry]) -> String {
        guard !entries.isEmpty else { return "No operators registered." }

        let idWidth = max(entries.map(\.id.count).max() ?? 0, "ID".count)
        let profileWidth = max(entries.map { profileLabel($0.reachableProfile).count }.max() ?? 0, "PROFILE".count)
        let confidenceWidth = max(entries.map(\.confidence.rawValue.count).max() ?? 0, "CONFIDENCE".count)

        func row(_ id: String, _ profile: String, _ confidence: String, _ summary: String) -> String {
            id.padding(toLength: idWidth, withPad: " ", startingAt: 0) + "  "
                + profile.padding(toLength: profileWidth, withPad: " ", startingAt: 0) + "  "
                + confidence.padding(toLength: confidenceWidth, withPad: " ", startingAt: 0) + "  "
                + summary
        }

        var lines = [row("ID", "PROFILE", "CONFIDENCE", "SUMMARY")]
        for entry in entries {
            lines.append(row(entry.id, profileLabel(entry.reachableProfile), entry.confidence.rawValue, entry.summary))
        }
        return lines.joined(separator: "\n")
    }

    static func renderDetail(_ entry: OperatorCatalogEntry) -> String {
        var lines = [
            "\(entry.id) (v\(entry.version))",
            "",
            "Category              \(entry.category)",
            "Profile               \(profileLabel(entry.reachableProfile))",
            "Default enabled       \(entry.defaultEnabled ? "yes" : "no")",
            "Confidence            \(entry.confidence.rawValue)",
            "Schemata eligible     \(entry.schemataEligible ? "yes" : "no")",
            "Requires symbol info  \(entry.requiresSymbolResolution ? "yes" : "no")",
            "",
            entry.summary
        ]

        if !entry.faultEvidence.isEmpty {
            lines.append("")
            lines.append("Why this operator exists")
            for evidence in entry.faultEvidence {
                lines.append("  " + evidence.replacingOccurrences(of: "\n", with: "\n  "))
            }
        }

        lines.append("")
        lines.append("""
        Corpus-measured evidence — kill rates, promotion history, provisional \
        status — is not tracked in this registry yet. See the README's \
        Operators table for what has been measured so far.
        """)

        return lines.joined(separator: "\n")
    }

    static func jsonString(_ value: some Encodable) throws -> String {
        try JSONOutput.string(for: value)
    }

    private static func profileLabel(_ profile: OperatorProfile?) -> String {
        profile?.rawValue ?? "none (requires symbol resolution)"
    }
}

/// The registry-derived facts this command shows. Every field is read
/// straight from `OperatorDescriptor`, plus `reachableProfile`, which is
/// derived using `OperatorProfile.admits` — the exact predicate
/// `MutationRegistry.resolve` uses to decide what a profile actually turns
/// on — rather than a second, hand-maintained notion of "which profile is
/// this operator in".
struct OperatorCatalogEntry: Codable, Equatable {
    /// Set internally to `SchemaVersion.operatorCatalogEntry`, never a
    /// caller-supplied parameter — matching `AgentEvidenceReport` and
    /// `RunHistoryRecord`, this tool's two other agent-facing `--json`
    /// output types.
    let schemaVersion: Int
    let id: String
    let category: String
    let version: Int
    let summary: String
    let defaultEnabled: Bool
    let confidence: MutationConfidence
    /// The most restrictive profile that reaches this operator by default
    /// (`conservative` < `default` < `experimental`), or `nil` if no profile
    /// can — true only for `requiresSymbolResolution` operators, which
    /// `MutationRegistry.resolve` excludes from every profile and can only be
    /// switched on by naming them explicitly in `operators.enable`.
    let reachableProfile: OperatorProfile?
    let schemataEligible: Bool
    let requiresSymbolResolution: Bool
    /// Citations to real fault patterns this operator's mutations expose.
    /// The only long-form rationale text the registry carries today — see
    /// this command's `discussion` for what it does *not* carry.
    let faultEvidence: [String]

    /// Mirrors the profile order `MutationRegistry.resolve` implicitly
    /// relies on: conservative admits a subset of default, default a subset
    /// of experimental, so the first one that admits a descriptor is also
    /// the most restrictive.
    private static let profileOrder: [OperatorProfile] = [.conservative, .default, .experimental]

    init(descriptor: OperatorDescriptor) {
        schemaVersion = SchemaVersion.operatorCatalogEntry
        id = descriptor.id
        category = descriptor.category
        version = descriptor.version
        summary = descriptor.summary
        defaultEnabled = descriptor.defaultEnabled
        confidence = descriptor.confidence
        schemataEligible = descriptor.schemataEligible
        requiresSymbolResolution = descriptor.requiresSymbolResolution
        faultEvidence = descriptor.faultEvidence
        reachableProfile = descriptor.requiresSymbolResolution
            ? nil
            : Self.profileOrder.first { $0.admits(descriptor) }
    }
}
