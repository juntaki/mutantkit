import ArgumentParser
import Foundation
import MutationModel

/// Finds and loads the evidence archive for a report, for `verify-run` and
/// `trust`. Both only read it; nothing here writes or repairs an archive.
enum EvidenceArchiveLocator {
    /// The archive at `explicit` when given (a missing directory is an
    /// operational error), else the one the report records, looked for under
    /// the project root and the root the report names. `nil` when there is
    /// none, which leaves the caller at Tier A.
    static func resolve(for report: RunReport, explicit: String?, root: URL, json: Bool) throws -> LoadedEvidenceArchive? {
        if let explicit {
            let directory = URL(fileURLWithPath: explicit)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                let message = "No evidence archive directory at \"\(explicit)\"."
                if json {
                    try JSONOutput.emitError(
                        code: "evidenceUnreadable", message: message,
                        remedy: "Pass the directory under .mutantkit/evidence/ written for this report's run."
                    )
                } else {
                    FileHandle.standardError.write(Data((message + "\n").utf8))
                }
                throw ExitCode(MutantKitExit.operationalError)
            }
            return EvidenceArchiveReader.load(directory: directory)
        }
        let roots = [root, URL(fileURLWithPath: report.projectRoot)]
        return EvidenceArchiveReader.discover(for: report, roots: roots).map(EvidenceArchiveReader.load(directory:))
    }

    /// The confirmation policy implied by the project's own configuration,
    /// but only when that configuration is the one the plan was made under
    /// (equal `configurationHash`). `nil` otherwise: the archive's policy is
    /// then not independently bound and is reported as such. The three policy
    /// flags are read straight from the configuration file; no profile or CLI
    /// option changes them.
    static func policyBoundToPlan(
        _ plan: MutationPlan?, configPath: String?, root: URL
    ) -> MutationVerdictVerifier.VerdictVerificationPolicy? {
        guard let plan,
              let configuration = try? ConfigurationLoader.load(explicitPath: configPath, projectRoot: root),
              configuration.configurationHash == plan.configurationHash
        else { return nil }
        return MutationVerdictVerifier.VerdictVerificationPolicy(configuration.execution)
    }
}
