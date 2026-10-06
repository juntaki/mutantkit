import Foundation
import MutationModel

extension MutationConfirmationCoordinator {
    /// The baseline control for a kill whose retest just reproduced the
    /// failure: the same selection run on the unmutated build products.
    /// `nil` when no control source exists for this run (the verifier then
    /// treats the kill as not controlled).
    ///
    /// Memoized per selection (`BaselineControlSource.observation`), so the
    /// extra cost is one execution per distinct selection, not per kill.
    func baselineControl(
        for point: MutationPoint, baseline: MutationRunner.BaselineContext, selectedTests: Set<TestIdentifier>?
    ) async -> BaselineControlObservation? {
        guard let source = baseline.control else { return nil }
        let selection = (selectedTests ?? []).map(\.onlyTestingArgument).sorted()
        let timeoutSeconds = baseline.timeouts.mutantLimitSeconds(selectedTests: selectedTests)
        let key = selection.isEmpty ? "whole-suite" : selection.joined(separator: "\n")
        let artifact = source.artifact
        let retained = source.retained
        let workspaces = source.workspaces
        return await source.memo.observation(key: key) {
            let run = await runControl(
                point, artifact: artifact, retained: retained, workspaces: workspaces,
                selectedTests: selectedTests, timeoutSeconds: timeoutSeconds
            )
            return BaselineControlObservation(method: .unmutatedBuildProducts, run: run, selectedTests: selection)
        }
    }

    private func runControl(
        _ point: MutationPoint, artifact: BuildArtifact, retained: URL, workspaces: WorkspaceManager,
        selectedTests: Set<TestIdentifier>?, timeoutSeconds: Double
    ) async -> TestRunResult {
        let clone: URL
        do {
            clone = try await workspaces.cloneProducts(
                from: retained, id: "baseline-control-\(UUID().uuidString)"
            )
        } catch {
            return infrastructureFailureRun("the baseline control workspace could not be cloned: \(error)")
        }
        let relocated = BuildArtifact(
            productsDirectory: clone, productHash: artifact.productHash,
            xctestrunPath: artifact.xctestrunPath.map { clone.appendingPathComponent($0.lastPathComponent) },
            command: artifact.command
        )
        let run: TestRunResult
        do {
            if let manifestDependent = manifestDependentTest {
                run = try await manifestDependent.runConfirmationRetest(
                    point, packageRoot: projectRoot, productsScratchRoot: clone,
                    timeoutSeconds: timeoutSeconds, selectedTests: selectedTests
                )
            } else {
                run = try await runMutantTests(
                    point, artifact: relocated, in: clone, timeoutSeconds: timeoutSeconds, selectedTests: selectedTests
                )
            }
        } catch {
            run = infrastructureFailureRun("the baseline control run could not be started: \(error)")
        }
        try? await workspaces.destroyProductsClone(at: clone)
        return run
    }
}
