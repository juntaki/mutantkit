import Foundation
import Testing

/// Turns a one-time audit into a permanent gate, the same way
/// `ProcessSupervisorBypassRegressionTests` and
/// `DocumentedVersionPinConsistencyTests` do — this time over the prose
/// this repository actually ships.
///
/// The audit: `skills/mutantkit/SKILL.md` — shipped as a Claude Code and
/// Codex plugin skill, and therefore read by an agent that then edits a
/// user's `mutantkit.yml` — told that agent, unconditionally, that
/// "`schemata` is faster and supported for `swiftPackageMacOS` and
/// `xcodeProject`". In this project's own vocabulary `xcodeProject` means
/// an Xcode project on the iOS Simulator (it is the only schemata-Supported
/// `xcodeProject` row in `docs/schemata-support-matrix.md`, and
/// `docs/apple-support-matrix.md` and
/// `Sources/CLI/ExecutionCapabilitiesDiagnosis.swift`'s own remedy text
/// agree). That is exactly the platform `ADR/0009-ios-execution-default.md`
/// — status "Accepted, implemented" — measured at **6383s schemata versus
/// 3928s isolated, +62.5%**, with the gap widening as the corpus grew, and
/// on that evidence made `isolated` the default and `schemata` an explicit
/// opt-in "for advanced or research use".
///
/// The same sentence cited `docs/schemata-support-matrix.md` as "the full,
/// measured matrix" backing the speed claim, while that document's own
/// opening disclaims performance outright: "actual performance is
/// workload-dependent, and this is not a benchmarking claim". The cited
/// source refuted the claim it was cited for.
///
/// Nothing mechanical could have caught either: a grep of `Tests/`,
/// `Sources/`, `Scripts/` and `.github/` for `SKILL.md` returns no hits.
/// The shipped skill's text was entirely unguarded, while the
/// code-and-doc pair it contradicted was not.
///
/// Neither rule below is a style check. Each encodes one fact this
/// repository has already paid to establish, and each was verified to
/// fail against the exact wording that shipped.
@Suite("Regression: shipped guidance does not contradict measured performance")
struct ShippedGuidancePerformanceClaimTests {
    /// `#filePath`-anchored so it resolves identically here and in a
    /// projected public snapshot.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Regression
            .deletingLastPathComponent() // MutantKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    /// Prose a user or an agent actually reads. `Research/` is deliberately
    /// excluded: it is where provisional and superseded measurements are
    /// supposed to live, and it does not ship.
    private static var shippedProse: [URL] {
        let root = repositoryRoot
        var files = [root.appendingPathComponent("README.md")]
        for directory in ["docs", "skills"] {
            let base = root.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "md" {
                files.append(url)
            }
        }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    struct Paragraph {
        let file: String
        let line: Int
        let text: String
    }

    /// Blank-line separated blocks, carrying the line each starts on so a
    /// failure names somewhere a maintainer can open.
    static func paragraphs(of text: String, file: String) -> [Paragraph] {
        var result: [Paragraph] = []
        var current: [String] = []
        var start = 1
        for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(Paragraph(file: file, line: start, text: current.joined(separator: " "))) }
                current = []
                start = offset + 2
            } else {
                if current.isEmpty { start = offset + 1 }
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(Paragraph(file: file, line: start, text: current.joined(separator: " "))) }
        return result
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    // MARK: - Rule A: an iOS speed claim must cite the ADR that measured it

    /// A paragraph that makes a speed claim *and* names the iOS/Xcode
    /// execution surface must cite ADR-0009. The ADR is what turned that
    /// comparison from an opinion into a measurement; a shipped claim about
    /// it that does not point at the measurement is how the original defect
    /// read.
    static func iOSSpeedClaimsMissingTheADR(in paragraph: Paragraph) -> Bool {
        let lower = paragraph.text.lowercased()
        let makesSpeedClaim = containsAny(lower, ["faster", "slower", "speedup", "quicker"])
        let namesIOSSurface = containsAny(lower, ["xcodeproject", "ios simulator", "ios-simulator"])
        let citesTheADR = containsAny(paragraph.text, ["ADR/0009", "ADR-0009"])
        return makesSpeedClaim && namesIOSSurface && !citesTheADR
    }

    @Test("No shipped paragraph claims an iOS/Xcode execution speed without citing ADR-0009")
    func iOSSpeedClaimsCiteTheMeasurement() throws {
        var offenders: [Paragraph] = []
        var scanned = 0
        for file in Self.shippedProse {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
            for paragraph in Self.paragraphs(of: text, file: relative) {
                scanned += 1
                if Self.iOSSpeedClaimsMissingTheADR(in: paragraph) { offenders.append(paragraph) }
            }
        }

        // A scan that matched nothing would be a silent pass.
        #expect(scanned > 0, "no shipped prose was scanned; the file set is wrong")

        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) shipped paragraph(s) make an iOS/Xcode speed claim without citing \
            ADR/0009-ios-execution-default.md, which measured schemata at +62.5% wall clock \
            (6383s vs 3928s) on a real 100-mutant iOS corpus and made isolated the default there:
            \(offenders.map { "\($0.file):\($0.line) — \($0.text.prefix(220))" }.joined(separator: "\n\n"))
            """
        )
    }

    // MARK: - Rule B: the support matrix is not a benchmark

    /// `docs/schemata-support-matrix.md` states in its own opening that
    /// "actual performance is workload-dependent, and this is not a
    /// benchmarking claim". Describing it as a measured or benchmarked
    /// matrix — as the shipped skill did — cites it for the one thing it
    /// refuses to say. Commas are stripped first so "the full, measured
    /// matrix" is caught as readily as "the full measured matrix".
    static func miscitesTheSupportMatrix(_ paragraph: Paragraph) -> Bool {
        guard paragraph.text.contains("schemata-support-matrix.md") else { return false }
        let normalized = paragraph.text.replacingOccurrences(of: ",", with: "").lowercased()
        return containsAny(normalized, ["measured matrix", "benchmarked matrix", "benchmark matrix"])
    }

    @Test("No shipped paragraph cites the schemata support matrix as a benchmark")
    func supportMatrixIsNotCitedAsABenchmark() throws {
        var offenders: [Paragraph] = []
        for file in Self.shippedProse {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: Self.repositoryRoot.path + "/", with: "")
            offenders += Self.paragraphs(of: text, file: relative).filter(Self.miscitesTheSupportMatrix)
        }

        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) shipped paragraph(s) describe docs/schemata-support-matrix.md as a \
            measured or benchmarked matrix. That document disclaims performance in its own opening \
            ("this is not a benchmarking claim") and contains no speed column at all:
            \(offenders.map { "\($0.file):\($0.line) — \($0.text.prefix(220))" }.joined(separator: "\n\n"))
            """
        )
    }

    // MARK: - The rules are tested against the wording that actually shipped

    /// Verbatim from `skills/mutantkit/SKILL.md` before the fix. If either
    /// rule stops flagging this, the gate has stopped gating.
    private static let shippedDefect = """
    `execution.strategy` (`isolated` default; `schemata` is faster and supported
    for `swiftPackageMacOS` and `xcodeProject` — see
    `docs/schemata-support-matrix.md` for the full, measured matrix, including
    `swiftPackageApple`/`xcodeWorkspace`, which still fall back to isolated for
    every mutation today).
    """

    @Test("Rule A flags the exact paragraph that shipped")
    func ruleAFlagsTheRealDefect() {
        let paragraph = try? #require(Self.paragraphs(of: Self.shippedDefect, file: "fixture.md").first)
        #expect(paragraph.map(Self.iOSSpeedClaimsMissingTheADR) == true)
    }

    @Test("Rule B flags the exact paragraph that shipped")
    func ruleBFlagsTheRealDefect() {
        let paragraph = try? #require(Self.paragraphs(of: Self.shippedDefect, file: "fixture.md").first)
        #expect(paragraph.map(Self.miscitesTheSupportMatrix) == true)
    }

    @Test("Rule A accepts an iOS speed claim that does cite the ADR")
    func ruleAAcceptsACitedClaim() {
        let text = "on Xcode/iOS-Simulator schemata measured 62.5% slower — see `ADR/0009-ios-execution-default.md`."
        let paragraph = Self.paragraphs(of: text, file: "fixture.md")[0]
        #expect(!Self.iOSSpeedClaimsMissingTheADR(in: paragraph))
    }

    @Test("Rule A ignores a speed claim that names no iOS surface")
    func ruleAIgnoresNonIOSClaims() {
        let text = "incrementalBuild makes a SwiftPM/macOS run substantially faster."
        let paragraph = Self.paragraphs(of: text, file: "fixture.md")[0]
        #expect(!Self.iOSSpeedClaimsMissingTheADR(in: paragraph))
    }

    @Test("Rule B ignores a paragraph that cites the matrix for support, not speed")
    func ruleBIgnoresSupportCitations() {
        let text = "see `docs/schemata-support-matrix.md` for the full support matrix."
        let paragraph = Self.paragraphs(of: text, file: "fixture.md")[0]
        #expect(!Self.miscitesTheSupportMatrix(paragraph))
    }
}
