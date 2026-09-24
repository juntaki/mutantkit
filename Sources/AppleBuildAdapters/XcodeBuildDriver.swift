import Foundation
import MutationExecution
import MutationModel

//
// Extracted from `XcodeBuildAdapter.swift` as part of this project's
// internal execution-engine restructuring (see its own, private planning
// notes, not part of this public repo, for the full rationale).
// `build(in:enableCoverage:extraArguments:)` moves here in full, unchanged
// body, becoming this type's own `build`.
//
// This is the structural enforcement of Structural Invariant 1 ("a build
// never leases a simulator"), not just a relocation: `BuildDriver`'s own
// stored-property list has no `SimulatorPool`, no `SimulatorLeaseCoordinator`,
// and no `resolvedDestination` field at all — a future editor who wanted this
// type to lease a device would have to add a stored property to a type whose
// entire reason for existing is not having one, a visible, reviewable diff
// rather than a silent one. `destination()` — a plain `String`, never a
// lease — stays a value the adapter computes and passes in as
// `buildDestination`, exactly as plan §6.6 describes.
//
// `schemeDiscoveryLogPath` is threaded through per call, not stored, for the
// same reason `XcodeSchemeResolver` and the adapter's own `resolveScheme`/
// `discoverSchemes` forwarders do: it is a mutable `var` on the adapter that
// tests set *after* construction (see `SchemeDiscoveryObservationLogTests`),
// so capturing its value at `BuildDriver`'s own construction time would stop
// observing later mutations.
//
// `projectArguments(in:)`/`derivedDataPath(in:)`/`productsDirectory(in:)` are
// each this type's own copy of the identical logic on `XcodeBuildAdapter`,
// not a shared call back into it — the same choice `XcodeSchemeResolver`
// already made for its own `projectArguments(in:)` copy in Step 1, for the
// same reason: the adapter's own versions stay in place because other code
// still reads them directly (`derivedDataPath(in:)` is tested directly and
// read by `Diagnostics.swift`; `projectArguments(in:)` is also called from
// `resolveSchemataBuildReceipt`; `productsDirectory(in:)` is the documented,
// canonical spot two other files' doc comments already point readers at —
// see plan §7 Step 7's own description of what remains on the adapter as its
// "hub").
//
// No behavior change: every argument, flag, and diagnosis string below is
// identical to the code this replaced. No unit test reaches `build(in:...)`
// directly — it was `private`, and remains reachable only through the
// adapter's own `build(in:enableCoverage:extraArguments:)` forwarder, which
// every one of its three original callers (`buildBaseline`/`buildMutant`,
// `buildSchemataChunk`, `readCoverage`) keeps calling unchanged — so this was
// verified by a manual side-by-side diff against the pre-extraction body,
// backed by `swift build --build-tests` (plan §7 Step 6's stated bar; no
// fast unit test reaches this code, same coverage gap as Steps 3-5).
//

/// Builds a scheme via `xcodebuild build-for-testing`. Never leases a
/// simulator — see this file's own header comment for how that is made a
/// structural fact, not an incidental one.
struct BuildDriver: Sendable {
    let kind: ProjectKind
    /// See `XcodeBuildAdapter.projectFileRelativePath`'s own doc comment.
    let projectFileRelativePath: String?
    let configuration: Configuration
    /// Step 1's collaborator — build needs scheme resolution too. The same
    /// instance the adapter holds as `schemeResolver`, not a copy: unlike
    /// `projectArguments`/`derivedDataPath`, scheme resolution is a whole
    /// collaborator already, so there is no "duplicate the logic" choice to
    /// make here.
    let scheme: XcodeSchemeResolver

    /// - Parameter enableCoverage: adds `-enableCodeCoverage YES` to
    ///   `build-for-testing` itself. Confirmed necessary, not just the test
    ///   invocation's own `-enableCodeCoverage YES`, on a real Xcode
    ///   project (a hand-authored `.xcodeproj`, not an auto-generated
    ///   SwiftPM scheme): source-based coverage is compiled in, and a
    ///   binary `build-for-testing` produced without the flag has no
    ///   instrumentation for `test-without-building` to retroactively turn
    ///   on — confirmed by a bundle whose `content-availability` reported
    ///   `hasCoverage: false` despite the test-time flag. Only ever used
    ///   for the dedicated coverage rebuild in `readCoverage`/
    ///   `measurePerTestCoverage`, never for `buildBaseline`/`buildMutant`:
    ///   an instrumented baseline's product hash would differ from every
    ///   mutant's uninstrumented one purely from the added profiling
    ///   counters, making every mutant look "activated" whether or not its
    ///   own edit actually reached the binary — the same reason
    ///   `SwiftPackageMacOSAdapter` captures its baseline's hash *before*
    ///   the coverage-instrumented test rebuild rather than after.
    func build(
        in workspace: URL,
        buildDestination: String,
        schemeDiscoveryLogPath: String?,
        enableCoverage: Bool = false,
        extraArguments: [String] = []
    ) async throws -> BuildArtifact {
        let resolvedScheme = try await scheme.resolve(in: workspace, logPath: schemeDiscoveryLogPath)
        let derivedData = derivedDataPath(in: workspace)

        // `build-for-testing`, not `build`: it produces the test bundles *and* the
        // `.xctestrun` that `test-without-building` needs, which is what lets the
        // build and test phases be timed and classified separately.
        var arguments = projectArguments(in: workspace) + [
            "build-for-testing",
            "-scheme", resolvedScheme,
            "-destination", buildDestination,
            "-derivedDataPath", derivedData.path
        ]
        // Build-setting overrides (e.g. XcodeLinkerInjector's OTHER_LDFLAGS/
        // LIBRARY_SEARCH_PATHS) go last, matching xcodebuild's own
        // convention of trailing NAME=value pairs after every flag.
        arguments.append(contentsOf: extraArguments)
        if enableCoverage {
            arguments.append(contentsOf: ["-enableCodeCoverage", "YES"])
        }

        let result: ProcessResult
        do {
            result = try await ProcessSupervisor.run(
                executable: ToolPaths.xcodebuild,
                arguments: arguments,
                workingDirectory: workspace,
                timeoutSeconds: configuration.timeouts.baselineSeconds,
                terminationGracePeriodSeconds: configuration.timeouts.terminationGracePeriodSeconds
            )
        } catch {
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: "Could not launch xcodebuild: \(error)",
                command: CommandRecording.record(
                    executable: ToolPaths.xcodebuild,
                    arguments: arguments,
                    workingDirectory: workspace,
                    result: nil
                ),
                output: ""
            )
        }

        let command = CommandRecording.record(
            executable: ToolPaths.xcodebuild,
            arguments: arguments,
            workingDirectory: workspace,
            result: result
        )

        guard result.succeeded else {
            throw BuildClassifier.failure(from: result, command: command)
        }

        let products = productsDirectory(in: workspace)
        let xctestrun = try XCTestRunLocator.locate(in: products, command: command)

        return BuildArtifact(
            productsDirectory: products,
            productHash: TestProductHasher.hash(productsDirectory: products),
            xctestrunPath: xctestrun,
            command: command
        )
    }

    /// `-workspace`/`-project` resolved inside `workspace`, or nothing for a
    /// package. Identical to `XcodeBuildAdapter.projectArguments(in:)`,
    /// which stays on the adapter (`resolveSchemataBuildReceipt` also needs
    /// it) — this is this type's own copy over the same two inputs, not a
    /// shared call, matching `XcodeSchemeResolver`'s own precedent.
    private func projectArguments(in workspace: URL) -> [String] {
        guard let projectFileRelativePath else { return [] }
        let path = workspace.appendingPathComponent(projectFileRelativePath).path
        switch kind {
        case .xcodeWorkspace: return ["-workspace", path]
        case .xcodeProject: return ["-project", path]
        case .swiftPackageApple, .swiftPackageMacOS, .auto: return []
        }
    }

    /// Where DerivedData goes for this workspace. Identical to
    /// `XcodeBuildAdapter.derivedDataPath(in:)`, which stays on the adapter
    /// (tested directly, and read by `Diagnostics.swift`) — this is this
    /// type's own copy, not a shared call.
    private func derivedDataPath(in workspace: URL) -> URL {
        if let configured = configuration.project.derivedDataPath {
            guard configured.hasPrefix("/") else {
                return workspace.appendingPathComponent(configured)
            }
            return URL(fileURLWithPath: configured)
        }
        return workspace.appendingPathComponent(".mutantkit/DerivedData", isDirectory: true)
    }

    /// `XcodeBuildAdapter`'s own former copy of this (identical body) was
    /// deleted as dead code once nothing outside this driver called it any
    /// more — this is now the one real implementation; other files' doc
    /// comments pointing at "`XcodeBuildAdapter.productsDirectory(in:)`"
    /// mean this type.
    private func productsDirectory(in workspace: URL) -> URL {
        derivedDataPath(in: workspace).appendingPathComponent("Build/Products", isDirectory: true)
    }
}
