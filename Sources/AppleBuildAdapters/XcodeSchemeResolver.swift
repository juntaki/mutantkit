import Foundation
import MutationExecution
import MutationModel

//
// Extracted from `XcodeBuildAdapter.swift` as part of this project's
// internal execution-engine restructuring (see its own, private planning
// notes, not part of this public repo, for the full rationale). A pure
// move of the scheme-discovery/resolution concern: no stored adapter state
// (`simulators`, `resolvedDestination`,
// `workerDevicesByWorkspace`, ...) is referenced here, only
// `configuration.project.scheme`, `projectArguments(in:)`'s own inputs
// (`projectFileRelativePath`, `kind`), `processRunner`, and the caller-supplied
// scheme-discovery log path (kept a per-call parameter rather than stored
// state, since `XcodeBuildAdapter.schemeDiscoveryLogPath` is a mutable `var`
// tests set *after* constructing the adapter — see
// `SchemeDiscoveryObservationLogTests`). No behavior change: every branch,
// diagnosis string, retry count, and timeout below is identical to the code
// this replaced.
//

/// The scheme-discovery/resolution concern `XcodeBuildAdapter` delegates to:
/// resolving a configured scheme, or discovering one via
/// `xcodebuild -list -json` with the empty-result retry policy and
/// observation logging real CI flakes required.
struct XcodeSchemeResolver: Sendable {
    let configuredScheme: String?
    /// The `.xcodeproj`/`.xcworkspace`, relative to the project root — see
    /// `XcodeBuildAdapter.projectFileRelativePath`'s own doc comment for why
    /// this is stored relative rather than absolute.
    let projectFileRelativePath: String?
    let kind: ProjectKind
    let processRunner: ProcessRunner

    /// `xcodebuild -list -json`'s own budget. Named rather than inlined so
    /// the diagnosis for a run killed at this deadline can quote the number
    /// the run was actually held to, instead of a second copy of it.
    static let schemeListTimeoutSeconds: Double = 120

    /// A discovery attempt's raw last `ProcessResult`, alongside the
    /// resolved scheme list — `resolve`'s own thrown `BuildFailure` needs the
    /// real exit code/stdout/stderr for a genuine "no schemes" diagnosis;
    /// `discover` itself stays a plain `[String]` for its two other call
    /// sites (`XcodeConfigDetector`, `Diagnostics`, reached via
    /// `XcodeBuildAdapter.discoverSchemes`), which have never needed more
    /// than the scheme list.
    struct SchemeDiscoveryResult {
        let schemes: [String]
        let lastResult: ProcessResult?
        /// Whether `xcodebuild` actually produced a scheme list to read.
        ///
        /// `schemes.isEmpty` alone cannot answer that, and conflating the
        /// two is precisely how a 120-second timeout with empty output got
        /// reported to a user as "no schemes are available here" — see
        /// `SchemeResolutionDiagnosis`. `false` means the emptiness is an
        /// absence of evidence; `true` means `xcodebuild` was asked, it
        /// answered, and the answer was none.
        let answered: Bool
    }

    /// `-workspace`/`-project` resolved inside `workspace`, or nothing for a
    /// package. Identical to `XcodeBuildAdapter.projectArguments(in:)`,
    /// which stays on the adapter (build/batch code also needs it) — this is
    /// the resolver's own copy over the same two inputs, not a shared call.
    private func projectArguments(in workspace: URL) -> [String] {
        guard let projectFileRelativePath else { return [] }
        let path = workspace.appendingPathComponent(projectFileRelativePath).path
        switch kind {
        case .xcodeWorkspace: return ["-workspace", path]
        case .xcodeProject: return ["-project", path]
        case .swiftPackageApple, .swiftPackageMacOS, .auto: return []
        }
    }

    /// The scheme to build.
    ///
    /// Resolved from configuration when given, otherwise discovered. Never
    /// derived from the project's name: SwiftPM's generated scheme is
    /// `<Package>-Package`, and an `.xcodeproj`'s schemes need not mention the
    /// project at all, so a name built by convention names something that does not
    /// exist.
    func resolve(in workspace: URL, logPath: String?) async throws -> String {
        if let configuredScheme { return configuredScheme }

        let discovery = await discoverWithDiagnostics(in: workspace, logPath: logPath)
        let schemes = discovery.schemes

        guard !schemes.isEmpty else {
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: SchemeResolutionDiagnosis.noSchemeResolved(
                    answered: discovery.answered,
                    lastResult: discovery.lastResult,
                    timeoutSeconds: Self.schemeListTimeoutSeconds
                ),
                command: listCommand(in: workspace, result: discovery.lastResult),
                output: discovery.lastResult?.combinedOutput ?? ""
            )
        }

        guard schemes.count == 1 else {
            throw BuildFailure(
                kind: .infrastructure,
                diagnosis: """
                \(schemes.count) schemes are available (\(schemes.joined(separator: ", "))) \
                and mutantkit will not choose for you. Set project.scheme in mutantkit.yml.
                """,
                command: listCommand(in: workspace, result: discovery.lastResult),
                output: discovery.lastResult?.combinedOutput ?? ""
            )
        }

        return schemes[0]
    }

    private func listCommand(in workspace: URL, result: ProcessResult?) -> CommandRecord {
        CommandRecording.record(
            executable: ToolPaths.xcodebuild,
            arguments: projectArguments(in: workspace) + ["-list", "-json"],
            workingDirectory: workspace,
            result: result
        )
    }

    /// Discovered schemes, or an empty list when discovery itself failed.
    ///
    /// Non-throwing because the two callers that take this plain `[String]`
    /// form (`XcodeConfigDetector`, `Diagnostics`, both via
    /// `XcodeBuildAdapter.discoverSchemes`) genuinely treat "could not ask"
    /// and "there are none" the same way: both mean no scheme can be
    /// resolved here and now, and neither caller is reporting a failure to a
    /// user. `resolve` is the one that *is*, and it deliberately does not
    /// use this form — see `SchemeDiscoveryResult.answered`, and
    /// `SchemeResolutionDiagnosis` for the real CI failure that proved the
    /// two must not share one remedy.
    ///
    /// Retries a *clean, fast, empty* result up to `emptyResultRetryCount`
    /// additional times before giving up — real CI evidence (2026-09-12,
    /// `xcode-project`'s own recurring "No schemes are available here"
    /// flake, reproduced identically 4 times) showed this exact call
    /// reporting zero schemes for a project whose shared scheme a
    /// *separate*, immediately preceding poll of the identical invocation
    /// had just confirmed visible — i.e. `xcodebuild`'s own scheme-visibility state can
    /// genuinely flicker under real resource pressure, not merely lag
    /// once and then stay caught up. This is a real robustness gap for
    /// any user on a loaded machine, not only a CI artifact, so the fix
    /// belongs here rather than in a test's own pre-flight wait. Only a
    /// clean empty result is retried, never a timeout or a crash — those
    /// already have their own, larger `timeoutSeconds` budget and retrying
    /// them here would only compound a real hang.
    func discover(in workspace: URL, emptyResultRetryCount: Int = 2, logPath: String?) async -> [String] {
        await discoverWithDiagnostics(
            in: workspace, emptyResultRetryCount: emptyResultRetryCount, logPath: logPath
        ).schemes
    }

    func discoverWithDiagnostics(
        in workspace: URL, emptyResultRetryCount: Int = 2, logPath: String?
    ) async -> SchemeDiscoveryResult {
        let arguments = projectArguments(in: workspace) + ["-list", "-json"]
        // Every `return` below is preceded by one observation row, and the
        // fall-through case records one too, so the log holds one row per
        // attempt actually made -- successes included. Successes are the
        // whole point: three failures at the 120s deadline say the budget
        // touches the distribution's edge and nothing more, and the budget
        // stays where it is until the successful durations say what it
        // should be. See `SchemeDiscoveryObservationLog`.
        func observe(_ outcome: SchemeDiscoveryObservationLog.Outcome,
                     attempt: Int, result: ProcessResult?, schemeCount: Int) {
            SchemeDiscoveryObservationLog.record(
                attempt: attempt,
                outcome: outcome,
                result: result,
                schemeCount: schemeCount,
                budgetSeconds: Self.schemeListTimeoutSeconds,
                path: logPath
            )
        }
        for attempt in 0 ... emptyResultRetryCount {
            let result = try? await processRunner(
                ToolPaths.xcodebuild, arguments, workspace, Self.schemeListTimeoutSeconds
            )
            guard let result, result.succeeded else {
                observe(result == nil ? .notStarted : .didNotSucceed,
                        attempt: attempt, result: result, schemeCount: 0)
                return SchemeDiscoveryResult(schemes: [], lastResult: result, answered: false)
            }
            let schemes = SchemeListJSON.schemes(from: result.standardOutput)
            if !schemes.isEmpty {
                observe(.schemesFound, attempt: attempt, result: result, schemeCount: schemes.count)
                return SchemeDiscoveryResult(schemes: schemes, lastResult: result, answered: true)
            }
            // An empty list read out of output the supervisor never confirmed
            // it had fully drained is not an answer: `ProcessResult
            // .outputComplete`'s own contract requires every consumer that
            // derives a failure classification to fail closed here, and the
            // classification this feeds ("the project has no schemes") is
            // exactly the kind that must not rest on possibly-truncated
            // bytes. A *non-empty* list needs no such guard — truncated JSON
            // does not parse, so any scheme name read out at all came from
            // a complete document.
            guard result.outputComplete else {
                observe(.outputIncomplete, attempt: attempt, result: result, schemeCount: 0)
                return SchemeDiscoveryResult(schemes: [], lastResult: result, answered: false)
            }
            if attempt == emptyResultRetryCount {
                observe(.answeredNone, attempt: attempt, result: result, schemeCount: 0)
                return SchemeDiscoveryResult(schemes: [], lastResult: result, answered: true)
            }
            observe(.emptyRetrying, attempt: attempt, result: result, schemeCount: 0)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return SchemeDiscoveryResult(schemes: [], lastResult: nil, answered: false)
    }
}
