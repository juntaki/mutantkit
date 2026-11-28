@testable import CLI
import Foundation
import MutationModel
import Testing
import Yams

/// Every numeric setting is finite and in a meaningful range, whichever way the
/// value arrived (YAML, JSON, direct construction), and identity never degrades
/// to a shared sentinel.
@Suite("Configuration: numeric input is finite and in range")
struct ConfigurationNumericInputTests {
    private func errorPaths(_ configuration: Configuration) -> Set<String> {
        Set(ConfigurationValidator.validate(configuration).filter { $0.severity == .error }.map(\.path))
    }

    private func parse(_ body: String) throws -> Configuration {
        try ConfigurationLoader.parse("version: 1\n" + body, environment: [:])
    }

    @Test("NaN and infinity are rejected for every Double setting")
    func nonfiniteDoubles() {
        for value in [Double.nan, .infinity, -.infinity] {
            var configuration = Configuration()
            configuration.timeouts.baselineSeconds = value
            configuration.timeouts.terminationGracePeriodSeconds = value
            configuration.timeouts.mutant.multiplier = value
            configuration.timeouts.mutant.minimumSeconds = value
            configuration.timeouts.mutant.maximumSeconds = value
            configuration.timeouts.mutant.overheadAllowanceSeconds = value
            configuration.execution.budget.maxDurationSeconds = value
            configuration.execution.noOpCanarySampleRate = value
            configuration.qualityGate = QualityGateSettings(
                testedScore: .init(minimum: value), effectiveScore: .init(minimum: value),
                regression: .init(maximumDrop: value)
            )
            let paths = errorPaths(configuration)
            for expected in [
                "timeouts.baseline", "timeouts.terminationGracePeriod", "timeouts.mutant",
                "timeouts.mutant.multiplier", "timeouts.mutant.overheadAllowance",
                "execution.budget.maxDurationSeconds", "execution.noOpCanarySampleRate",
                "qualityGate.testedScore.minimum", "qualityGate.effectiveScore.minimum",
                "qualityGate.regression.maximumDrop"
            ] {
                #expect(paths.contains(expected), "\(value) at \(expected)")
            }
        }
    }

    @Test("Overflowing durations, negative grace and zero coverage workers are rejected")
    func rangeViolations() {
        var configuration = Configuration()
        configuration.timeouts.mutant.maximumSeconds = 1e300
        configuration.timeouts.baselineSeconds = ConfigurationLimits.maximumDurationSeconds + 1
        configuration.timeouts.terminationGracePeriodSeconds = -1
        configuration.timeouts.mutant.overheadAllowanceSeconds = -0.5
        configuration.execution.coverageWorkers = 0
        configuration.execution.budget.maxDurationSeconds = 1e300
        let paths = errorPaths(configuration)
        for expected in [
            "timeouts.mutant", "timeouts.baseline", "timeouts.terminationGracePeriod",
            "timeouts.mutant.overheadAllowance", "execution.coverageWorkers",
            "execution.budget.maxDurationSeconds"
        ] {
            #expect(paths.contains(expected), "\(expected)")
        }
        configuration = Configuration()
        configuration.qualityGate = QualityGateSettings(
            testedScore: .init(minimum: 101), regression: .init(maximumDrop: -1), survived: .init(newMaximum: -1)
        )
        #expect(errorPaths(configuration) == [
            "qualityGate.testedScore.minimum", "qualityGate.regression.maximumDrop",
            "qualityGate.survived.newMaximum"
        ])
    }

    @Test("Zero grace period and zero overhead allowance are valid; they mean 'none'")
    func zeroIsAllowedWhereMeaningful() {
        var configuration = Configuration()
        configuration.timeouts.terminationGracePeriodSeconds = 0
        configuration.timeouts.mutant.overheadAllowanceSeconds = 0
        #expect(errorPaths(configuration).isEmpty)
    }

    @Test("Gate thresholds resolved for `gate` reject nonfinite and out-of-range values too")
    func gateResolutionIsStrict() {
        #expect(throws: QualityGateSettingsError.self) {
            try QualityGateSettings(testedScore: .init(minimum: .nan)).resolvedThresholds()
        }
        #expect(throws: QualityGateSettingsError.self) {
            try QualityGateSettings(regression: .init(maximumDrop: .infinity)).resolvedThresholds()
        }
        #expect(throws: QualityGateSettingsError.self) {
            try QualityGateSettings(survived: .init(newMaximum: -1)).resolvedThresholds()
        }
    }

    @Test("Explicit null on a duration key is rejected; an absent key still defaults")
    func nullDuration() throws {
        #expect(try parse("").timeouts.baselineSeconds == 600)
        for body in [
            "timeouts:\n  baseline: null\n",
            "timeouts:\n  terminationGracePeriod: ~\n",
            "timeouts:\n  mutant:\n    minimum: null\n",
            "timeouts:\n  mutant:\n    maximum: null\n",
            "timeouts:\n  mutant:\n    overheadAllowance: null\n"
        ] {
            #expect(throws: ConfigurationError.self, "\(body)") { try parse(body) }
        }
    }

    @Test("A nonfinite multiplier written in YAML never reaches a usable configuration")
    func yamlNonfiniteMultiplier() throws {
        let configuration = try parse("timeouts:\n  mutant:\n    multiplier: .nan\n")
        #expect(errorPaths(configuration).contains("timeouts.mutant.multiplier"))
    }

    @Test("Identity of an unencodable configuration is an explicit failure, never a shared digest")
    func identityFailsExplicitly() throws {
        // Each identity drops different sections, so each needs a value in a section it keeps.
        var timeouts = Configuration()
        timeouts.timeouts.mutant.multiplier = .nan
        var execution = Configuration()
        execution.execution.noOpCanarySampleRate = .nan
        var budget = Configuration()
        budget.execution.budget.maxDurationSeconds = .infinity
        #expect(throws: ConfigurationIdentity.EncodingFailure.self) { try timeouts.configurationHash }
        #expect(throws: ConfigurationIdentity.EncodingFailure.self) { try execution.configurationHash }
        #expect(throws: ConfigurationIdentity.EncodingFailure.self) { try execution.buildIdentityHash }
        #expect(throws: ConfigurationIdentity.EncodingFailure.self) { try budget.planningHash }
        // A valid configuration still hashes.
        #expect(try !Configuration().configurationHash.isEmpty)
    }

    @Test("A schema the key validator cannot parse fails closed instead of allowing every key")
    func keyValidatorFailsClosed() throws {
        let composed = try Yams.compose(yaml: "bogus: 1\n")
        let root = try #require(composed)
        for broken in ["", "not json", "[1, 2]", "{}", "{\"properties\": 3}"] {
            #expect(throws: ConfigurationKeyError.self, "\(broken)") {
                try ConfigurationKeyValidator.validate(root, schemaDocument: broken)
            }
        }
        #expect(throws: ConfigurationKeyError.self) { try ConfigurationKeyValidator.validate(root) }
    }
}
