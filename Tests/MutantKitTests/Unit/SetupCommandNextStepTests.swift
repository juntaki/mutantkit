@testable import CLI
import Testing

/// `mutantkit setup`'s "what do I tell the user next" decision, pinned
/// directly: `--dry-run` never writes anything, but its outcome still turns
/// on whether the *previewed* config actually passes readiness — a real
/// diagnosed failure of that preview must read differently from one that
/// passes, not collapse into the same "preview done" bucket regardless. An
/// unresolved scheme/test target must not be silently guessed away, and only
/// a genuine `doctor`-style readiness failure should make `setup` itself
/// report "not ready" or exit non-zero — the same contract `init` and
/// `doctor` already have individually.
@Suite("SetupCommand.nextStep")
struct SetupCommandNextStepTests {
    @Test("--dry-run with a ready preview reports previewOnly, regardless of scheme/test-target ambiguity")
    func dryRunReadyReportsPreviewOnly() {
        #expect(SetupCommand.nextStep(dryRun: true, hasTestTargets: true, schemeAmbiguous: false, environmentReady: true) == .previewOnly)
        #expect(SetupCommand.nextStep(dryRun: true, hasTestTargets: false, schemeAmbiguous: true, environmentReady: true) == .previewOnly)
    }

    @Test("--dry-run with a genuinely failing preview reports previewNotReady, not a silent previewOnly")
    func dryRunNotReadyReportsPreviewNotReady() {
        let resolved = SetupCommand.nextStep(dryRun: true, hasTestTargets: true, schemeAmbiguous: false, environmentReady: false)
        #expect(resolved == .previewNotReady)
        let unresolved = SetupCommand.nextStep(dryRun: true, hasTestTargets: false, schemeAmbiguous: true, environmentReady: false)
        #expect(unresolved == .previewNotReady)
    }

    @Test("An ambiguous scheme is reported, not silently resolved, even when the environment is otherwise ready")
    func ambiguousSchemeIsReported() {
        let step = SetupCommand.nextStep(dryRun: false, hasTestTargets: true, schemeAmbiguous: true, environmentReady: true)
        guard case let .needsManualCompletion(details) = step else {
            Issue.record("expected .needsManualCompletion, got \(step)")
            return
        }
        #expect(details.contains("the ambiguous Xcode scheme"))
        #expect(!details.contains("the missing test target(s)"))
    }

    @Test("Missing test targets is reported, not silently left empty, even when the environment is otherwise ready")
    func missingTestTargetsIsReported() {
        let step = SetupCommand.nextStep(dryRun: false, hasTestTargets: false, schemeAmbiguous: false, environmentReady: true)
        guard case let .needsManualCompletion(details) = step else {
            Issue.record("expected .needsManualCompletion, got \(step)")
            return
        }
        #expect(details.contains("the missing test target(s)"))
        #expect(!details.contains("the ambiguous Xcode scheme"))
    }

    @Test("Both an ambiguous scheme and missing test targets are reported together")
    func bothUnresolvedAreReportedTogether() {
        let step = SetupCommand.nextStep(dryRun: false, hasTestTargets: false, schemeAmbiguous: true, environmentReady: true)
        guard case let .needsManualCompletion(details) = step else {
            Issue.record("expected .needsManualCompletion, got \(step)")
            return
        }
        #expect(details.count == 2)
    }

    @Test("Unresolved detection outranks a failed readiness check — the ambiguity is the more actionable fact")
    func unresolvedDetectionOutranksReadinessFailure() {
        let step = SetupCommand.nextStep(dryRun: false, hasTestTargets: false, schemeAmbiguous: false, environmentReady: false)
        guard case .needsManualCompletion = step else {
            Issue.record("expected .needsManualCompletion, got \(step)")
            return
        }
    }

    @Test("A resolved config with a failed readiness check reports environmentNotReady, matching doctor's own exit behavior")
    func resolvedConfigWithFailedReadinessReportsNotReady() {
        let step = SetupCommand.nextStep(dryRun: false, hasTestTargets: true, schemeAmbiguous: false, environmentReady: false)
        #expect(step == .environmentNotReady)
    }

    @Test("Fully resolved and ready reports ready")
    func fullyResolvedAndReadyReportsReady() {
        #expect(SetupCommand.nextStep(dryRun: false, hasTestTargets: true, schemeAmbiguous: false, environmentReady: true) == .ready)
    }

    @Test("Every message mentions the config path and the ready message names the actual next commands")
    func messagesAreConcrete() {
        let path = "/tmp/project/mutantkit.yml"
        let unresolved = SetupCommand.NextStep.needsManualCompletion(details: ["the ambiguous Xcode scheme"])
        #expect(SetupCommand.message(for: .previewOnly, configPath: path).contains(path))
        #expect(SetupCommand.message(for: .previewNotReady, configPath: path).contains(path))
        #expect(SetupCommand.message(for: unresolved, configPath: path).contains(path))
        #expect(SetupCommand.message(for: unresolved, configPath: path).contains("the ambiguous Xcode scheme"))

        let ready = SetupCommand.message(for: .ready, configPath: path)
        #expect(ready.contains("mutantkit dry-run"))
        #expect(ready.contains("mutantkit plan"))
        #expect(ready.contains("mutantkit run --fail-on-survivors"))
    }
}
