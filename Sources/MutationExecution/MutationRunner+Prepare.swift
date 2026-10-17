import Foundation
import MutationModel
import SwiftFrontend

extension MutationRunner {
    /// The per-mutant context `prepare` threads through its steps: how a mutant's evaluation ends
    /// early with a finalized result.
    struct PrepareScope {
        let runner: MutationRunner
        let point: MutationPoint
        let startedAt: Date

        func finished(
            sourceApplication: SourceApplicationOutcome? = nil,
            build: BuildObservation? = nil,
            coverage: CoverageObservation? = nil,
            infrastructureFailureDiagnosis: String? = nil,
            buildDurationSeconds: Double? = nil
        ) async -> PrepareOutcome {
            .finished(await runner.evidenceAssembler.finalize(
                point: point,
                sourceApplication: sourceApplication,
                build: build,
                coverage: coverage,
                infrastructureFailureDiagnosis: infrastructureFailureDiagnosis,
                durationSeconds: Date().timeIntervalSince(startedAt),
                buildDurationSeconds: buildDurationSeconds
            ))
        }

        func infrastructureFailure(
            _ diagnosis: String, evidence: MutationEvidence? = nil, buildDurationSeconds: Double? = nil
        ) async -> PrepareOutcome {
            await finished(
                sourceApplication: evidence.map { .applied($0) },
                infrastructureFailureDiagnosis: diagnosis,
                buildDurationSeconds: buildDurationSeconds
            )
        }
    }

    /// Result of the build step of `prepare`: the artifact and how long the build took, or the
    /// finished outcome of a mutant that failed to build.
    enum PrepareBuildStep {
        case built(BuildArtifact, durationSeconds: Double)
        case failed(PrepareOutcome)
    }

    /// Result of the apply step of `prepare`: the applied mutation, or the finished outcome of a
    /// mutant that could not be applied.
    enum PrepareApplyStep {
        case applied(AppliedMutation)
        case failed(PrepareOutcome)
    }

    func applyMutation(in sandbox: Sandbox, scope: PrepareScope) async -> PrepareApplyStep {
        let point = scope.point
        let sourceURL: URL
        do {
            sourceURL = try workspaces.resolveSourceURL(in: sandbox, relativePath: point.file)
        } catch {
            return .failed(await scope.infrastructureFailure("\(point.file) could not be located inside the sandbox: \(error)"))
        }

        do {
            return .applied(try MutationApplication.applyInPlace(point, fileAt: sourceURL))
        } catch let error as ApplicationError {
            // No evidence is attached on purpose: for a mutation that was never
            // written, the absence of a diff is the honest record, and
            // `notApplied` is exempt from the phantom check for that reason.
            switch error {
            case let .anchorRejected(verification):
                return .failed(await scope.finished(sourceApplication: .notApplied(diagnosis: verification.diagnosis)))
            case let .unreadableFile(path, underlying):
                return .failed(await scope.infrastructureFailure("The sandboxed copy of \(path) could not be read: \(underlying)"))
            case let .unwritableFile(path, underlying):
                return .failed(await scope.infrastructureFailure("The mutation could not be written to \(path): \(underlying)"))
            }
        } catch {
            return .failed(await scope.infrastructureFailure("The mutation could not be applied: \(error)"))
        }
    }

    func buildMutant(_ applied: AppliedMutation, in sandbox: Sandbox, scope: PrepareScope) async -> PrepareBuildStep {
        let buildStarted = Date()
        do {
            let artifact = try await build.buildMutant(applied, in: sandbox.workspaceRoot)
            return .built(artifact, durationSeconds: Date().timeIntervalSince(buildStarted))
        } catch let first as BuildFailure {
            var failure = first
            // The baseline built (this mutant is only prepared after it did). A compiler that dies on the
            // mutated source and dies the same way again in an independent rebuild makes the mutant
            // unbuildable, like a compilation error; one crash alone, or two different crashes, stay an
            // infrastructure failure.
            if first.kind == .infrastructure, first.isCompilerCrashCandidate, let signature = first.compilerCrashSignature,
               await confirmationCoordinator.confirmCompilerCrash(scope.point, matching: signature) != nil {
                failure = BuildFailure(
                    kind: .confirmedCompilerCrash,
                    diagnosis: """
                    The compiler crashed on this mutant and crashed the same way again (same signal and compiler \
                    frames) in an independent rebuild in a fresh sandbox, while the unmutated baseline builds.
                    """,
                    command: first.command, output: first.output, isCompilerCrashCandidate: true
                )
            }
            return .failed(await scope.finished(
                sourceApplication: .applied(evidenceAssembler.evidence(applied, buildCommand: failure.command)),
                build: BuildObservation(outcome: .failed(kind: failure.kind, diagnosis: failure.diagnosis, command: failure.command)),
                buildDurationSeconds: Date().timeIntervalSince(buildStarted)
            ))
        } catch {
            return .failed(await scope.infrastructureFailure(
                "The mutant's build could not be run: \(error)",
                evidence: evidenceAssembler.evidence(applied),
                buildDurationSeconds: Date().timeIntervalSince(buildStarted)
            ))
        }
    }
}
