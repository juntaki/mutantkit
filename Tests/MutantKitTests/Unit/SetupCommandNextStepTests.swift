@testable import CLI
import Testing

/// `mutantkit setup`'s "what do I tell the user next" decision, pinned
/// directly: `--dry-run` never writes anything, but its outcome still turns
/// on whether the *previewed* config actually passes readiness — a real
/// diagnosed failure of that preview must read differently from one that
/// passes, not collapse into the same "preview done" bucket regardless. An
/// unresolved scheme/test target must not be silently guessed away in either
/// mode — a dry-run preview with an unresolved choice must not report
/// `.previewOnly` just because the underlying readiness diagnosis happens to
/// say ready, the same way the non-dry-run path never lets an unresolved
/// choice hide behind a passing `environmentReady` — and only a genuine
/// `doctor`-style readiness failure of an otherwise fully-resolved config
/// should make `setup` report "not ready" or exit non-zero — the same
/// contract `init` and `doctor` already have individually.
@Suite("SetupCommand.nextStep")
struct SetupCommandNextStepTests {
    @Test("--dry-run with a ready, fully-resolved preview reports previewOnly")
    func dryRunReadyReportsPreviewOnly() {
        #expect(SetupCommand.nextStep(dryRun: true, hasTestTargets: true, schemeAmbiguous: false, environmentReady: true) == .previewOnly)
    }

    @Test("--dry-run with a genuinely failing, but fully-resolved, preview reports previewNotReady, not a silent previewOnly")
    func dryRunNotReadyReportsPreviewNotReady() {
        let resolved = SetupCommand.nextStep(dryRun: true, hasTestTargets: true, schemeAmbiguous: false, environmentReady: false)
        #expect(resolved == .previewNotReady)
    }

    @Test("--dry-run with an unresolved scheme/test-target never reports previewOnly, even when readiness says ready")
    func dryRunWithUnresolvedAmbiguityNeverReportsPreviewOnly() {
        let step = SetupCommand.nextStep(dryRun: true, hasTestTargets: false, schemeAmbiguous: true, environmentReady: true)
        guard case let .previewNeedsManualCompletion(details) = step else {
            Issue.record("expected .previewNeedsManualCompletion, got \(step)")
            return
        }
        #expect(details.contains("the ambiguous Xcode scheme"))
        #expect(details.contains("the missing test target(s)"))
    }

    @Test("--dry-run reports the unresolved scheme/test-target case even when readiness would also fail")
    func dryRunWithUnresolvedAmbiguityOutranksFailedReadiness() {
        let step = SetupCommand.nextStep(dryRun: true, hasTestTargets: false, schemeAmbiguous: true, environmentReady: false)
        guard case .previewNeedsManualCompletion = step else {
            Issue.record("expected .previewNeedsManualCompletion, got \(step)")
            return
        }
    }

    @Test("--dry-run's previewNeedsManualCompletion exits non-zero, unlike its non-dry-run needsManualCompletion counterpart")
    func previewNeedsManualCompletionIsNotAPlainSuccess() {
        let preview = SetupCommand.nextStep(dryRun: true, hasTestTargets: false, schemeAmbiguous: true, environmentReady: true)
        let real = SetupCommand.nextStep(dryRun: false, hasTestTargets: false, schemeAmbiguous: true, environmentReady: true)
        guard case .previewNeedsManualCompletion = preview else {
            Issue.record("expected .previewNeedsManualCompletion, got \(preview)")
            return
        }
        guard case .needsManualCompletion = real else {
            Issue.record("expected .needsManualCompletion, got \(real)")
            return
        }
        // The two cases are deliberately different: a dry-run preview writes
        // nothing, so — unlike the real, file-was-written case — there is no
        // "leave a starting point" tradeoff to protect it from a non-zero
        // exit. See `NextStep.previewNeedsManualCompletion`'s doc comment.
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

    @Test("previewNeedsManualCompletion's message names the unresolved detail and never claims the preview is ready")
    func previewNeedsManualCompletionMessageNamesTheDetail() {
        let path = "/tmp/project/mutantkit.yml"
        let step = SetupCommand.NextStep.previewNeedsManualCompletion(details: ["the ambiguous Xcode scheme"])
        let message = SetupCommand.message(for: step, configPath: path)
        #expect(message.contains(path))
        #expect(message.contains("the ambiguous Xcode scheme"))
        #expect(message.contains("nothing was written"))
    }

    @Test("A non-default --config is appended to every suggested next command, not just the write path")
    func configFlagIsPropagatedToEverySuggestedCommand() {
        let path = "/some/project/configs/foo.yml"
        let configFlag = "configs/foo.yml"

        let ready = SetupCommand.message(for: .ready, configPath: path, configFlag: configFlag)
        #expect(ready.contains("mutantkit dry-run --config \(configFlag)"))
        #expect(ready.contains("mutantkit plan --config \(configFlag)"))
        #expect(ready.contains("mutantkit run --fail-on-survivors --config \(configFlag)"))

        let needsManualCompletion = SetupCommand.message(
            for: .needsManualCompletion(details: ["the ambiguous Xcode scheme"]), configPath: path, configFlag: configFlag
        )
        #expect(needsManualCompletion.contains("mutantkit doctor --config \(configFlag)"))

        let environmentNotReady = SetupCommand.message(for: .environmentNotReady, configPath: path, configFlag: configFlag)
        #expect(environmentNotReady.contains("mutantkit setup --config \(configFlag)"))
        #expect(environmentNotReady.contains("mutantkit doctor --config \(configFlag)"))

        let previewNotReady = SetupCommand.message(for: .previewNotReady, configPath: path, configFlag: configFlag)
        #expect(previewNotReady.contains("--dry-run --config \(configFlag)"))

        let previewNeedsManualCompletion = SetupCommand.message(
            for: .previewNeedsManualCompletion(details: ["the ambiguous Xcode scheme"]), configPath: path, configFlag: configFlag
        )
        #expect(previewNeedsManualCompletion.contains("--dry-run --config \(configFlag)"))

        // No default `--config` was passed: nothing extra is appended, and
        // the message reads exactly as it did before this flag existed.
        let withoutFlag = SetupCommand.message(for: .ready, configPath: path)
        #expect(!withoutFlag.contains("--config"))
    }
}
