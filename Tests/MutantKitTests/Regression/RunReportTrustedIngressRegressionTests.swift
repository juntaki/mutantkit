import Foundation
import Testing

/// `RunReport.decode(from:)` (`Sources/MutationModel/MutationResult.swift`)
/// is the one place a `RunReport` should ever be read from disk — it
/// enforces the `schemaVersion` fail-closed gate every other machine-
/// readable artifact reader (`MutationPlan.decode(from:)`) already applies.
/// `mutantkit merge` (`Sources/CLI/Commands/MergeCommand.swift`) used to
/// bypass it, decoding shard reports through a raw `JSONDecoder` obtained
/// from `MutationPlan.decoder()` — the one multi-input reader, and
/// therefore exactly the place a version-mixed CI fleet would surface a
/// foreign `schemaVersion`, was unable to detect one and would silently
/// fold it into a scored, integrity-checked, history-recorded merged
/// report instead.
///
/// This is a permanent, mechanical guard against that regression
/// recurring in a different command: a textual scan, not a build-time
/// check, so it catches the exact shape of the bug (a raw decode call
/// spelled out again somewhere new) regardless of which file introduces
/// it — the same "hand-rolled scan over a small, deliberately-scoped file
/// set" approach `DocumentedVersionPinConsistencyTests`/
/// `ProcessSupervisorBypassRegressionTests` already use for their own
/// permanent contracts.
@Suite("Regression: RunReport has exactly one trusted decode ingress")
struct RunReportTrustedIngressRegressionTests {
    /// `#filePath`-anchored, like `DocumentedVersionPinConsistencyTests`: it
    /// resolves identically in this repository and in a projected public
    /// snapshot, needs no environment, no git, and no build products.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/MutantKitTests/Regression/<this file>
            .deletingLastPathComponent() // Regression
            .deletingLastPathComponent() // MutantKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    /// The one file allowed to spell out a raw `RunReport` decode — it is
    /// the definition of the trusted ingress itself, not a caller of it.
    private static let definitionFile = "Sources/MutationModel/MutationResult.swift"

    /// The exact shape the real bug took: a `Decoder.decode(RunReport.self,
    /// from:)` call reached from anywhere other than `definitionFile`.
    /// Deliberately a plain substring search, not a Swift-syntax parse:
    /// the goal is catching the literal pattern reappearing, not
    /// understanding call graphs, and a textual match is exactly as
    /// effective at that while staying trivially portable to the projected
    /// public snapshot.
    private static let forbiddenPattern = "decode(RunReport.self"

    @Test("No file outside MutationResult.swift decodes a RunReport with a raw decoder")
    func onlyTheDefinitionDecodesRunReportDirectly() throws {
        let root = Self.repositoryRoot
        let sourcesRoot = root.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: nil
        ) else {
            Issue.record("could not enumerate \(sourcesRoot.path)")
            return
        }

        var offenders: [String] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            guard relativePath != Self.definitionFile else { continue }
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            if text.contains(Self.forbiddenPattern) {
                offenders.append(relativePath)
            }
        }

        let offenderList = offenders.joined(separator: ", ")
        #expect(
            offenders.isEmpty,
            "these file(s) decode RunReport directly instead of through RunReport.decode(from:), bypassing its schemaVersion fail-closed gate: \(offenderList)"
        )
    }
}
