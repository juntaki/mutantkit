import Foundation
import MutationModel
import Testing

/// `ConfigurationValidationTests` already covers most of `validate`'s branches;
/// this fills the specific rules a coverage audit found genuinely untested —
/// each one a real, independent `if` in `ConfigurationValidator.validate`/
/// `validateXcodeTestTargets`/`validateBudgetSelectionV2`, not exercised by
/// any existing test.
@Suite("Configuration validation: previously untested rules")
struct ConfigurationValidationUncoveredRulesTests {
    @Test("An unsupported configuration version is rejected")
    func unsupportedVersionIsRejected() {
        var configuration = Configuration()
        configuration.version = 2
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "version" && $0.severity == .error })
    }

    @Test("execution.budget.maxMutants below 1 is rejected")
    func maxMutantsBelowOneIsRejected() {
        var configuration = Configuration()
        configuration.execution.budget.maxMutants = 0
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "execution.budget.maxMutants" && $0.severity == .error })
    }

    @Test("execution.budget.maxDurationSeconds at or below zero is rejected")
    func maxDurationSecondsAtOrBelowZeroIsRejected() {
        for invalid: Double in [0, -1] {
            var configuration = Configuration()
            configuration.execution.budget.maxDurationSeconds = invalid
            let issues = ConfigurationValidator.validate(configuration)
            #expect(
                issues.contains { $0.path == "execution.budget.maxDurationSeconds" && $0.severity == .error },
                "\(invalid) should be rejected"
            )
        }
    }

    @Test("timeouts.baseline at or below zero is rejected")
    func baselineTimeoutAtOrBelowZeroIsRejected() {
        var configuration = Configuration()
        configuration.timeouts.baselineSeconds = 0
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "timeouts.baseline" && $0.severity == .error })
    }

    @Test("timeouts.mutant.minimum or maximum at or below zero is rejected regardless of strategy")
    func mutantTimeoutAtOrBelowZeroIsRejected() {
        var minimumZero = Configuration()
        minimumZero.timeouts.mutant.minimumSeconds = 0
        #expect(ConfigurationValidator.validate(minimumZero).contains { $0.path == "timeouts.mutant" && $0.severity == .error })

        var maximumZero = Configuration()
        maximumZero.timeouts.mutant.maximumSeconds = 0
        #expect(ConfigurationValidator.validate(maximumZero).contains { $0.path == "timeouts.mutant" && $0.severity == .error })
    }

    @Test("timeouts.mutant.multiplier at or below zero is rejected")
    func multiplierAtOrBelowZeroIsRejected() {
        var configuration = Configuration()
        configuration.timeouts.mutant.multiplier = 0
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "timeouts.mutant.multiplier" && $0.severity == .error })
    }

    // MARK: - validateXcodeTestTargets

    @Test("An Xcode project or workspace with no explicit test targets is flagged")
    func xcodeProjectWithNoTestTargetsIsFlagged() {
        for kind: ProjectKind in [.xcodeProject, .xcodeWorkspace] {
            var configuration = Configuration()
            configuration.project.kind = kind
            let issues = ConfigurationValidator.validate(configuration)
            #expect(
                issues.contains { $0.path == "tests.targets" && $0.severity == .warning },
                "\(kind) with no test targets should be flagged"
            )
        }
    }

    @Test("An Xcode project with explicit test targets is not flagged")
    func xcodeProjectWithTestTargetsIsNotFlagged() {
        var configuration = Configuration()
        configuration.project.kind = .xcodeProject
        configuration.tests.targets = ["AppTests"]
        let issues = ConfigurationValidator.validate(configuration)
        #expect(!issues.contains { $0.path == "tests.targets" })
    }

    @Test("A non-Xcode project kind with no test targets is not flagged")
    func nonXcodeProjectWithNoTestTargetsIsNotFlagged() {
        var configuration = Configuration()
        configuration.project.kind = .swiftPackageMacOS
        let issues = ConfigurationValidator.validate(configuration)
        #expect(!issues.contains { $0.path == "tests.targets" })
    }

    // MARK: - v1-only budget knobs set without selection: v2

    @Test("minimumPerStratum set without selection: v2 is flagged as ineffective")
    func minimumPerStratumWithoutV2IsFlagged() {
        var configuration = Configuration()
        configuration.execution.budget.minimumPerStratum = 3
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "execution.budget.minimumPerStratum" && $0.severity == .warning })
    }

    @Test("weight set without selection: v2 is flagged as ineffective")
    func weightWithoutV2IsFlagged() {
        var configuration = Configuration()
        configuration.execution.budget.weight = ["a": 1]
        let issues = ConfigurationValidator.validate(configuration)
        #expect(issues.contains { $0.path == "execution.budget.weight" && $0.severity == .warning })
    }

    // MARK: - Budget Selection v2's own field checks (still evaluated even though v2 itself is withdrawn)

    private func configuration(budget: BudgetSettings) -> Configuration {
        var configuration = Configuration()
        configuration.execution = ExecutionSettings(budget: budget)
        return configuration
    }

    @Test("A v2 configuration without maxMutants is rejected for that reason too, alongside the withdrawal")
    func v2WithoutMaxMutantsIsRejectedForMissingMaxMutants() {
        let issues = ConfigurationValidator.validate(
            configuration(budget: BudgetSettings(selection: .v2))
        )
        #expect(issues.contains {
            $0.severity == .error && $0.path == "execution.budget.selection" && $0.message.contains("maxMutants")
        })
    }

    @Test("v2's minimumPerStratum below 1 is rejected")
    func v2MinimumPerStratumBelowOneIsRejected() {
        let issues = ConfigurationValidator.validate(
            configuration(budget: BudgetSettings(maxMutants: 100, selection: .v2, minimumPerStratum: 0))
        )
        #expect(issues.contains { $0.path == "execution.budget.minimumPerStratum" && $0.severity == .error })
    }

    @Test("v2's weight values out of [1, 1_000_000] are rejected by stratum, valid ones are not")
    func v2WeightOutOfRangeIsRejectedPerStratum() {
        let issues = ConfigurationValidator.validate(
            configuration(budget: BudgetSettings(
                maxMutants: 100, selection: .v2,
                weight: ["tooLow": 0, "tooHigh": 1_000_001, "valid": 42]
            ))
        )
        #expect(issues.contains { $0.path == "execution.budget.weight.tooLow" && $0.severity == .error })
        #expect(issues.contains { $0.path == "execution.budget.weight.tooHigh" && $0.severity == .error })
        #expect(!issues.contains { $0.path == "execution.budget.weight.valid" })
    }
}
