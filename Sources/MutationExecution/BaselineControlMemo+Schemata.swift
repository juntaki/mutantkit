import Foundation
import MutationModel

extension BaselineControlMemo {
    /// The kill's baseline control for a schemata chunk: the already-built chunk
    /// run with no selector token, so nothing activates and the original code
    /// runs, in the same sandbox and with the same selection. Shared by every
    /// kill in the chunk with that selection (one extra execution per distinct
    /// selection per chunk build, not per kill).
    func schemataControl(
        test: any SchemataTestable, artifact: BuildArtifact, in sandbox: URL, timeoutSeconds: Double,
        selectedTests: Set<TestIdentifier>?
    ) async -> BaselineControlObservation {
        let selection = (selectedTests ?? []).map(\.onlyTestingArgument).sorted()
        let key = artifact.productsDirectory.path + "\n" + (selection.isEmpty ? "whole-suite" : selection.joined(separator: "\n"))
        return await observation(key: key) {
            let run: TestRunResult
            do {
                run = try await test.runSchemataToken(
                    artifact, in: sandbox, timeoutSeconds: timeoutSeconds, environment: [:], selectedTests: selectedTests
                )
            } catch {
                run = TestRunResult(
                    status: .infrastructureFailure, summary: nil,
                    command: CommandRecord(executable: "", arguments: [], workingDirectory: ""),
                    resultArtifactPath: nil, diagnosis: "the baseline control run could not be started: \(error)"
                )
            }
            return BaselineControlObservation(method: .unmutatedSchemataRun, run: run, selectedTests: selection)
        }
    }
}
