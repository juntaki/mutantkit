import Foundation
import MutationModel

/// The unmutated build products, kept for the whole run so a kill's baseline
/// control can run them, plus a memo of the control runs made so far.
///
/// A control is the same tests, the same selection, run on the unmutated build
/// in a fresh clone of these products. Because the products and the selection
/// fully determine what runs, two kills with the same selection share one
/// control run: with whole-suite runs that is one extra execution per run, not
/// one per kill. The trade-off is that the control is not adjacent in time to
/// each kill's retest, so a fault that appears and disappears between the two
/// is not seen by it; a fault that is deterministic for the environment, which
/// is what a same-artifact retest cannot rule out, is.
///
/// Only established when `retestKilledMutants` is on; with it off nothing here
/// exists and no extra work is done.
actor BaselineControlSource {
    /// The retained clone, destroyed by `teardown()`. It already has the shape
    /// the adapter needs (see `WorkspaceManager.cloneProductsForConfirmationRetest`:
    /// nested under the products' scratch-relative path for SwiftPM, flat
    /// otherwise), so every control run copies it as it is, whatever layout
    /// the toolchain gave the products.
    nonisolated let retained: URL
    nonisolated let workspaces: WorkspaceManager
    nonisolated let artifact: BuildArtifact
    nonisolated let memo = BaselineControlMemo()

    private init(retained: URL, workspaces: WorkspaceManager, artifact: BuildArtifact) {
        self.retained = retained
        self.workspaces = workspaces
        self.artifact = artifact
    }

    /// Clones the baseline's just-built, not-yet-tested products, or returns
    /// `nil` when no control is needed (`retestKilledMutants` is off, no `workspaces`)
    /// or the products cannot be cloned (the control is then simply unavailable
    /// and kills stay unconfirmed; nothing else is affected).
    ///
    /// Called right after the baseline build, before the baseline test run:
    /// that run may instrument the products, and the control must run the same
    /// uninstrumented products a mutant's retest does.
    static func establish(
        _ execution: ExecutionSettings, from artifact: BuildArtifact, workspaces: WorkspaceManager?, test: any TestAdapter
    ) async -> BaselineControlSource? {
        guard execution.retestKilledMutants, let workspaces else { return nil }
        do {
            let retained = try await workspaces.cloneProductsForConfirmationRetest(
                from: artifact.productsDirectory, id: "baseline-control", for: test
            )
            return BaselineControlSource(retained: retained, workspaces: workspaces, artifact: artifact)
        } catch {
            return nil
        }
    }

    func teardown() async {
        try? await workspaces.destroyProductsClone(at: retained)
    }

    /// Runs `body`, then disposes of `source` whether it returned or threw.
    static func disposing<T>(_ source: BaselineControlSource?, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            await source?.teardown()
            return value
        } catch {
            await source?.teardown()
            throw error
        }
    }
}

/// One control run per key, shared by every caller that asks for the same key
/// while or after it runs.
///
/// A control that could not be established for a transient reason (it timed
/// out, hit an infrastructure failure, or produced no per-test summary) is not
/// kept for the rest of the run: the next request for that key runs it again,
/// up to `maximumAttempts` runs per key, after which the last observation
/// stands. Callers already waiting on a run all receive its result. A retry
/// can only let a later kill be confirmed by a control that now ran cleanly;
/// no earlier result is revisited, and a control never turns a non-kill into a
/// kill, so a kill can still only be lost, never gained, through it.
actor BaselineControlMemo {
    static let maximumAttempts = 3

    private var runs: [String: Task<BaselineControlObservation, Never>] = [:]
    private var attempts: [String: Int] = [:]
    private var started = 0

    /// How many control runs were started, including bounded retries.
    var startedCount: Int { started }

    func observation(
        key: String, produce: @escaping @Sendable () async -> BaselineControlObservation
    ) async -> BaselineControlObservation {
        if let existing = runs[key] { return await existing.value }
        let task = Task { await produce() }
        runs[key] = task
        attempts[key, default: 0] += 1
        started += 1
        let observation = await task.value
        if observation.isTransientlyNotEstablished, attempts[key, default: 0] < Self.maximumAttempts {
            runs[key] = nil
        }
        return observation
    }
}

extension BaselineControlObservation {
    /// A control whose outcome says nothing about the tests or the build and
    /// may differ on another run: no verdict (timeout, infrastructure failure)
    /// or a pass with no per-test summary. A crash or a failing run is a
    /// result, not a transient, and is kept.
    var isTransientlyNotEstablished: Bool {
        switch run.status {
        case .timedOut, .infrastructureFailure:
            return true
        case .passed:
            return (run.summary?.total ?? 0) == 0
        case .failed, .crashed:
            return false
        }
    }
}
