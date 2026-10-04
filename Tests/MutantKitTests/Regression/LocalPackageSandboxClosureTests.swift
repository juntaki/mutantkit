import AppleBuildAdapters
import Foundation
import MutationExecution
import Testing

/// A sandbox must carry every local package the build will read.
///
/// A project that depends on `.package(path: "../SwiftMapper")` builds in
/// place and fails in a sandbox: the sandbox is a copy of the project root
/// alone, so `../SwiftMapper` resolves to a sibling of the sandbox that does
/// not exist, SwiftPM exits 1 with a tool error and no compiler diagnostic,
/// and the run ends in a baseline mismatch.
///
/// Each test here asks SwiftPM itself, from inside the sandbox, which local
/// packages its manifests reference (`LocalPackageFixture
/// .localDependencyClosure`), and checks the answer against the sandbox's
/// container. The requirement is one of two outcomes, never a third: every
/// referenced package resolves inside the container, or sandbox creation
/// is refused before anything is built. A sandbox whose manifests reach
/// outside it builds whatever lives out there instead of the copy, so its
/// verdicts are about a different tree.
///
/// Each test builds its manager the way a run does: the project's local
/// packages are resolved, laid out (`SandboxLayout`), and handed to
/// `WorkspaceManager(layout:…)` with the SwiftPM containment proof. A
/// sandbox has a container, which holds every copy, and a workspace inside
/// it, which is the project copy.
@Suite("Regression: sandboxes carry the local-package input closure", .subprocessExclusive)
struct LocalPackageSandboxClosureTests {
    // MARK: - Sibling packages are materialized

    @Test("Core -> ../SwiftMapper: the sibling package resolves inside the sandbox container")
    func siblingDependencyIsInsideContainer() async throws {
        let layoutRoot = try LocalPackageFixture.makeLayoutRoot(label: "sibling")
        defer { try? FileManager.default.removeItem(at: layoutRoot) }
        let core = layoutRoot.appendingPathComponent("Core")
        try LocalPackageFixture.writePackage(named: "Core", at: core, pathDependencies: ["../SwiftMapper"])
        try LocalPackageFixture.writePackage(named: "SwiftMapper", at: layoutRoot.appendingPathComponent("SwiftMapper"))

        let workspaces = try await Self.workspaces(for: core)
        let sandbox = try await workspaces.createSandbox(id: "baseline")
        let closure = try await LocalPackageFixture.localDependencyClosure(from: sandbox.workspaceRoot)

        #expect(closure.count == 1, "\(closure)")
        #expect(LocalPackageFixture.isContained(closure, in: sandbox.containerRoot), "\(closure)")
    }

    /// `dump-package` reports direct
    /// dependencies only, so `Logging` is found only by walking the graph.
    @Test("Core -> ../SwiftMapper -> ../Logging: the transitive sibling resolves inside the container too")
    func transitiveSiblingIsInsideContainer() async throws {
        let layoutRoot = try LocalPackageFixture.makeLayoutRoot(label: "chain")
        defer { try? FileManager.default.removeItem(at: layoutRoot) }
        let core = try LocalPackageFixture.writeSiblingChain(in: layoutRoot)

        let workspaces = try await Self.workspaces(for: core)
        let sandbox = try await workspaces.createSandbox(id: "baseline")
        let closure = try await LocalPackageFixture.localDependencyClosure(from: sandbox.workspaceRoot)

        #expect(closure.count == 2, "\(closure)")
        #expect(LocalPackageFixture.isContained(closure, in: sandbox.containerRoot), "\(closure)")
    }

    /// Holds today and must keep holding: a package inside the project root
    /// is already part of the project copy. The layout must not also list it
    /// as an extra root, which the layout's own unit tests pin.
    @Test("Core -> Vendor/Inner: a package inside the project root is carried by the project copy")
    func internalPackageIsCarriedByProjectCopy() async throws {
        let core = try LocalPackageFixture.makeLayoutRoot(label: "internal")
        defer { try? FileManager.default.removeItem(at: core) }
        try LocalPackageFixture.writePackage(named: "Core", at: core, pathDependencies: ["Vendor/Inner"])
        try LocalPackageFixture.writePackage(named: "Inner", at: core.appendingPathComponent("Vendor/Inner"))

        let workspaces = try await Self.workspaces(for: core)
        let sandbox = try await workspaces.createSandbox(id: "baseline")
        let closure = try await LocalPackageFixture.localDependencyClosure(from: sandbox.workspaceRoot)

        #expect(sandbox.workspaceRoot == sandbox.containerRoot)
        #expect(closure.count == 1, "\(closure)")
        #expect(LocalPackageFixture.isContained(closure, in: sandbox.containerRoot), "\(closure)")
    }

    // MARK: - Dependencies that escape the container are refused

    /// Refused by the containment proof. An absolute path is copied
    /// verbatim into the sandboxed manifest, so it still names the original
    /// tree.
    ///
    /// The path is spelled canonically (`/private/var`, not `/var`): through
    /// an alias it would be refused as a symlinked package before the
    /// containment question is ever asked.
    @Test("An absolute path to a package outside the project is refused or contained")
    func absolutePathOutsideProjectIsRefused() async throws {
        let layoutRoot = try LocalPackageFixture.makeCanonicalLayoutRoot(label: "absolute-outside")
        defer { try? FileManager.default.removeItem(at: layoutRoot) }
        let mapper = layoutRoot.appendingPathComponent("SwiftMapper")
        try LocalPackageFixture.writePackage(named: "SwiftMapper", at: mapper)
        let core = layoutRoot.appendingPathComponent("Core")
        try LocalPackageFixture.writePackage(named: "Core", at: core, pathDependencies: [mapper.path])

        let outcome = try await Self.sandboxOutcome(projectRoot: core)

        #expect(outcome.isRefusedOrContained, "\(outcome)")
    }

    /// What `run` and `dry-run` announce ("Local packages: ... copied into each
    /// sandbox") hangs off this signal, so it must fire for an accepted layout
    /// and never for a refused one.
    @Test("The containment-proven signal fires for a sibling package and not for an absolute path")
    func provenSignalFollowsValidation() async throws {
        let accepted = try LocalPackageFixture.makeLayoutRoot(label: "proven-sibling")
        defer { try? FileManager.default.removeItem(at: accepted) }
        let acceptedCore = accepted.appendingPathComponent("Core")
        try LocalPackageFixture.writePackage(named: "Core", at: acceptedCore, pathDependencies: ["../SwiftMapper"])
        try LocalPackageFixture.writePackage(named: "SwiftMapper", at: accepted.appendingPathComponent("SwiftMapper"))
        let acceptedCalls = Counter()
        _ = try await Self.workspaces(for: acceptedCore, onContainmentProven: { acceptedCalls.increment() })
            .createSandbox(id: "baseline")
        #expect(acceptedCalls.value == 1)

        let refused = try LocalPackageFixture.makeCanonicalLayoutRoot(label: "proven-absolute")
        defer { try? FileManager.default.removeItem(at: refused) }
        let mapper = refused.appendingPathComponent("SwiftMapper")
        try LocalPackageFixture.writePackage(named: "SwiftMapper", at: mapper)
        let refusedCore = refused.appendingPathComponent("Core")
        try LocalPackageFixture.writePackage(named: "Core", at: refusedCore, pathDependencies: [mapper.path])
        let refusedCalls = Counter()
        let manager = try await Self.workspaces(for: refusedCore, onContainmentProven: { refusedCalls.increment() })
        await #expect(throws: (any Error).self) { try await manager.createSandbox(id: "baseline") }
        #expect(refusedCalls.value == 0)
    }

    @Test("Without a containment proof the signal fires once, on the first sandbox")
    func provenSignalFiresWithoutProof() async throws {
        let root = try LocalPackageFixture.makeLayoutRoot(label: "proven-noproof")
        defer { try? FileManager.default.removeItem(at: root) }
        let core = root.appendingPathComponent("Core")
        try LocalPackageFixture.writePackage(named: "Core", at: core)
        let calls = Counter()
        let manager = try WorkspaceManager(
            layout: .projectOnly(core), scratchRoot: LocalPackageFixture.scratchRoot(for: core),
            onContainmentProven: { calls.increment() }
        )
        #expect(calls.value == 0)
        _ = try await manager.createSandbox(id: "a")
        _ = try await manager.createSandbox(id: "b")
        #expect(calls.value == 1)
    }

    /// Refused by the containment proof. This is the dangerous one: the
    /// build would compile the original `Vendor/Inner`, not the sandbox's
    /// copy, so a mutant placed there would never reach the binary. Spelled
    /// canonically for the same reason as the test above.
    @Test("An absolute path into the original project tree is refused or contained")
    func absolutePathIntoOriginalProjectIsRefused() async throws {
        let core = try LocalPackageFixture.makeCanonicalLayoutRoot(label: "absolute-inward")
        defer { try? FileManager.default.removeItem(at: core) }
        let inner = core.appendingPathComponent("Vendor/Inner")
        try LocalPackageFixture.writePackage(named: "Inner", at: inner)
        try LocalPackageFixture.writePackage(named: "Core", at: core, pathDependencies: [inner.path])

        let outcome = try await Self.sandboxOutcome(projectRoot: core)

        #expect(outcome.isRefusedOrContained, "\(outcome)")
    }

    /// The dependency path is inside the project, but it is a symlink whose
    /// absolute target is outside it; the sandbox would recreate the link
    /// verbatim, so the copy would still point out. Resolution refuses a
    /// symlinked package path before any sandbox exists.
    @Test("A dependency reached through an escaping symlink is refused or contained")
    func symlinkEscapeIsRefused() async throws {
        let layoutRoot = try LocalPackageFixture.makeLayoutRoot(label: "symlink-escape")
        defer { try? FileManager.default.removeItem(at: layoutRoot) }
        let mapper = layoutRoot.appendingPathComponent("SwiftMapper")
        try LocalPackageFixture.writePackage(named: "SwiftMapper", at: mapper)
        let core = layoutRoot.appendingPathComponent("Core")
        try LocalPackageFixture.writePackage(named: "Core", at: core, pathDependencies: ["Vendor/Link"])
        try FileManager.default.createDirectory(at: core.appendingPathComponent("Vendor"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: core.appendingPathComponent("Vendor/Link").path, withDestinationPath: mapper.path
        )

        let outcome = try await Self.sandboxOutcome(projectRoot: core)

        #expect(outcome.isRefusedOrContained, "\(outcome)")
    }

    /// Symlinked dependency paths are refused in the first version: the copy
    /// would recreate the link, and the link would lead back to the
    /// original tree.
    @Test("A sibling dependency whose path is a symlink is refused or contained")
    func symlinkedSiblingIsRefused() async throws {
        let layoutRoot = try LocalPackageFixture.makeLayoutRoot(label: "symlink-sibling")
        defer { try? FileManager.default.removeItem(at: layoutRoot) }
        try LocalPackageFixture.writePackage(named: "SwiftMapper", at: layoutRoot.appendingPathComponent("Real/SwiftMapper"))
        try FileManager.default.createSymbolicLink(
            atPath: layoutRoot.appendingPathComponent("SMLink").path, withDestinationPath: "Real/SwiftMapper"
        )
        let core = layoutRoot.appendingPathComponent("Core")
        try LocalPackageFixture.writePackage(named: "Core", at: core, pathDependencies: ["../SMLink"])

        let outcome = try await Self.sandboxOutcome(projectRoot: core)

        #expect(outcome.isRefusedOrContained, "\(outcome)")
    }

    // MARK: - Layout invariants

    /// Activation evidence compares compiled code across sandboxes, and the
    /// absolute build path's length reaches that code (see
    /// `SandboxPathLengthTests`). With a nested workspace, equal-length
    /// sandbox names are no longer enough on their own: the workspace and
    /// every dependency copy must sit at equal-length paths too.
    @Test("Baseline and mutant sandboxes put the workspace and its dependencies at equal-length paths")
    func baselineAndMutantPathsHaveEqualLength() async throws {
        let layoutRoot = try LocalPackageFixture.makeLayoutRoot(label: "equal-length")
        defer { try? FileManager.default.removeItem(at: layoutRoot) }
        let core = try LocalPackageFixture.writeSiblingChain(in: layoutRoot)
        let workspaces = try await Self.workspaces(for: core)

        let baseline = try await workspaces.createSandbox(id: "baseline")
        let mutant = try await workspaces.createSandbox(id: "mut_0123456789abcdef")

        #expect(baseline.containerRoot.path.count == mutant.containerRoot.path.count)
        #expect(baseline.workspaceRoot.path.count == mutant.workspaceRoot.path.count)

        let baselineClosure = try await LocalPackageFixture.localDependencyClosure(from: baseline.workspaceRoot)
        let mutantClosure = try await LocalPackageFixture.localDependencyClosure(from: mutant.workspaceRoot)
        #expect(LocalPackageFixture.isContained(baselineClosure, in: baseline.containerRoot), "\(baselineClosure)")
        #expect(LocalPackageFixture.isContained(mutantClosure, in: mutant.containerRoot), "\(mutantClosure)")
        #expect(baselineClosure.count == 2, "\(baselineClosure)")
        #expect(baselineClosure.map(\.canonicalPath.count).sorted() == mutantClosure.map(\.canonicalPath.count).sorted())
    }

    /// Two sandboxes that shared a
    /// dependency tree would let one build's writes into `.build` state or
    /// generated sources leak into the other.
    @Test("Parallel sandboxes each get their own copy of every local dependency")
    func parallelSandboxesDoNotShareDependencies() async throws {
        let layoutRoot = try LocalPackageFixture.makeLayoutRoot(label: "parallel")
        defer { try? FileManager.default.removeItem(at: layoutRoot) }
        let core = try LocalPackageFixture.writeSiblingChain(in: layoutRoot)
        let workspaces = try await Self.workspaces(for: core)

        let first = try await workspaces.createSandbox(id: "mut_first")
        let second = try await workspaces.createSandbox(id: "mut_second")
        let firstClosure = try await LocalPackageFixture.localDependencyClosure(from: first.workspaceRoot)
        let secondClosure = try await LocalPackageFixture.localDependencyClosure(from: second.workspaceRoot)

        #expect(LocalPackageFixture.isContained(firstClosure, in: first.containerRoot), "\(firstClosure)")
        #expect(LocalPackageFixture.isContained(secondClosure, in: second.containerRoot), "\(secondClosure)")
        #expect(Set(firstClosure.map(\.canonicalPath)).isDisjoint(with: secondClosure.map(\.canonicalPath)))

        // A write into the first sandbox's SwiftMapper copy must not show
        // up in the second sandbox's copy or in the original package.
        let firstMapper = try #require(firstClosure.first { $0.canonicalPath.hasSuffix("/SwiftMapper") })
        try Data("x".utf8).write(
            to: URL(fileURLWithPath: firstMapper.canonicalPath).appendingPathComponent("written-by-first")
        )
        let elsewhere = secondClosure.map(\.canonicalPath) + [layoutRoot.appendingPathComponent("SwiftMapper").path]
        let leaked = elsewhere.filter {
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("written-by-first").path)
        }
        #expect(leaked.isEmpty, "a write in one sandbox's dependency copy is visible elsewhere: \(leaked)")
    }

    /// Destroying a sandbox must remove its dependency copies with it; a
    /// leftover copy would be reused by the next sandbox with the same id,
    /// whose population keeps files whose size and date still match.
    @Test("Destroying a sandbox removes the whole container, dependency copies included")
    func destroyRemovesWholeContainer() async throws {
        let layoutRoot = try LocalPackageFixture.makeLayoutRoot(label: "destroy")
        defer { try? FileManager.default.removeItem(at: layoutRoot) }
        let core = try LocalPackageFixture.writeSiblingChain(in: layoutRoot)
        let scratch = LocalPackageFixture.scratchRoot(for: core)
        let workspaces = try await Self.workspaces(for: core)

        let sandbox = try await workspaces.createSandbox(id: "mut_destroy")
        let closure = try await LocalPackageFixture.localDependencyClosure(from: sandbox.workspaceRoot)
        #expect(closure.count == 2, "\(closure)")
        #expect(LocalPackageFixture.isContained(closure, in: sandbox.containerRoot), "\(closure)")

        try await workspaces.destroySandbox(sandbox)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .filter { !$0.hasPrefix(".") }
        #expect(remaining.isEmpty, "left behind under the scratch root: \(remaining)")
    }

    // MARK: - Support

    /// What happened when a sandbox was requested for `projectRoot`: either
    /// creation was refused, or it succeeded and this is the local-package
    /// closure its manifests reference.
    enum SandboxOutcome: CustomStringConvertible {
        case refused(String)
        case created(container: URL, closure: [LocalPackageFixture.Dependency])

        var isRefusedOrContained: Bool {
            switch self {
            case .refused:
                true
            case let .created(container, closure):
                LocalPackageFixture.isContained(closure, in: container)
            }
        }

        var description: String {
            switch self {
            case let .refused(reason):
                "refused: \(reason)"
            case let .created(container, closure):
                "created at \(container.path); closure: \(closure)"
            }
        }
    }

    /// A manager for `projectRoot` built as a run builds one: local
    /// packages resolved, then laid out, with the containment proof on the
    /// first sandbox.
    static func workspaces(
        for projectRoot: URL, onContainmentProven: (@Sendable () -> Void)? = nil
    ) async throws -> WorkspaceManager {
        let scratch = LocalPackageFixture.scratchRoot(for: projectRoot)
        let packages = try await SwiftPMLocalDependencyResolver().localPackageClosure(of: projectRoot)
        let layout = SandboxLayout.make(
            canonicalProjectRoot: CanonicalPath.resolve(projectRoot.path) ?? projectRoot.path, localPackages: packages
        )
        try SandboxExternalRootValidator.validate(layout: layout, excludes: WorkspaceManager.defaultExcludes, scratchRoot: scratch)
        return try WorkspaceManager(
            layout: layout, scratchRoot: scratch, containmentProof: SwiftPMSandboxContainmentProof(projectPath: nil),
            onContainmentProven: onContainmentProven
        )
    }

    /// Resolution, layout and sandbox creation, in the order a run does
    /// them. A refusal at any step counts as a refusal.
    static func sandboxOutcome(projectRoot: URL) async throws -> SandboxOutcome {
        let sandbox: Sandbox
        do {
            sandbox = try await workspaces(for: projectRoot).createSandbox(id: "baseline")
        } catch {
            return .refused("\(error)")
        }
        return try await .created(
            container: sandbox.containerRoot, closure: LocalPackageFixture.localDependencyClosure(from: sandbox.workspaceRoot)
        )
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
