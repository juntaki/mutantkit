@testable import AppleBuildAdapters
import Foundation
import Testing

/// `xcodeWorkspace` schemata target resolution (the multi-image build receipt): the member `.xcodeproj` files are read
/// from `contents.xcworkspacedata`, and source paths are re-rooted at the workspace directory.
@Suite("Xcode workspace target resolution")
struct XcodeWorkspaceTargetResolverTests {
    private let container = URL(fileURLWithPath: "/work/Rx")

    private func members(_ xml: String) throws -> [String] {
        try XcodeTargetResolver.parseWorkspaceMemberProjects(
            workspaceData: Data(xml.utf8), workspaceContainer: container, workspacePath: "contents.xcworkspacedata"
        ).map(\.path)
    }

    @Test("group: references resolve against the workspace directory, including nested groups")
    func groupReferencesAndNesting() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "group:Package.swift"></FileRef>
           <FileRef location = "group:Rx.xcodeproj"></FileRef>
           <Group location = "group:Examples" name = "Examples">
              <FileRef location = "group:Demo/Demo.xcodeproj"></FileRef>
           </Group>
           <FileRef location = "group:Preprocessor/Preprocessor.xcodeproj"></FileRef>
        </Workspace>
        """
        #expect(try members(xml) == [
            "/work/Rx/Rx.xcodeproj", "/work/Rx/Examples/Demo/Demo.xcodeproj", "/work/Rx/Preprocessor/Preprocessor.xcodeproj"
        ])
    }

    @Test("container:, absolute: and self: references; non-project files and duplicates are ignored")
    func otherReferenceKinds() throws {
        let xml = """
        <Workspace version = "1.0">
           <FileRef location = "self:"></FileRef>
           <FileRef location = "container:Libs/Libs.xcodeproj"></FileRef>
           <FileRef location = "absolute:/elsewhere/Other.xcodeproj"></FileRef>
           <FileRef location = "group:README.md"></FileRef>
           <FileRef location = "container:Libs/Libs.xcodeproj"></FileRef>
        </Workspace>
        """
        #expect(try members(xml) == ["/work/Rx/Libs/Libs.xcodeproj", "/elsewhere/Other.xcodeproj"])
    }

    @Test("a workspace file that is not XML is an error, not an empty result")
    func malformedWorkspaceIsAnError() {
        #expect(throws: XcodeTargetResolver.ResolutionError.self) { _ = try members("<Workspace><FileRef") }
    }

    @Test("source paths are re-rooted from the member project's directory to the workspace directory")
    func reroot() {
        let root = URL(fileURLWithPath: "/work/Rx")
        #expect(XcodeTargetResolver.rerooted("Sources/A.swift", projectDirectory: root, root: root) == "Sources/A.swift")
        #expect(
            XcodeTargetResolver.rerooted(
                "App/A.swift", projectDirectory: URL(fileURLWithPath: "/work/Rx/Examples/Demo"), root: root
            ) == "Examples/Demo/App/A.swift"
        )
    }
}
