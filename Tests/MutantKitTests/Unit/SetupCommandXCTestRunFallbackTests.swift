@testable import CLI
import MutationExecution
import Testing

/// Lane D external-proof discovery, root-caused 2026-09-10 against a real,
/// external Xcode project: `setup` wrote `tests.targets: []` even though
/// the same
/// invocation's own readiness check found real test target(s) moments
/// later via a real, post-build `.xctestrun` — because
/// `XcodeConfigDetector.testTargets(forScheme:)` only ever reads a static
/// `.xcscheme` file, which does not exist for a project that has never
/// explicitly shared or saved a scheme (Xcode's own common, unremarkable
/// state). `SetupCommand.finalTemplate` is the fallback: when the static
/// parse found nothing, but readiness's own `.testTargets` diagnosis item
/// did, the written/previewed template uses that instead.
@Suite("SetupCommand.finalTemplate: .xctestrun fallback for tests.targets")
struct SetupCommandXCTestRunFallbackTests {
    private static func plan(hasTestTargets: Bool, template: String = "placeholder") -> ProjectDetectionPlan.Result {
        ProjectDetectionPlan.Result(
            template: template,
            summaryLines: [],
            hasTestTargets: hasTestTargets,
            schemeAmbiguous: false,
            destinationDiscoveryFailed: false,
            kind: .xcodeProject,
            scheme: "ExampleApp",
            resolvedDestination: "platform=iOS Simulator,name=iPhone 17"
        )
    }

    private static func diagnosis(testTargetsDetail: String?, status: DiagnosisItem.Status = .ok) -> BuildDiagnosis {
        var items: [DiagnosisItem] = []
        if let testTargetsDetail {
            items.append(DiagnosisItem(name: "Test targets", status: status, code: .testTargets, detail: testTargetsDetail))
        }
        return BuildDiagnosis(items: items)
    }

    @Test("Static detection already found test targets: readiness's own finding is never consulted, even if present")
    func staticDetectionTakesPrecedence() {
        let result = SetupCommand.finalTemplate(
            for: Self.plan(hasTestTargets: true, template: "has-targets"),
            given: Self.diagnosis(testTargetsDetail: "ExampleAppTests")
        )
        #expect(result.template == "has-targets")
        #expect(result.hasTestTargets == true)
    }

    @Test("Static detection found nothing, readiness's .xctestrun-based check found real targets: falls back to those")
    func fallsBackToXCTestRunTargets() {
        let result = SetupCommand.finalTemplate(
            for: Self.plan(hasTestTargets: false, template: "no-targets"),
            given: Self.diagnosis(testTargetsDetail: "ExampleAppTests, ExampleAppUITests")
        )
        #expect(result.template != "no-targets")
        #expect(result.template.contains("ExampleAppTests"))
        #expect(result.template.contains("ExampleAppUITests"))
        #expect(result.hasTestTargets == true)
    }

    @Test("Static detection found nothing, --skip-build means no .testTargets diagnosis item exists at all: stays empty")
    func noXCTestRunDiagnosisLeavesTemplateUnchanged() {
        let result = SetupCommand.finalTemplate(
            for: Self.plan(hasTestTargets: false, template: "no-targets"),
            given: Self.diagnosis(testTargetsDetail: nil)
        )
        #expect(result.template == "no-targets")
        #expect(result.hasTestTargets == false)
    }

    @Test("Static detection found nothing, .xctestrun-based check also failed (no targets, or unreadable): stays empty")
    func failedXCTestRunDiagnosisLeavesTemplateUnchanged() {
        let result = SetupCommand.finalTemplate(
            for: Self.plan(hasTestTargets: false, template: "no-targets"),
            given: Self.diagnosis(testTargetsDetail: "some.xctestrun lists no test targets.", status: .failure)
        )
        #expect(result.template == "no-targets")
        #expect(result.hasTestTargets == false)
    }
}
