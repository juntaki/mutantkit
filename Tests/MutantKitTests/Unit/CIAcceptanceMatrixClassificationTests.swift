import Foundation
import Testing

/// A deterministic regression test for the classifiers that decide what
/// CI's `acceptance` matrix actually runs — exactly the class of bug that
/// already shipped once for real (`cli-commands`'s `simulator: "0"`
/// misclassification): a classifier's job is never to make a false skip
/// look like a pass.
///
/// This reads the *real*, checked-in `Scripts/ci-fixtures.json` — the
/// single source of truth for the `acceptance` job's dynamic matrix, read
/// at CI time by both `Scripts/ci-route.sh` (for the filtered/targeted
/// case) and, via that same script's `acceptance_matrix` output, the
/// full-matrix case too (see `.github/workflows/ci.yml`'s own comment
/// directly above the `acceptance` job) — and the *real* acceptance test
/// source files, so a future edit to either one is checked against the
/// other automatically, without anyone having to remember this file exists.
@Suite("CI acceptance matrix classification")
struct CIAcceptanceMatrixClassificationTests {
    struct MatrixEntry: Decodable {
        let fixture: String
        let filter: String
        let simulator: String?
        let wave: String?
    }

    private struct FixturesFile: Decodable {
        let fixtures: [MatrixEntry]
    }

    /// `Scripts/ci-fixtures.json` lives at a different relative path
    /// depending on which repo checkout this runs in: the public repo's
    /// root, or the private monorepo's `oss-public/` overlay of exactly the
    /// paths that differ from its own internal layout. Both are real, both
    /// must work.
    private static func fixturesFileURL() throws -> URL {
        let root = Acceptance.packageRoot
        for candidate in [
            root.appendingPathComponent("Scripts/ci-fixtures.json"),
            root.appendingPathComponent("oss-public/Scripts/ci-fixtures.json")
        ] where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw ClassificationTestError.fixturesFileNotFound(root.path)
    }

    /// Substrings whose presence in an acceptance test file's own source is
    /// strong, direct evidence it makes a real `xcrun simctl`/CoreSimulator
    /// call somewhere in its path — the exact thing `cli-commands`'s
    /// misclassification got wrong. Erring toward *more* of these than
    /// strictly necessary is the safe direction (a false positive here just
    /// means one harmless extra check on a fixture that turns out not to
    /// need it — see `simulator.isEmpty` handling below, unclassifiable
    /// stays fail-open too).
    private static let simulatorMarkers = [
        "simctl", "SimulatorPool", "XcodeConfigDetector", "iPhoneDestination", "CoreSimulator"
    ]

    private func acceptanceTestsDirectory() -> URL {
        Acceptance.packageRoot.appendingPathComponent("Tests/MutantKitTests/Acceptance")
    }

    private func loadMatrix() throws -> [MatrixEntry] {
        let url = try Self.fixturesFileURL()
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(FixturesFile.self, from: data)
        try #require(!file.fixtures.isEmpty, "parsed zero acceptance matrix entries from \(url.path) -- the file's structure changed")
        return file.fixtures
    }

    /// Maps every `struct <Name>` declared anywhere under
    /// `Tests/MutantKitTests/Acceptance/` to that file's own contents. Not a
    /// filename == suite-name lookup: several suites (`XcodeProjectAcceptanceTests`,
    /// `XcodeWorkspaceAcceptanceTests`, ...) share one file
    /// (`XcodeAcceptanceTests.swift`), so the only reliable way to find a
    /// suite is to search declarations, not guess a path.
    private func suiteDeclarationsByName() throws -> [String: String] {
        let directory = acceptanceTestsDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty, "found zero .swift files under \(directory.path)")

        var map: [String: String] = [:]
        let structPattern = /struct\s+(\w+)/

        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for match in contents.matches(of: structPattern) {
                map[String(match.1)] = contents
            }
        }
        return map
    }

    @Test("Every matrix fixture's filter names a suite that actually exists")
    func everyFilterNamesARealSuiteFile() throws {
        let matrix = try loadMatrix()
        let declarations = try suiteDeclarationsByName()

        for entry in matrix {
            // A `filter` can be a single suite name or a `"A|B"` alternation
            // (see `ios-simulator-schemata-runtime`'s own job in ci.yml).
            for suiteName in entry.filter.split(separator: "|").map(String.init) {
                #expect(
                    declarations[suiteName] != nil,
                    """
                    fixture '\(entry.fixture)' declares filter '\(suiteName)', but no \
                    `struct \(suiteName)` exists anywhere under Tests/MutantKitTests/Acceptance/ -- \
                    a renamed or deleted suite would leave this fixture's CI job silently matching zero tests
                    """
                )
            }
        }
    }

    /// The adversarial case this whole test exists for: a fixture whose real
    /// test file touches simulator-dependent APIs must be marked
    /// `simulator: "1"`. An *unrecognized* or missing `simulator:` value is
    /// deliberately treated as a violation too, not skipped — "cannot
    /// classify" must never quietly mean "assume it's fine to skip the
    /// preflight," matching this whole phase's own `unknown -> run` stance.
    @Test("A fixture whose suite makes real simulator calls is never marked simulator: \"0\"")
    func simulatorMarkedFixturesMatchRealUsage() throws {
        let matrix = try loadMatrix()
        let declarations = try suiteDeclarationsByName()

        for entry in matrix {
            var usesSimulatorAPI = false
            var matchedMarker = ""
            for suiteName in entry.filter.split(separator: "|").map(String.init) {
                guard let contents = declarations[suiteName] else { continue }
                for marker in Self.simulatorMarkers where contents.contains(marker) {
                    usesSimulatorAPI = true
                    matchedMarker = marker
                    break
                }
            }

            guard usesSimulatorAPI else { continue }

            let declared = entry.simulator.map { "\"\($0)\"" } ?? "<missing>"
            #expect(
                entry.simulator == "1",
                """
                fixture '\(entry.fixture)' (filter '\(entry.filter)') references '\(matchedMarker)' \
                but is marked simulator: \(declared) -- \
                this is exactly the cli-commands misclassification this test exists to catch
                """
            )
        }
    }

    /// Pins the fix directly: `XcodeWaveEarlyKillAcceptanceTests`
    /// (a real, differential, Xcode-based acceptance gate for wave-based
    /// early kill — real, shipped functionality) must have an entry in the
    /// matrix with `wave: "1"`, so `Acceptance.waveEnabled` is actually true
    /// when this job runs. Before this fix, no matrix entry referenced this
    /// filter at all, and `MUTANTKIT_WAVE_ACCEPTANCE` was never set anywhere
    /// — this suite had never executed in CI since it was added.
    @Test("XcodeWaveEarlyKillAcceptanceTests has a matrix entry with wave enabled")
    func waveAcceptanceSuiteIsWiredIntoCI() throws {
        let matrix = try loadMatrix()
        let entry = try #require(
            matrix.first { $0.filter.split(separator: "|").map(String.init).contains("XcodeWaveEarlyKillAcceptanceTests") },
            "no acceptance matrix entry runs XcodeWaveEarlyKillAcceptanceTests at all"
        )
        #expect(entry.simulator == "1", "wave acceptance needs a real Xcode/simulator destination")
        #expect(entry.wave == "1", "without wave: \"1\", Acceptance.waveEnabled stays false and this suite silently never runs")
    }

    /// Every matrix entry must declare a `simulator` value at all — an
    /// entry with none would leave `MUTANTKIT_ACCEPTANCE_SIMULATOR` unset in
    /// that job, silently defaulting to `Acceptance.simulatorEnabled`'s own
    /// fail-open behavior (unset -> enabled) rather than a deliberate
    /// per-fixture choice either way.
    @Test("Every matrix entry declares an explicit simulator value")
    func everyEntryDeclaresSimulatorExplicitly() throws {
        let matrix = try loadMatrix()
        for entry in matrix {
            let declared = entry.simulator.map { "\"\($0)\"" } ?? "<missing>"
            #expect(
                entry.simulator == "0" || entry.simulator == "1",
                "fixture '\(entry.fixture)' has simulator: \(declared), not an explicit \"0\" or \"1\""
            )
        }
    }
}

enum ClassificationTestError: Error, CustomStringConvertible {
    case fixturesFileNotFound(String)

    var description: String {
        switch self {
        case let .fixturesFileNotFound(root):
            "no Scripts/ci-fixtures.json found under \(root) at either Scripts/ or oss-public/Scripts/"
        }
    }
}
