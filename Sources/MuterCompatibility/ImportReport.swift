import Foundation

/// What an import did to every field it found, including the ones it could not
/// carry over.
///
/// Muter compatibility is explicitly not guaranteed, so an importer that quietly
/// produced a config would be claiming an equivalence that does not exist. The
/// report is the deliverable: a user reading it should be able to tell, without
/// running anything, exactly where the imported config will behave differently
/// from their Muter setup.
public struct ImportReport: Sendable, Hashable, Codable {
    /// What happened to one field of the source config.
    public enum Disposition: String, Sendable, Codable, CaseIterable {
        /// Carried over with the same meaning.
        case translated
        /// Carried over, but the meaning is not identical.
        case partiallyTranslated
        /// No equivalent exists. The setting has no effect on the imported run.
        case dropped
        /// Translated or defaulted on a guess a human should confirm.
        case needsReview
    }

    /// One field's fate.
    public struct Entry: Sendable, Hashable, Codable {
        /// The field's name as it appears in `muter.conf.yml`.
        public let field: String
        public let disposition: Disposition
        /// The value found in the Muter config, rendered for display.
        public let muterValue: String?
        /// Where it landed in our config, if anywhere.
        public let mutantkitValue: String?
        /// Why this disposition — the sentence the user actually needs.
        public let detail: String

        public init(
            field: String,
            disposition: Disposition,
            muterValue: String? = nil,
            mutantkitValue: String? = nil,
            detail: String
        ) {
            self.field = field
            self.disposition = disposition
            self.muterValue = muterValue
            self.mutantkitValue = mutantkitValue
            self.detail = detail
        }
    }

    /// The file the config was read from, for the report header.
    public let sourceName: String
    public let entries: [Entry]

    public init(sourceName: String, entries: [Entry]) {
        self.sourceName = sourceName
        self.entries = entries
    }

    public func entries(with disposition: Disposition) -> [Entry] {
        entries.filter { $0.disposition == disposition }
    }

    /// True when something was dropped or guessed at. The CLI should not let
    /// this pass without printing the report.
    public var requiresAttention: Bool {
        entries.contains { $0.disposition == .dropped || $0.disposition == .needsReview }
    }

    /// Human-readable rendering, grouped by what the reader has to do about it.
    public func rendered() -> String {
        var lines = ["Imported \(sourceName)", ""]

        let sections: [(Disposition, String)] = [
            (.dropped, "Dropped — no equivalent in this tool"),
            (.needsReview, "Needs review — confirm these before running"),
            (.partiallyTranslated, "Translated with a difference in meaning"),
            (.translated, "Translated")
        ]

        for (disposition, heading) in sections {
            let matching = entries(with: disposition)
            guard !matching.isEmpty else { continue }

            lines.append("\(heading):")
            for entry in matching {
                lines.append("  \(entry.field)")
                if let muterValue = entry.muterValue {
                    lines.append("    muter:  \(muterValue)")
                }
                if let mutantkitValue = entry.mutantkitValue {
                    lines.append("    mutantkit: \(mutantkitValue)")
                }
                for detailLine in entry.detail.split(separator: "\n") {
                    lines.append("    \(detailLine.trimmingCharacters(in: .whitespaces))")
                }
            }
            lines.append("")
        }

        if requiresAttention {
            lines.append(
                "Muter compatibility is best-effort. Review the imported config before trusting a score from it."
            )
        }

        return lines.joined(separator: "\n")
    }
}
