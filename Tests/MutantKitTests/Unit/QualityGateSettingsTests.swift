import Foundation
import MutationModel
import Testing

/// `QualityGateSettings` is the `qualityGate:` section of `mutantkit.yml` —
/// see its own doc comment for why it is excluded from
/// `Configuration.configurationHash` (CI merge policy must not invalidate a
/// plan or checkpoint) and why `integrityViolations.maximum` accepts only
/// `0` (the gate's fail-closed behavior on an integrity violation is not
/// configurable).
@Suite("Quality gate settings")
struct QualityGateSettingsTests {
    @Test("decodes from JSON matching the documented mutantkit.yml shape")
    func decodesFromConfigShape() throws {
        let json = """
        {
          "testedScore": { "minimum": 80 },
          "effectiveScore": { "minimum": 70 },
          "regression": { "maximumDrop": 2 },
          "survived": { "newMaximum": 0 },
          "integrityViolations": { "maximum": 0 }
        }
        """
        let settings = try JSONDecoder().decode(QualityGateSettings.self, from: Data(json.utf8))
        #expect(settings.testedScore?.minimum == 80)
        #expect(settings.effectiveScore?.minimum == 70)
        #expect(settings.regression?.maximumDrop == 2)
        #expect(settings.survived?.newMaximum == 0)
        #expect(settings.integrityViolations?.maximum == 0)
    }

    @Test("resolvedThresholds converts percent to fraction")
    func resolvedThresholdsConvertsUnits() throws {
        let settings = QualityGateSettings(
            testedScore: .init(minimum: 80),
            effectiveScore: .init(minimum: 70),
            regression: .init(maximumDrop: 2),
            survived: .init(newMaximum: 0)
        )
        let thresholds = try settings.resolvedThresholds()
        #expect(thresholds.minimumTested == 0.8)
        #expect(thresholds.minimumEffective == 0.7)
        #expect(thresholds.regressionMaximumDrop == 0.02)
        #expect(thresholds.newSurvivorsMaximum == 0)
    }

    @Test("integrityViolations.maximum of 0 is accepted")
    func zeroIntegrityToleranceIsAccepted() throws {
        let settings = QualityGateSettings(integrityViolations: .init(maximum: 0))
        _ = try settings.resolvedThresholds()
    }

    @Test("a nonzero integrityViolations.maximum is rejected: fail-closed cannot be configured away")
    func nonzeroIntegrityToleranceIsRejected() {
        let settings = QualityGateSettings(integrityViolations: .init(maximum: 1))
        #expect(throws: QualityGateSettingsError.self) { try settings.resolvedThresholds() }
    }

    @Test("qualityGate does not affect configurationHash")
    func configurationHashExcludesQualityGate() {
        var strict = Configuration()
        strict.qualityGate = QualityGateSettings(
            testedScore: .init(minimum: 95), regression: .init(maximumDrop: 0), survived: .init(newMaximum: 0)
        )
        var lenient = Configuration()
        lenient.qualityGate = QualityGateSettings()

        #expect(strict.configurationHash == lenient.configurationHash)
    }

    @Test("a non-qualityGate change still changes configurationHash")
    func configurationHashStillReflectsRealChanges() {
        var a = Configuration()
        var b = Configuration()
        b.execution.workers = (a.execution.workers ?? 0) + 7

        #expect(a.configurationHash != b.configurationHash)
    }
}
