import Foundation
import MutationModel
import SwiftFrontend

extension VerifyRunCommand {
    /// Re-derives each result's source edit from the checkout: applying the
    /// point to the file it was anchored to must give the recorded
    /// `sourceAfterHash` and the recorded diff. A file that has changed since
    /// the run (or cannot be read or applied to) cannot be judged and is
    /// `notVerifiable`, never a pass; `source.anchors` reports the change.
    static func sourceEvidenceCheck(report: RunReport, root: URL) -> ReverificationCheck {
        let name = "evidence.sourceAfter"
        var sources: [String: Data?] = [:]
        var mismatched: [String] = []
        var unjudged: [String] = []
        var checked = 0
        for result in report.results {
            guard ReportReverifier.requiresSourceApplication(result.outcome), let evidence = result.evidence,
                  evidence.provesSourceApplication
            else { continue }
            let point = result.point
            if sources[point.file] == nil {
                sources[point.file] = .some(try? Data(contentsOf: root.appendingPathComponent(point.file)))
            }
            guard let data = sources[point.file] ?? nil,
                  ContentHash.of(data) == point.sourceFileHash,
                  let applied = try? MutationApplication.apply(point, to: data)
            else {
                unjudged.append(result.id.rawValue)
                continue
            }
            checked += 1
            if applied.evidence.sourceAfterHash != evidence.sourceAfterHash || applied.evidence.sourceDiff != evidence.sourceDiff {
                mismatched.append(result.id.rawValue)
            }
        }
        if !mismatched.isEmpty {
            return ReverificationCheck(
                name: name, status: .fail,
                detail: """
                \(mismatched.count) result(s): applying the point to the checkout does not give the recorded \
                sourceAfterHash and diff.
                """,
                mutationIDs: mismatched.sorted()
            )
        }
        if !unjudged.isEmpty {
            return ReverificationCheck(
                name: name, status: .notVerifiable,
                detail: """
                \(unjudged.count) result(s): the file under \(root.path) is missing or is not the one the point was \
                anchored to, so the recorded sourceAfterHash cannot be re-derived (\(checked) were).
                """,
                mutationIDs: unjudged.sorted()
            )
        }
        return ReverificationCheck(
            name: name, status: .pass,
            detail: "\(checked) result(s): applying the point to the checkout reproduces the recorded sourceAfterHash and diff."
        )
    }
}
