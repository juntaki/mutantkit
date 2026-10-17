@testable import AppleBuildAdapters
import Foundation
import Testing

/// A source shared by several app targets is embedded once per target; only the targets the run's
/// scheme builds can ever be exercised, so the rest must not be offered to the chunk planner.
@Suite("Xcode scheme built targets")
struct XcodeSchemeBuiltTargetsTests {
    private func project(scheme name: String, blueprints: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scheme-\(UUID().uuidString).xcodeproj")
        let schemes = root.appendingPathComponent("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        let references = blueprints.map { "<BuildableReference BlueprintName = \"\($0)\"></BuildableReference>" }.joined()
        let xml = "<Scheme><BuildAction><BuildActionEntries><BuildActionEntry>\(references)</BuildActionEntry></BuildActionEntries></BuildAction></Scheme>"
        try Data(xml.utf8).write(to: schemes.appendingPathComponent("\(name).xcscheme"))
        return root
    }

    private let memberships: [XcodeTargetResolver.TargetMembership] = [
        .init(name: "App", sources: [], dependencies: ["Framework"]),
        .init(name: "Framework", sources: []),
        .init(name: "Experimental", sources: [], dependencies: ["Framework"]),
        .init(name: "AppTests", sources: [], dependencies: ["App"])
    ]

    @Test("the scheme's named targets and their dependency closure are built; siblings are not")
    func closureOfNamedTargets() throws {
        let url = try project(scheme: "App", blueprints: ["App", "AppTests"])
        let built = try XcodeTargetResolver.schemeBuiltTargets(scheme: "App", schemeContainers: [url], memberships: memberships)
        #expect(built == ["App", "AppTests", "Framework"])
    }

    @Test("a scheme that is unset, missing, or declared elsewhere is refused, not treated as every target")
    func unprovableSchemeThrows() throws {
        let url = try project(scheme: "Other", blueprints: ["NotHere"])
        for scheme in [nil, "", "Missing"] as [String?] {
            #expect(throws: XcodeTargetResolver.ResolutionError.self) {
                _ = try XcodeTargetResolver.schemeBuiltTargets(scheme: scheme, schemeContainers: [url], memberships: memberships)
            }
        }
        // Present but naming nothing of this project (a workspace scheme for another member): nothing built here.
        #expect(try XcodeTargetResolver.schemeBuiltTargets(scheme: "Other", schemeContainers: [url], memberships: memberships).isEmpty)
    }
}
