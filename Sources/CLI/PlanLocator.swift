import Foundation
import MutationModel

/// Finds the plan a report names when none was passed explicitly.
///
/// A candidate is accepted only when it decodes as a plan and its `planID`
/// equals the report's. Anything else is ignored rather than reported: a
/// stray file is not evidence, and a missing plan simply leaves the
/// plan-dependent checks not verifiable.
enum PlanLocator {
    struct Found {
        let plan: MutationPlan
        let path: String
    }

    /// Looks beside the report, then in the project root and its
    /// `.mutantkit` directory, then in the working directory and the root the
    /// report records, for a `plan.json` with the report's plan ID.
    static func discover(for report: RunReport, reportPath: String, root: URL, workingDirectory: URL? = nil) -> Found? {
        let reportDirectory = URL(fileURLWithPath: reportPath).deletingLastPathComponent()
        let cwd = workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let recordedRoot = URL(fileURLWithPath: report.projectRoot)
        let directories = [
            reportDirectory,
            root, root.appendingPathComponent(".mutantkit"),
            cwd, cwd.appendingPathComponent(".mutantkit"),
            recordedRoot, recordedRoot.appendingPathComponent(".mutantkit")
        ]
        var seen = Set<String>()
        for directory in directories {
            let candidate = directory.appendingPathComponent("plan.json").standardizedFileURL
            guard seen.insert(candidate.path).inserted,
                  let data = try? Data(contentsOf: candidate),
                  let plan = try? MutationPlan.decode(from: data),
                  plan.planID == report.planID
            else { continue }
            return Found(plan: plan, path: candidate.path)
        }
        return nil
    }
}
