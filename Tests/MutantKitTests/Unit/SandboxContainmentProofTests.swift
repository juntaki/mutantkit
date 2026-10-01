import Foundation
@testable import MutationExecution
import Testing

/// The containment proof on scripted resolver answers. WorkspaceManager
/// wiring is tested separately with the sandbox materialization.
@Suite("Sandbox containment proof")
struct SandboxContainmentProofTests {
    @Test("Every package inside the container, matching the layout, is proven")
    func containedSandboxIsProven() async throws {
        let tree = try ProofTree()
        defer { tree.remove() }
        let sandbox = tree.sandbox(external: ["SwiftMapper", "Logging"])
        let proof = LocalPackageContainmentProof(
            resolver: ScriptedResolver(tree.packages(in: sandbox, [
                "SwiftMapper",
                "Logging",
                "Core/Vendor/Inner"
            ]))
        )

        try await proof.proveContainment(
            of: sandbox,
            layout: tree.layout(external: ["SwiftMapper", "Logging"])
        )
    }

    @Test("A package outside the container is refused and names the original declaring manifest")
    func packageOutsideContainerIsRefused() async throws {
        let tree = try ProofTree()
        defer { tree.remove() }
        let sandbox = tree.sandbox(external: ["SwiftMapper"])
        let original = tree.root + "/SwiftMapper"
        let resolver = ScriptedResolver([
            LocalPackageRoot(
                reportedPath: original,
                canonicalPath: original,
                declaredBy: sandbox.workspaceRoot.path
            )
        ])

        let error = await #expect(throws: SandboxContainmentError.self) {
            try await LocalPackageContainmentProof(resolver: resolver)
                .proveContainment(
                    of: sandbox,
                    layout: tree.layout(external: ["SwiftMapper"])
                )
        }

        #expect(error == .localPackageOutsideSandbox(
            reported: original,
            canonical: original,
            declaredBy: tree.root + "/Core"
        ))
        #expect(error?.description.contains("relative path") == true)
    }

    @Test("Containment is judged by path component, not string prefix")
    func siblingContainerWithSharedPrefixIsOutside() async throws {
        let tree = try ProofTree()
        defer { tree.remove() }
        let sandbox = tree.sandbox(external: [])
        let neighbour = sandbox.containerRoot.path + "b/Core/Vendor/Inner"
        let resolver = ScriptedResolver([
            LocalPackageRoot(
                reportedPath: neighbour,
                canonicalPath: neighbour,
                declaredBy: sandbox.workspaceRoot.path
            )
        ])

        await #expect(throws: SandboxContainmentError.self) {
            try await LocalPackageContainmentProof(resolver: resolver)
                .proveContainment(of: sandbox, layout: tree.layout(external: []))
        }
    }

    @Test("An unexpected package inside the container means the graph changed")
    func unexpectedPackageInsideContainerIsRefused() async throws {
        let tree = try ProofTree()
        defer { tree.remove() }
        let sandbox = tree.sandbox(external: ["SwiftMapper"])
        let resolver = ScriptedResolver(
            tree.packages(in: sandbox, ["SwiftMapper", "Logging"])
        )

        let error = await #expect(throws: SandboxContainmentError.self) {
            try await LocalPackageContainmentProof(resolver: resolver)
                .proveContainment(
                    of: sandbox,
                    layout: tree.layout(external: ["SwiftMapper"])
                )
        }

        #expect(error == .dependencyGraphChangedInSandbox(
            unexpected: ["Logging"],
            missing: []
        ))
    }

    @Test("A missing external root means the graph changed")
    func missingExternalRootIsRefused() async throws {
        let tree = try ProofTree()
        defer { tree.remove() }
        let sandbox = tree.sandbox(external: ["SwiftMapper", "Logging"])
        let resolver = ScriptedResolver(tree.packages(in: sandbox, ["SwiftMapper"]))

        let error = await #expect(throws: SandboxContainmentError.self) {
            try await LocalPackageContainmentProof(resolver: resolver)
                .proveContainment(
                    of: sandbox,
                    layout: tree.layout(external: ["SwiftMapper", "Logging"])
                )
        }

        #expect(error == .dependencyGraphChangedInSandbox(
            unexpected: [],
            missing: ["Logging"]
        ))
    }

    @Test("A package nested in an external root is carried by that root")
    func packageNestedInExternalRootIsAccepted() async throws {
        let tree = try ProofTree()
        defer { tree.remove() }
        let sandbox = tree.sandbox(external: ["Shared"])
        let resolver = ScriptedResolver(
            tree.packages(in: sandbox, ["Shared", "Shared/Plugins/Lint"])
        )

        try await LocalPackageContainmentProof(resolver: resolver)
            .proveContainment(
                of: sandbox,
                layout: tree.layout(external: ["Shared"])
            )
    }

    @Test("Without external roots, packages inside the project copy are accepted")
    func projectOnlyLayoutAcceptsInternalPackages() async throws {
        let tree = try ProofTree()
        defer { tree.remove() }
        let layout = SandboxLayout.projectOnly(
            canonicalProjectRoot: tree.root + "/Core"
        )
        let container = URL(
            fileURLWithPath: tree.root + "/Core/.mutantkit/sandboxes/sbx_a",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        let sandbox = layout.sandbox(containerRoot: container)
        let inner = container.path + "/Vendor/Inner"
        let resolver = ScriptedResolver([
            LocalPackageRoot(
                reportedPath: inner,
                canonicalPath: inner,
                declaredBy: container.path
            )
        ])

        try await LocalPackageContainmentProof(resolver: resolver)
            .proveContainment(of: sandbox, layout: layout)
    }

    @Test("A resolver failure is reported as an unresolvable sandbox")
    func resolutionFailureIsRefused() async throws {
        let tree = try ProofTree()
        defer { tree.remove() }
        let sandbox = tree.sandbox(external: [])
        let resolver = ScriptedResolver(
            failure: LocalPackageResolutionError.symlinkedLocalPackage(
                reportedPath: "/x/Link",
                canonicalPath: "/y/Real",
                declaredBy: "/x"
            )
        )

        let error = await #expect(throws: SandboxContainmentError.self) {
            try await LocalPackageContainmentProof(resolver: resolver)
                .proveContainment(of: sandbox, layout: tree.layout(external: []))
        }

        guard case let .unresolvableInSandbox(detail) = error else {
            Issue.record("expected unresolvableInSandbox, got \(String(describing: error))")
            return
        }
        #expect(detail.contains("/x/Link"))
    }

    @Test("Cancellation passes through unchanged")
    func cancellationPassesThrough() async throws {
        let tree = try ProofTree()
        defer { tree.remove() }
        let sandbox = tree.sandbox(external: [])

        await #expect(throws: CancellationError.self) {
            try await LocalPackageContainmentProof(
                resolver: ScriptedResolver(failure: CancellationError())
            ).proveContainment(
                of: sandbox,
                layout: tree.layout(external: [])
            )
        }
    }
}

private struct ScriptedResolver: LocalPackageDependencyResolving {
    let packages: [LocalPackageRoot]
    let failure: (any Error & Sendable)?

    init(_ packages: [LocalPackageRoot]) {
        self.packages = packages
        failure = nil
    }

    init(failure: any Error & Sendable) {
        packages = []
        self.failure = failure
    }

    func localPackageClosure(of _: URL) async throws -> [LocalPackageRoot] {
        if let failure {
            throw failure
        }
        return packages
    }
}

private struct ProofTree {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandboxContainmentProofTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        root = try #require(CanonicalPath.resolve(base.path))
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }

    func layout(external: [String]) -> SandboxLayout {
        guard !external.isEmpty else {
            return .projectOnly(canonicalProjectRoot: root + "/Core")
        }
        return SandboxLayout(
            projectRoot: URL(
                fileURLWithPath: root + "/Core",
                isDirectory: true
            ),
            layoutRoot: URL(fileURLWithPath: root, isDirectory: true),
            workspaceRelativePath: "Core",
            externalRoots: external.sorted().map {
                .init(
                    sourceRoot: URL(
                        fileURLWithPath: root + "/" + $0,
                        isDirectory: true
                    ),
                    relativePath: $0
                )
            }
        )
    }

    func sandbox(external: [String]) -> Sandbox {
        let container = URL(
            fileURLWithPath: root + "/Core/.mutantkit/sandboxes/sbx_a",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        return layout(external: external).sandbox(containerRoot: container)
    }

    func packages(
        in sandbox: Sandbox,
        _ relativePaths: [String]
    ) -> [LocalPackageRoot] {
        relativePaths.map {
            let path = sandbox.containerRoot.path + "/" + $0
            return LocalPackageRoot(
                reportedPath: path,
                canonicalPath: path,
                declaredBy: sandbox.workspaceRoot.path
            )
        }
    }
}
