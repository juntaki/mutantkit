import Foundation
import Testing

/// Every macOS job in the projected workflows must select its Xcode
/// explicitly, never take the runner image's implicit default, and an exact
/// version assertion in a job must agree with the version that job selects.
///
/// Reads the real workflow files (as `WorkflowErrexitCaptureTests` does), so a
/// new macOS job or a half-finished toolchain move is caught by a unit test
/// instead of by a mixed-toolchain CI fleet that stays green.
@Suite("macOS workflow jobs pin Xcode explicitly and consistently")
struct WorkflowXcodePinTests {
    private struct Job {
        let file: String
        let id: String
        let runsOn: String
        let body: String

        var label: String { "\(file):\(id)" }

        /// The version in `xcode-select -s /Applications/Xcode_<version>.app`.
        var pinnedVersions: [String] { Self.matches(#"xcode-select -s /Applications/Xcode_([0-9.]+)\.app"#, in: body) }

        /// The version in an `!= "<version>"` comparison on `$xcode_version`.
        var assertedVersions: [String] { Self.matches(#"\$xcode_version" != "([0-9.]+)""#, in: body) }

        private static func matches(_ pattern: String, in text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            return regex.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
    }

    /// `ci.yml:lint` and `release-validation.yml:release-package` are the jobs
    /// that must carry the exact-version assertion on top of the pin.
    private static let jobsRequiringExactAssertion: Set<String> = [
        "ci.yml:lint",
        "release-validation.yml:release-package"
    ]

    private static func workflowsDirectory() -> URL? {
        let url = Acceptance.packageRoot.appendingPathComponent("oss-public/.github/workflows")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func jobs(in url: URL) throws -> [Job] {
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        guard let jobsIndex = lines.firstIndex(of: "jobs:") else { return [] }
        var result: [Job] = []
        var currentID: String?
        var currentLines: [String] = []

        func flush() {
            guard let id = currentID else { return }
            let body = currentLines.joined(separator: "\n")
            let runsOn = currentLines
                .first { $0.hasPrefix("    runs-on:") }
                .map { $0.dropFirst("    runs-on:".count).trimmingCharacters(in: .whitespaces) } ?? ""
            result.append(Job(file: url.lastPathComponent, id: id, runsOn: runsOn, body: body))
        }

        for line in lines[(jobsIndex + 1)...] {
            let isJobHeader = line.hasPrefix("  ") && !line.hasPrefix("   ") && line.hasSuffix(":")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            if isJobHeader {
                flush()
                currentID = line.trimmingCharacters(in: .whitespaces).dropLast().description
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        flush()
        return result
    }

    private static func macOSJobs() throws -> [Job] {
        guard let directory = workflowsDirectory() else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yml" }
            .sorted { $0.path < $1.path }
        return try files.flatMap { try jobs(in: $0) }
            .filter { $0.runsOn.hasPrefix("xcode-") || $0.runsOn.hasPrefix("macos-") }
    }

    @Test("Every macOS job selects its Xcode explicitly")
    func everyMacOSJobHasAnExplicitPin() throws {
        let jobs = try Self.macOSJobs()
        guard Self.workflowsDirectory() != nil else { return } // not a development checkout
        #expect(!jobs.isEmpty, "no macOS jobs found; the parser is likely broken")
        for job in jobs {
            #expect(job.pinnedVersions.count == 1, "\(job.label) (\(job.runsOn)) must have exactly one `xcode-select -s` pin")
        }
    }

    @Test("The runner image label and the pinned Xcode major version agree")
    func runnerLabelMatchesPin() throws {
        for job in try Self.macOSJobs() {
            guard let pin = job.pinnedVersions.first, let major = pin.split(separator: ".").first else { continue }
            let label = job.runsOn.replacingOccurrences(of: "-xlarge", with: "")
            #expect(
                label == "xcode-\(major)" || label == "macos-\(major)",
                "\(job.label) runs on \(job.runsOn) but pins Xcode \(pin)"
            )
        }
    }

    @Test("Exact-version assertions agree with the pin, and lint/release-package carry one")
    func exactAssertionsMatchPins() throws {
        let jobs = try Self.macOSJobs()
        for job in jobs {
            for asserted in job.assertedVersions {
                #expect(job.pinnedVersions == [asserted], "\(job.label) asserts \(asserted) but pins \(job.pinnedVersions)")
            }
            if Self.jobsRequiringExactAssertion.contains(job.label) {
                #expect(!job.assertedVersions.isEmpty, "\(job.label) must assert the exact Xcode version")
            }
        }
        if Self.workflowsDirectory() != nil {
            for label in Self.jobsRequiringExactAssertion {
                #expect(jobs.contains { $0.label == label }, "\(label) not found; update this test if the job was renamed")
            }
        }
    }
}
