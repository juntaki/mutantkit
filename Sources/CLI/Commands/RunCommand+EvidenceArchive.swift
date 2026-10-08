import Foundation
import MutationExecution
import MutationModel

extension RunCommand {
    /// Closes the run's evidence archive and records it in the report.
    ///
    /// Adds the archive reference and any archive problems as operational
    /// issues; every verdict, the integrity record and the score are carried
    /// over unchanged. A failure to write the manifest is reported, not
    /// thrown: the run's results stand without an archive.
    static func sealEvidenceArchive(_ archive: EvidenceArchiveWriter?, in report: RunReport, keep: Int? = nil) -> RunReport {
        guard let archive else { return report }
        var issues: [OperationalIssue] = []
        var reference: EvidenceArchiveReference?
        do {
            reference = try archive.seal()
        } catch {
            let diagnosis = "evidence archive manifest could not be written: \(error)"
            FileHandle.standardError.write(Data("warning: \(diagnosis)\n".utf8))
            issues.append(OperationalIssue(severity: .warning, kind: .evidenceArchiveWriteFailed, mutationID: nil, diagnosis: diagnosis))
        }
        let failures = archive.writeFailureSummary
        if failures.count > 0 {
            issues.append(OperationalIssue(
                severity: .warning, kind: .evidenceArchiveWriteFailed, mutationID: nil,
                diagnosis: "evidence archive write failed for \(failures.count) mutation(s); first: \(failures.first ?? "unknown")"
            ))
        }
        let archived = archive.recordedCount
        if archived < report.results.count {
            issues.append(OperationalIssue(
                severity: .warning, kind: .evidenceArchiveIncomplete, mutationID: nil,
                diagnosis: """
                evidence archive holds observations for \(archived) of \(report.results.count) result(s); the rest were \
                resumed from a checkpoint, served from the cache, or embedded by the schemata strategy, and cannot be \
                re-verified from it
                """
            ))
        }
        if let reference {
            print("Evidence archive: \(archive.directory.path) (\(reference.entryCount) observation file(s))")
            if let keep {
                pruneOldArchives(of: archive, keep: keep)
            }
        }
        return report.attachingEvidenceArchive(reference, additionalIssues: issues)
    }

    /// Applies `evidence.keep` once the run's own archive is sealed.
    private static func pruneOldArchives(of archive: EvidenceArchiveWriter, keep: Int) {
        let outcome = EvidenceArchivePruner.prune(
            root: archive.directory.deletingLastPathComponent(), keep: keep, current: archive.runID
        )
        if !outcome.removed.isEmpty {
            print("Evidence archives: removed \(outcome.removed.count) older than the newest \(keep) (evidence.keep)")
        }
        for failure in outcome.failures {
            FileHandle.standardError.write(Data("warning: could not remove an old evidence archive: \(failure)\n".utf8))
        }
    }
}
