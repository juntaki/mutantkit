@testable import AppleBuildAdapters
import Foundation
import Testing

/// Pins `XcodeTargetResolver`'s `project.pbxproj`-parsing half — the piece
/// that fills the gap this session closes: schemata classification
/// previously only knew how to resolve targets for SwiftPM
/// (`SwiftPMTargetResolver`, via `swift package describe`), so a pure
/// Xcode project (no `Package.swift`) silently degraded to 100% isolated
/// mode every time.
///
/// Two independent cases: `parseTargetMemberships` against a real,
/// committed fixture (`Fixtures/XcodeAppWithUITests/BatchUIDemo.xcodeproj`
/// — the same one `XcodeBatchTestingUITargetAcceptanceTests` builds and
/// tests for real) proves this parses an actual Xcode-generated
/// `project.pbxproj`, not just a hand-built approximation of one; a small
/// synthetic pbxproj below proves the `sourceTree` edge cases the real
/// fixture happens not to exercise — a file whose own `sourceTree`
/// overrides its containing group's path (`SOURCE_ROOT`), and one this
/// resolver cannot express as project-root-relative at all (`absolute`),
/// which must be skipped rather than guessed at. `parseBuildSettings` is
/// pinned separately against a captured `xcodebuild -showBuildSettings
/// -json` shape, with no process spawn.
@Suite("XcodeTargetResolver")
struct XcodeTargetResolverTests {
    private static var fixtureXcodeproj: URL {
        Acceptance.packageRoot.appendingPathComponent("Fixtures/XcodeAppWithUITests/BatchUIDemo.xcodeproj")
    }

    // MARK: - Real fixture

    @Test("resolves every native target's source membership from a real project.pbxproj")
    func realFixtureMembership() throws {
        let pbxprojURL = Self.fixtureXcodeproj.appendingPathComponent("project.pbxproj")
        let data = try Data(contentsOf: pbxprojURL)
        let memberships = try XcodeTargetResolver.parseTargetMemberships(pbxprojData: data, pbxprojPath: pbxprojURL.path)

        let byName = Dictionary(uniqueKeysWithValues: memberships.map { ($0.name, $0.sources) })
        #expect(byName.keys.sorted() == ["BatchUIDemo", "BatchUIDemoTests", "BatchUIDemoUITests"])
        #expect(byName["BatchUIDemo"] == ["Sources/AppDelegate.swift"])
        #expect(byName["BatchUIDemoTests"] == ["Tests/BatchUIDemoTests.swift"])
        #expect(byName["BatchUIDemoUITests"] == ["UITests/BatchUIDemoUITests.swift"])
    }

    @Test("a malformed project.pbxproj throws rather than silently resolving nothing")
    func malformedPbxprojThrows() {
        let garbage = Data("not a property list at all".utf8)
        #expect(throws: XcodeTargetResolver.ResolutionError.self) {
            try XcodeTargetResolver.parseTargetMemberships(pbxprojData: garbage, pbxprojPath: "/tmp/fake/project.pbxproj")
        }
    }

    // MARK: - sourceTree edge cases (synthetic — the real fixture has neither)

    /// `FILEA` sits inside `GRPA` (`path = Sources`, `sourceTree =
    /// "<group>"`) and resolves to `Sources/A.swift` — the ordinary,
    /// accumulate-through-the-group-chain case.
    ///
    /// `FILEROOT` also sits inside `GRPA`, but its own `sourceTree =
    /// SOURCE_ROOT` means its `path` is resolved from the project root
    /// directly, ignoring `GRPA`'s `Sources` path entirely — it must
    /// resolve to `Root.swift`, not `Sources/Root.swift`.
    ///
    /// `FILEABS` (`sourceTree = absolute`) is a tree this resolver cannot
    /// express as project-root-relative — it must be dropped from the
    /// target's sources entirely, never included with a wrong or guessed
    /// path.
    private static let syntheticPbxproj = """
    // !$*UTF8*$!
    {
    \tarchiveVersion = 1;
    \tclasses = {};
    \tobjectVersion = 50;
    \tobjects = {
    \t\tPROJ /* Project object */ = {
    \t\t\tisa = PBXProject;
    \t\t\tmainGroup = MAINGRP;
    \t\t\ttargets = (
    \t\t\t\tTARGET1,
    \t\t\t);
    \t\t};
    \t\tMAINGRP = {
    \t\t\tisa = PBXGroup;
    \t\t\tchildren = (
    \t\t\t\tGRPA,
    \t\t\t\tFILEABS,
    \t\t\t);
    \t\t\tsourceTree = "<group>";
    \t\t};
    \t\tGRPA = {
    \t\t\tisa = PBXGroup;
    \t\t\tpath = Sources;
    \t\t\tchildren = (
    \t\t\t\tFILEA,
    \t\t\t\tFILEROOT,
    \t\t\t);
    \t\t\tsourceTree = "<group>";
    \t\t};
    \t\tFILEA = {isa = PBXFileReference; path = A.swift; sourceTree = "<group>"; };
    \t\tFILEROOT = {isa = PBXFileReference; path = Root.swift; sourceTree = SOURCE_ROOT; };
    \t\tFILEABS = {isa = PBXFileReference; path = "/abs/Ignored.swift"; sourceTree = absolute; };
    \t\tBUILDFILE1 = {isa = PBXBuildFile; fileRef = FILEA; };
    \t\tBUILDFILE2 = {isa = PBXBuildFile; fileRef = FILEROOT; };
    \t\tBUILDFILE3 = {isa = PBXBuildFile; fileRef = FILEABS; };
    \t\tPHASE1 = {
    \t\t\tisa = PBXSourcesBuildPhase;
    \t\t\tfiles = (
    \t\t\t\tBUILDFILE1,
    \t\t\t\tBUILDFILE2,
    \t\t\t\tBUILDFILE3,
    \t\t\t);
    \t\t};
    \t\tTARGET1 = {
    \t\t\tisa = PBXNativeTarget;
    \t\t\tname = Demo;
    \t\t\tbuildPhases = (
    \t\t\t\tPHASE1,
    \t\t\t);
    \t\t};
    \t};
    \trootObject = PROJ;
    }
    """

    @Test("SOURCE_ROOT overrides group nesting; absolute is dropped rather than guessed at")
    func sourceTreeEdgeCases() throws {
        let data = Data(Self.syntheticPbxproj.utf8)
        let memberships = try XcodeTargetResolver.parseTargetMemberships(pbxprojData: data, pbxprojPath: "/tmp/fake/project.pbxproj")

        #expect(memberships.count == 1)
        let demo = try #require(memberships.first { $0.name == "Demo" })
        #expect(demo.sources == ["Sources/A.swift", "Root.swift"])
    }

    // MARK: - xcodebuild -showBuildSettings -json parsing (no process spawn)

    @Test("extracts PRODUCT_MODULE_NAME/PRODUCT_NAME from a captured -showBuildSettings -json shape")
    func parsesCapturedBuildSettings() throws {
        let json = """
        [
          {
            "target" : "ExampleApp",
            "buildSettings" : {
              "PRODUCT_MODULE_NAME" : "ExampleApp",
              "PRODUCT_NAME" : "ExampleApp",
              "FULL_PRODUCT_NAME" : "ExampleApp.app"
            }
          }
        ]
        """
        let settings = try XcodeTargetResolver.parseBuildSettings(Data(json.utf8), target: "ExampleApp")
        #expect(settings.moduleName == "ExampleApp")
        #expect(settings.productName == "ExampleApp")
    }

    @Test("PRODUCT_NAME falls back to the module name when absent")
    func productNameFallsBackToModuleName() throws {
        let json = """
        [{"target": "Widget", "buildSettings": {"PRODUCT_MODULE_NAME": "Widget"}}]
        """
        let settings = try XcodeTargetResolver.parseBuildSettings(Data(json.utf8), target: "Widget")
        #expect(settings.moduleName == "Widget")
        #expect(settings.productName == "Widget")
    }

    @Test("malformed -showBuildSettings JSON throws")
    func malformedBuildSettingsThrows() {
        let json = "{}"
        #expect(throws: XcodeTargetResolver.ResolutionError.self) {
            try XcodeTargetResolver.parseBuildSettings(Data(json.utf8), target: "Widget")
        }
    }
}
