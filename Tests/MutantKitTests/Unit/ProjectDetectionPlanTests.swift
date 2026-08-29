@testable import CLI
import MutationModel
import Testing

/// `ProjectDetectionPlan.build` is the pure half of what `init` (and now
/// `setup`) does with real detection results: it decides what to narrate,
/// whether a scheme or test-target list is still ambiguous, and what
/// `mutantkit.yml` template to produce — all without touching the
/// filesystem, `xcodebuild`, or `simctl`. These tests exercise it directly
/// against synthetic detection results so every branch is reachable without
/// a real fixture project.
@Suite("ProjectDetectionPlan.build")
struct ProjectDetectionPlanTests {
    private func build(
        kind: ProjectKind? = .swiftPackageMacOS,
        reason: String? = "Package.swift declares no Apple platform.",
        swiftPMTestTargets: [String] = [],
        scheme: String? = nil,
        schemeCandidates: [String] = [],
        xcodeTestTargets: [String] = [],
        destination: String? = nil,
        destinationDiscoveryFailed: Bool = false
    ) -> ProjectDetectionPlan.Result {
        ProjectDetectionPlan.build(ProjectDetectionPlan.Input(
            kind: kind,
            reason: reason,
            swiftPMTestTargets: swiftPMTestTargets,
            scheme: scheme,
            schemeCandidates: schemeCandidates,
            xcodeTestTargets: xcodeTestTargets,
            destination: destination,
            destinationDiscoveryFailed: destinationDiscoveryFailed
        ))
    }

    // MARK: - Project kind narration

    @Test("A successful detection narrates the kind and reason")
    func successfulDetectionNarratesKindAndReason() {
        let result = build(kind: .xcodeProject, reason: "Found MyApp.xcodeproj.")
        #expect(result.summaryLines.first == "Detected: xcodeProject — Found MyApp.xcodeproj.")
    }

    @Test("A failed detection (nil kind) falls back to the auto template without claiming a reason")
    func failedDetectionFallsBackToAuto() {
        let result = build(kind: nil, reason: nil)
        #expect(result.summaryLines.contains("Could not detect the project kind. Writing a template with `kind: auto`."))
        #expect(result.template.contains("kind: auto"))
    }

    // MARK: - Test targets

    @Test("SwiftPM test targets are reported and win over Xcode test targets when both are present")
    func swiftPMTestTargetsWinOverXcodeTestTargets() {
        let result = build(swiftPMTestTargets: ["PricingTests"], xcodeTestTargets: ["OtherTests"])
        #expect(result.hasTestTargets)
        #expect(result.template.contains("PricingTests"))
        #expect(!result.template.contains("OtherTests"))
    }

    @Test("No test targets from either source leaves hasTestTargets false")
    func noTestTargetsFromEitherSource() {
        let result = build()
        #expect(!result.hasTestTargets)
        #expect(result.template.contains("No test target detected"))
    }

    @Test("Xcode test targets alone are reported and used when SwiftPM found none")
    func xcodeTestTargetsUsedWhenSwiftPMFoundNone() {
        let result = build(xcodeTestTargets: ["HangContainmentTests"])
        #expect(result.hasTestTargets)
        #expect(result.template.contains("HangContainmentTests"))
    }

    // MARK: - Scheme ambiguity

    @Test("A single resolved scheme is not ambiguous")
    func singleResolvedSchemeIsNotAmbiguous() {
        let result = build(kind: .xcodeProject, scheme: "MyApp", schemeCandidates: [])
        #expect(!result.schemeAmbiguous)
        #expect(result.summaryLines.contains("Detected scheme: MyApp"))
    }

    @Test("More than one scheme candidate with none chosen is reported as ambiguous, never guessed")
    func multipleSchemeCandidatesAreAmbiguous() {
        let result = build(kind: .xcodeProject, scheme: nil, schemeCandidates: ["A", "B", "C"])
        #expect(result.schemeAmbiguous)
        #expect(result.summaryLines.contains("Multiple schemes found (A, B, C) — set `project.scheme` yourself."))
        // Never silently picks one for the template either.
        #expect(!result.template.contains("scheme: A"))
    }

    @Test("Zero scheme candidates (not an Xcode project) is not treated as ambiguous")
    func zeroSchemeCandidatesIsNotAmbiguous() {
        let result = build(kind: .swiftPackageMacOS, scheme: nil, schemeCandidates: [])
        #expect(!result.schemeAmbiguous)
    }

    // MARK: - Destination

    @Test("A genuinely detected destination is narrated and written to the template")
    func detectedDestinationIsNarratedAndWritten() {
        let result = build(kind: .xcodeProject, destination: "platform=iOS Simulator,name=iPhone 16 Pro")
        #expect(result.summaryLines.contains("Detected destination: platform=iOS Simulator,name=iPhone 16 Pro"))
        #expect(result.template.contains("platform=iOS Simulator,name=iPhone 16 Pro"))
    }

    @Test("A placeholder fallback destination is written but never narrated as 'detected'")
    func placeholderDestinationIsWrittenButNotNarratedAsDetected() {
        let result = build(kind: .xcodeProject, destination: nil)
        #expect(!result.summaryLines.contains { $0.hasPrefix("Detected destination:") })
        #expect(result.template.contains("platform=iOS Simulator,name=iPhone 16"))
    }

    @Test("A macOS SwiftPM package gets no destination at all")
    func macOSPackageGetsNoDestination() {
        let result = build(kind: .swiftPackageMacOS, destination: nil)
        #expect(!result.template.contains("destination:"))
    }

    @Test("Destination discovery failure is warned about and propagated on the result")
    func destinationDiscoveryFailureIsWarned() {
        let result = build(kind: .xcodeProject, destination: nil, destinationDiscoveryFailed: true)
        #expect(result.destinationDiscoveryFailed)
        #expect(result.summaryLines.contains { $0.contains("could not query the simulator subsystem") })
    }
}
