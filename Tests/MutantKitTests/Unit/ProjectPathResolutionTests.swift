@testable import AppleBuildAdapters
import Foundation
import Testing

@Suite("Project path resolution")
struct ProjectPathResolutionTests {
    private let directory = URL(fileURLWithPath: "/work/project", isDirectory: true)

    @Test(
        "An unset, empty, dot or absolute project path leaves the directory itself",
        arguments: [nil, "", ".", "/elsewhere/package"] as [String?]
    )
    func unresolvedPathsStayAtTheDirectory(projectPath: String?) {
        let resolved = ProjectPathResolution.packageDirectory(in: directory, projectPath: projectPath)
        #expect(resolved.path == "/work/project")
    }

    @Test("A relative project path names a place below the directory")
    func relativePathIsResolvedBelowTheDirectory() {
        #expect(ProjectPathResolution.packageDirectory(in: directory, projectPath: "Package").path == "/work/project/Package")
        #expect(ProjectPathResolution.packageDirectory(in: directory, projectPath: "apps/ios").path == "/work/project/apps/ios")
    }
}
