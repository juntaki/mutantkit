import Foundation
import MutationModel

extension MutationEvidenceAssembler {
    /// Writes `observations` to the run's evidence archive, when one was
    /// requested. A failure is never swallowed and never allowed to touch the
    /// verdict already derived from those same observations. It is counted on
    /// the writer, which warns on stderr once; the run's report carries one
    /// aggregated operational issue, not one per mutant.
    func archiveEvidence(_ observations: MutationObservations, mutationID: MutationID) async {
        guard let evidenceArchive else { return }
        do {
            try evidenceArchive.record(observations)
        } catch {
            let diagnosis = "evidence archive write failed for \(mutationID): \(error)"
            if evidenceArchive.noteWriteFailure(diagnosis) {
                FileHandle.standardError.write(
                    Data("warning: \(diagnosis) (further archive write failures are counted, not repeated)\n".utf8)
                )
            }
        }
    }
}
