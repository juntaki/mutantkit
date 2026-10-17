@testable import AppleBuildAdapters
import Foundation
import Testing

/// Xcode 16 folder references (`PBXFileSystemSynchronizedRootGroup`) list no files in the project:
/// membership is the directory's contents minus per-target exception sets. A resolver blind to them
/// leaves every such source without a target and silently drops the project out of schemata.
@Suite("Xcode synchronized-group target membership")
struct XcodeSynchronizedGroupMembershipTests {
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
        let shared = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("ShareExtension"), withIntermediateDirectories: true)
        for file in ["Model.swift", "ShareExtension/Item.swift", "Notes.txt"] {
            try Data("// x\n".utf8).write(to: shared.appendingPathComponent(file))
        }
        let xcodeproj = root.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        let pbxproj = """
        // !$*UTF8*$!
        {
            archiveVersion = 1; classes = {}; objectVersion = 77;
            objects = {
                PROJ /* Project */ = { isa = PBXProject; mainGroup = MAIN; targets = (APP, EXT); };
                MAIN = { isa = PBXGroup; children = (SHARED); sourceTree = "<group>"; };
                SHARED = {
                    isa = PBXFileSystemSynchronizedRootGroup; path = Shared; sourceTree = "<group>";
                    exceptions = (EXC, EXC2);
                };
                EXC = {
                    isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
                    membershipExceptions = ("ShareExtension/Item.swift");
                    target = APP;
                };
                EXC2 = {
                    isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
                    membershipExceptions = ("ShareExtension/Item.swift", "Missing.swift");
                    target = EXT;
                };
                APP = {
                    isa = PBXNativeTarget; name = App; buildPhases = (); dependencies = ();
                    fileSystemSynchronizedGroups = (SHARED);
                };
                EXT = {
                    isa = PBXNativeTarget; name = Ext; buildPhases = (); dependencies = ();
                };
            };
            rootObject = PROJ;
        }
        """
        try Data(pbxproj.utf8).write(to: xcodeproj.appendingPathComponent("project.pbxproj"))
        return xcodeproj
    }

    @Test("a member target owns the folder minus its exception set; a non-member owns exactly the files its exception set names")
    func membershipFollowsExceptionSets() throws {
        let xcodeproj = try makeProject()
        let data = try Data(contentsOf: xcodeproj.appendingPathComponent("project.pbxproj"))
        let memberships = try XcodeTargetResolver.parseTargetMemberships(
            pbxprojData: data, pbxprojPath: xcodeproj.appendingPathComponent("project.pbxproj").path
        )
        let byName = Dictionary(uniqueKeysWithValues: memberships.map { ($0.name, Set($0.sources)) })
        #expect(byName["App"] == ["Shared/Model.swift"], "\(String(describing: byName["App"]))")
        #expect(byName["Ext"] == ["Shared/ShareExtension/Item.swift"], "\(String(describing: byName["Ext"]))")
    }
}

/// A test bundle that links a framework target's product, without a declared target dependency,
/// still builds that framework when its scheme builds implicit dependencies (Nuke's NukeTests).
@Suite("Xcode implicit dependencies by linked product")
struct XcodeImplicitDependencyTests {
    @Test("a product linked in the Frameworks phase makes its target a dependency")
    func linkedProductIsADependency() throws {
        let pbxproj = """
        // !$*UTF8*$!
        {
            archiveVersion = 1; classes = {}; objectVersion = 77;
            objects = {
                PROJ = { isa = PBXProject; mainGroup = MAIN; targets = (FW, TESTS); };
                MAIN = { isa = PBXGroup; children = (); sourceTree = "<group>"; };
                FWPRODUCT = { isa = PBXFileReference; path = Lib.framework; sourceTree = BUILT_PRODUCTS_DIR; };
                LINK = { isa = PBXBuildFile; fileRef = FWPRODUCT; };
                LINKPHASE = { isa = PBXFrameworksBuildPhase; files = (LINK); };
                FW = { isa = PBXNativeTarget; name = Lib; buildPhases = (); dependencies = (); productReference = FWPRODUCT; };
                TESTS = { isa = PBXNativeTarget; name = LibTests; buildPhases = (LINKPHASE); dependencies = (); };
            };
            rootObject = PROJ;
        }
        """
        let memberships = try XcodeTargetResolver.parseTargetMemberships(
            pbxprojData: Data(pbxproj.utf8), pbxprojPath: "App.xcodeproj/project.pbxproj"
        )
        let byName = Dictionary(uniqueKeysWithValues: memberships.map { ($0.name, $0.dependencies) })
        #expect(byName["LibTests"] == ["Lib"], "\(byName)")
        #expect(byName["Lib"] == [])
    }
}
