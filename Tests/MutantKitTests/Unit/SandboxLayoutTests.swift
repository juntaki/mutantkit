import Foundation
@testable import MutationExecution
import Testing

/// Pure path-shape tests for `SandboxLayout`.
///
/// The paths deliberately do not exist. The layout must not inspect the filesystem:
/// discovery has already canonicalized the roots, and materialization owns copying and
/// containment checks.
@Suite("Sandbox layout")
struct SandboxLayoutTests {
    // MARK: - Placement

    @Test("A sibling package keeps its position beside the project")
    func siblingKeepsRelativePosition() {
        let layout = SandboxLayout.make(
            canonicalProjectRoot: "/work/Core",
            localPackages: [package("/work/SwiftMapper", declaredBy: "/work/Core")]
        )

        #expect(layout.projectRoot.path == "/work/Core")
        #expect(layout.layoutRoot.path == "/work")
        #expect(layout.workspaceRelativePath == "Core")
        #expect(layout.externalRoots == [
            SandboxLayout.ExternalRoot(
                sourceRoot: URL(fileURLWithPath: "/work/SwiftMapper", isDirectory: true),
                relativePath: "SwiftMapper"
            )
        ])
    }

    @Test("A transitive chain is sorted by relative path and shares one layout root")
    func transitiveChainIsSorted() {
        let layout = SandboxLayout.make(
            canonicalProjectRoot: "/work/Apps/Core",
            localPackages: [
                package("/work/Libraries/SwiftMapper", declaredBy: "/work/Apps/Core"),
                package("/work/Libraries/Logging", declaredBy: "/work/Libraries/SwiftMapper")
            ]
        )

        #expect(layout.layoutRoot.path == "/work")
        #expect(layout.workspaceRelativePath == "Apps/Core")
        #expect(layout.externalRoots.map(\.relativePath) == [
            "Libraries/Logging",
            "Libraries/SwiftMapper"
        ])
    }

    @Test("Without external packages the workspace is the container")
    func projectOnlyWorkspaceIsContainer() {
        let layout = SandboxLayout.make(canonicalProjectRoot: "/work/Core", localPackages: [])
        let container = URL(fileURLWithPath: "/scratch/sbx_0123456789abcdef0123", isDirectory: true)
        let sandbox = layout.sandbox(containerRoot: container)

        #expect(layout == SandboxLayout.projectOnly(canonicalProjectRoot: "/work/Core"))
        #expect(layout.layoutRoot == layout.projectRoot)
        #expect(layout.workspaceRelativePath.isEmpty)
        #expect(sandbox.workspaceRoot == sandbox.containerRoot)
    }

    @Test("A nested workspace sits at the project's relative path inside the container")
    func sandboxWorkspaceIsNested() {
        let layout = SandboxLayout.make(
            canonicalProjectRoot: "/work/Apps/Core",
            localPackages: [package("/work/SwiftMapper", declaredBy: "/work/Apps/Core")]
        )
        let container = URL(fileURLWithPath: "/scratch/sbx_0123456789abcdef0123", isDirectory: true)
        let sandbox = layout.sandbox(containerRoot: container)

        #expect(sandbox.containerRoot == container)
        #expect(sandbox.workspaceRoot.path == "/scratch/sbx_0123456789abcdef0123/Apps/Core")
    }

    @Test("Roots with no common directory below slash use slash as the layout root")
    func layoutRootCanBeFilesystemRoot() {
        let layout = SandboxLayout.make(
            canonicalProjectRoot: "/Users/someone/work/Core",
            localPackages: [
                package("/opt/packages/SwiftMapper", declaredBy: "/Users/someone/work/Core")
            ]
        )

        #expect(layout.layoutRoot.path == "/")
        #expect(layout.workspaceRelativePath == "Users/someone/work/Core")
        #expect(layout.externalRoots.map(\.relativePath) == ["opt/packages/SwiftMapper"])
    }

    // MARK: - Roots the project or another external copy already carries

    @Test("A package inside the project is dropped because the project copy carries it")
    func internalPackageIsDropped() {
        let layout = SandboxLayout.make(
            canonicalProjectRoot: "/work/Core",
            localPackages: [
                package("/work/Core/Vendor/Inner", declaredBy: "/work/Core"),
                package("/work/SwiftMapper", declaredBy: "/work/Core")
            ]
        )

        #expect(layout.externalRoots.map(\.relativePath) == ["SwiftMapper"])
    }

    @Test("Only internal packages leave a project-only layout")
    func onlyInternalPackagesIsProjectOnly() {
        let layout = SandboxLayout.make(
            canonicalProjectRoot: "/work/Core",
            localPackages: [
                package("/work/Core/Vendor/Inner", declaredBy: "/work/Core")
            ]
        )

        #expect(layout == SandboxLayout.projectOnly(canonicalProjectRoot: "/work/Core"))
    }

    @Test("A package inside another external package is carried by the outer copy")
    func overlappingRootsCollapse() {
        let layout = SandboxLayout.make(
            canonicalProjectRoot: "/work/Core",
            localPackages: [
                package("/work/Kit/Plugins/Extra", declaredBy: "/work/Core"),
                package("/work/Kit", declaredBy: "/work/Core")
            ]
        )

        #expect(layout.externalRoots.map(\.relativePath) == ["Kit"])
    }

    @Test("The same canonical package reached through two reported spellings is listed once")
    func canonicalIdentityDeduplicatesAliases() {
        let layout = SandboxLayout.make(
            canonicalProjectRoot: "/work/Core",
            localPackages: [
                LocalPackageRoot(
                    reportedPath: "/alias/SwiftMapper",
                    canonicalPath: "/work/SwiftMapper",
                    declaredBy: "/work/Core"
                ),
                LocalPackageRoot(
                    reportedPath: "/work/SwiftMapper/",
                    canonicalPath: "/work/SwiftMapper",
                    declaredBy: "/work/Other"
                )
            ]
        )

        #expect(layout.externalRoots.map(\.sourceRoot.path) == ["/work/SwiftMapper"])
    }

    @Test("A sibling whose name extends the project's name is not mistaken for a child")
    func namePrefixIsNotContainment() {
        let layout = SandboxLayout.make(
            canonicalProjectRoot: "/work/Core",
            localPackages: [package("/work/CoreKit", declaredBy: "/work/Core")]
        )

        #expect(layout.workspaceRelativePath == "Core")
        #expect(layout.externalRoots.map(\.relativePath) == ["CoreKit"])
    }

    // MARK: - Finding the container from a workspace

    private static let container = "/work/Core/.mutantkit/sandboxes/sbx_0123456789abcdef0123"

    @Test("A nested workspace maps back to its container and scratch root")
    func nestedWorkspaceMapsBackToContainer() throws {
        let layout = SandboxLayout(
            projectRoot: URL(fileURLWithPath: "/work/Apps/Core", isDirectory: true),
            layoutRoot: URL(fileURLWithPath: "/work", isDirectory: true),
            workspaceRelativePath: "Apps/Core",
            externalRoots: []
        )
        let workspace = URL(fileURLWithPath: Self.container + "/Apps/Core", isDirectory: true)

        #expect(try layout.scratchRoot(ofWorkspace: workspace).path == "/work/Core/.mutantkit/sandboxes")
        #expect(try layout.containerName(ofWorkspace: workspace) == "sbx_0123456789abcdef0123")
    }

    @Test("A flat project-only workspace maps back to its container and scratch root")
    func flatWorkspaceMapsBackToContainer() throws {
        let layout = SandboxLayout.projectOnly(canonicalProjectRoot: "/work/Core")
        let workspace = URL(fileURLWithPath: Self.container, isDirectory: true)

        #expect(try layout.scratchRoot(ofWorkspace: workspace).path == "/work/Core/.mutantkit/sandboxes")
        #expect(try layout.containerName(ofWorkspace: workspace) == "sbx_0123456789abcdef0123")
    }

    @Test("A path that is not a workspace of the layout is refused")
    func foreignWorkspaceIsRefused() {
        let nested = SandboxLayout(
            projectRoot: URL(fileURLWithPath: "/work/Apps/Core", isDirectory: true),
            layoutRoot: URL(fileURLWithPath: "/work", isDirectory: true),
            workspaceRelativePath: "Apps/Core",
            externalRoots: []
        )
        let flat = SandboxLayout.projectOnly(canonicalProjectRoot: "/work/Core")
        let refusals: [(SandboxLayout, String)] = [
            (nested, Self.container),
            (nested, Self.container + "/Apps/Other"),
            (nested, "/work/Apps/Core"),
            (flat, Self.container + "/Apps/Core"),
            (flat, "/work/Core/.mutantkit/sandboxes/prd_0123456789abcdef0123"),
            (flat, "/work/Core/.mutantkit/sandboxes/sbx_probe"),
            (flat, "/")
        ]

        for (layout, path) in refusals {
            #expect(throws: SandboxLayoutError.self, "\(path)") {
                _ = try layout.scratchRoot(ofWorkspace: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - Containment predicate

    // MARK: - Contract with discovery

    @Test("A package containing the project breaks discovery's contract and stops the layout instead of producing an empty root")
    func packageContainingProjectStopsTheLayout() async {
        await #expect(processExitsWith: .failure) {
            _ = SandboxLayout.make(
                canonicalProjectRoot: "/work/Core",
                localPackages: [LocalPackageRoot(
                    reportedPath: "/work", canonicalPath: "/work", declaredBy: "/work/Core"
                )]
            )
        }
    }

    @Test("Containment is component-aware")
    func containmentIsComponentAware() {
        #expect(SandboxLayout.isSameOrInside("/work/Core", "/work/Core"))
        #expect(SandboxLayout.isSameOrInside("/work/Core/Vendor", "/work/Core"))
        #expect(!SandboxLayout.isSameOrInside("/work/CoreKit", "/work/Core"))
        #expect(SandboxLayout.isSameOrInside("/work/Core", "/"))
    }

    private func package(_ canonicalPath: String, declaredBy: String) -> LocalPackageRoot {
        LocalPackageRoot(
            reportedPath: canonicalPath,
            canonicalPath: canonicalPath,
            declaredBy: declaredBy
        )
    }
}
