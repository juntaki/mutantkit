import AppleBuildAdapters
import Foundation
import MutationExecution
import MutationModel

/// Reads the toolchain's identity from the toolchain itself.
///
/// The planner and the reporters are deliberately subprocess-free, so gathering
/// this is the CLI's job — it is the only layer allowed to ask the outside world
/// questions.
/// Everything one `ToolchainProbe.fingerprint(workingDirectory:
/// resolvedDestination:)` call produces: the identity values themselves,
/// plus whether every cache-identity-relevant subprocess probe behind them
/// was proven fully captured.
///
/// `fingerprint` alone is never enough to decide whether the *values*
/// inside it are safe to hash into a cache key: a genuinely unreadable
/// toolchain (no `swift` on `PATH`) and a probe that could not be trusted
/// (`ProcessResult.outputComplete == false`, a timeout, a signal, a thrown
/// launch error, or an exit-0 run that printed nothing parseable) can both
/// leave a field `nil` or "unknown", but only the first is a reproducible
/// fact about *this machine* — the second is evidence that was lost or
/// never actually gathered, which could just as easily have been a
/// different, real value on a re-run or on a different machine. Two
/// machines with genuinely different toolchains, each hitting an
/// untrustworthy probe on a different field, must not be able to collapse
/// onto the identical cache identity just because both fields read
/// "unknown" — see `identityEvidenceComplete` below.
struct ToolchainProbeResult: Sendable {
    let fingerprint: ToolchainFingerprint
    /// `false` when any subprocess this probe ran to build `fingerprint`
    /// either could not be proven fully read (`ProcessResult
    /// .outputComplete == false`) or ran but could not be trusted as proof
    /// of anything — timed out, was signalled, threw launching, or exited
    /// successfully with no parseable version string
    /// (`VersionProbeOutcome.probeFailed`) — before this result was built.
    /// Never set by a probe that found a genuinely reproducible absence
    /// (`VersionProbeOutcome.notPresent`: the executable simply is not on
    /// this machine) — that is a legitimate, reproducible "unknown" on this
    /// machine, not lost evidence, and already handled by `fingerprint`'s
    /// own `nil`/"unknown" fields.
    ///
    /// Despite the name, this is no longer only a cache-identity concern:
    /// `PlanCommand`/`VerifyCommand` also read it to decide whether a
    /// toolchain identity is under-evidenced before writing a plan or
    /// claiming a compatibility match. A caller computing a cache key from
    /// `fingerprint` must still treat `false` here exactly like
    /// `RunContextProbe`'s own git-output incompleteness guard: refuse to
    /// trust the resulting digest rather than hash a value that might
    /// silently be wrong.
    let identityEvidenceComplete: Bool
}

enum ToolchainProbe {
    /// What a single version-string subprocess probe (`swift --version`,
    /// `xcodebuild -version`, `xcrun --show-sdk-version`/`--show-sdk-build-
    /// version`) actually found. Internal, not `private`: `combinedIdentityEvidenceComplete`
    /// below is unit-tested directly against real outcome values
    /// (`ToolchainProbeCombinedCompletenessTests`), which needs to
    /// construct them from another file.
    enum VersionProbeOutcome {
        /// The subprocess ran, exited successfully, and its output was
        /// proven fully captured.
        case value(String)
        /// The executable simply is not on this machine (`FileManager
        /// .isExecutableFile` found nothing at the fixed path) — a clean,
        /// ENOENT-style absence, recorded as "unknown" exactly as before
        /// this type existed. Reproducible: re-running the identical probe
        /// on the identical machine reports the identical outcome, because
        /// nothing was ever launched that could time out, be signalled, or
        /// answer differently on a retry.
        case notPresent
        /// The subprocess was launched but its outcome proves nothing
        /// reproducible about this machine: it could not be spawned, it
        /// timed out, it died to a signal, it exited non-zero, or it
        /// exited `0` with no parseable version line. Every one of these is
        /// a fact about *this run of the probe*, not a stable fact about
        /// the machine — the identical probe on the identical, unchanged
        /// machine could easily answer differently next time (Xcode exists
        /// but `xcodebuild -version` happened to time out once). Must be
        /// treated exactly like `.incomplete` for identity-evidence
        /// purposes: collapsing it into "unknown" the same way
        /// `.notPresent` is would let a merely-unlucky probe hash
        /// identically to a machine with no toolchain at all, or to a
        /// different failed probe on a genuinely different machine.
        case probeFailed
        /// The subprocess exited successfully but `ProcessResult
        /// .outputComplete` was `false` — evidence that was lost, not a
        /// fact about the machine. Must never be treated as either a real
        /// value or `.notPresent`: collapsing it into "unknown" the same
        /// way `.notPresent` is would let a truncated capture hash
        /// identically to a machine with no toolchain at all, or to a
        /// different truncated capture on a genuinely different machine —
        /// the exact false-cache-hit shape this type exists to close.
        case incomplete

        var value: String? {
            if case let .value(value) = self { return value }
            return nil
        }

        /// Whether this outcome must veto identity-evidence completeness —
        /// true for both `.incomplete` (evidence lost after a successful
        /// exit) and `.probeFailed` (no reproducible fact was ever
        /// established). `.notPresent` and `.value` never veto: both are
        /// stable, reproducible outcomes safe to hash.
        var vetoesIdentityEvidence: Bool {
            switch self {
            case .incomplete, .probeFailed: true
            case .value, .notPresent: false
            }
        }
    }

    /// Whether a set of version-probe outcomes are all safe to treat as part
    /// of a reproducible identity: `true` only when *none* of them
    /// `.vetoesIdentityEvidence` — see `VersionProbeOutcome`'s own doc
    /// comments for why a single incomplete-or-failed probe (even just the
    /// SDK's build-number half, with its paired version probe fine) must
    /// veto the whole identity, not just the field it belongs to.
    /// `.notPresent` never vetoes anything here: it is a genuine,
    /// reproducible fact about the machine, not lost or unproven evidence.
    ///
    /// Split out of `fingerprint`/`buildSDKIdentity`'s own inline boolean
    /// logic purely so it can be pinned by a direct, no-subprocess unit test
    /// (`ToolchainProbeCombinedCompletenessTests`) that calls this exact
    /// function, rather than a test that merely hand-constructs the boolean
    /// it should have produced — mirrors `ProcessSupervisor
    /// .classify(readResult:errno:)`'s own reason for existing as a
    /// standalone function.
    static func combinedIdentityEvidenceComplete(_ outcomes: VersionProbeOutcome...) -> Bool {
        !outcomes.contains { $0.vetoesIdentityEvidence }
    }

    /// `resolvedDestination`: the run's own already-resolved destination
    /// (`nil` for callers with no destination yet, e.g. `mutantkit plan`,
    /// which legitimately has nothing to report for either
    /// `buildSDKIdentity`/`destinationRuntimeIdentity` — see those fields'
    /// own doc comments). Passing it through here, rather than probing
    /// generically, is deliberate: `xcodebuild`'s own destination
    /// resolution is itself ambiguous without a concretely resolved device
    /// (`ResolvedDestination`'s own doc comment), so anything this function
    /// guessed on its own could disagree with what the run actually
    /// built/tested against.
    static func fingerprint(
        workingDirectory: URL, resolvedDestination: ResolvedDestination? = nil
    ) async -> ToolchainProbeResult {
        async let swiftOutcome = firstLine(of: "/usr/bin/swift", arguments: ["--version"], in: workingDirectory)
        async let xcodeOutcome = firstLine(of: "/usr/bin/xcodebuild", arguments: ["-version"], in: workingDirectory)
        async let sdk = buildSDKIdentity(resolvedDestination: resolvedDestination, workingDirectory: workingDirectory)

        let swift = await swiftOutcome
        let xcode = await xcodeOutcome
        let sdkResult = await sdk

        let fingerprint = ToolchainFingerprint(
            toolVersion: ToolVersion.version,
            toolCommitSHA: ToolVersion.commitSHA,
            // An unreadable toolchain is recorded as unknown rather than guessed.
            // A wrong fingerprint is worse than an absent one: it would let a
            // plan look reproducible on a machine where it is not.
            swiftVersion: swift.value ?? "unknown",
            swiftSyntaxVersion: ToolVersion.swiftSyntaxVersion,
            xcodeVersion: xcode.value,
            buildSDKIdentity: sdkResult.identity,
            // Deliberately independent of `buildSDKIdentity` above, not
            // derived from it: a build's SDK and a test run's simulator
            // runtime are two genuinely separate axes (the SDK a project
            // compiles against is whatever Xcode's toolchain resolves for
            // the platform; the runtime a resolved *device* boots can be an
            // explicitly older one the destination string names) — see
            // `ToolchainFingerprint.destinationRuntimeIdentity`'s own doc
            // comment.
            destinationRuntimeIdentity: resolvedDestination?.device.map { "simulator:\($0.runtimeIdentifier)" }
        )

        return ToolchainProbeResult(
            fingerprint: fingerprint,
            identityEvidenceComplete: Self.combinedIdentityEvidenceComplete(swift, xcode) && sdkResult.complete
        )
    }

    /// See `ToolchainFingerprint.buildSDKIdentity`'s own doc comment for the
    /// exact shape. Platform-aware, not hardcoded to one SDK: derives the
    /// canonical `xcrun --sdk <name>` platform from the destination's own
    /// `platform=` field (`DestinationResolver.field`, the same parser
    /// `SchemataRuntimePlatform`/the resolver itself already use), covering
    /// every Apple platform this catalog's destinations can name — not just
    /// the two (`macosx`/`iphonesimulator`) `SchemataRuntimePlatform` itself
    /// deliberately fails closed on for its own, narrower schemata-archive-
    /// linking purpose.
    /// `complete` is `true` whenever there was nothing to probe at all (no
    /// destination, an unmodeled platform, the Catalyst-variant carve-out)
    /// or every probe actually run was `.value`/`.notPresent` — never
    /// `.incomplete`/`.probeFailed`. `false` the moment either the version
    /// *or* the build-number probe comes back `.incomplete`/`.probeFailed`:
    /// a truncated or failed build-number capture must not be allowed to
    /// silently degrade `identity` to a coarser-but-plausible-looking
    /// string (missing only its `(build)` suffix) the way a `.notPresent`
    /// build probe legitimately does — that string would still get hashed
    /// into a cache key as if it were the whole, real SDK identity.
    private static func buildSDKIdentity(
        resolvedDestination: ResolvedDestination?, workingDirectory: URL
    ) async -> (identity: String?, complete: Bool) {
        guard let requested = resolvedDestination?.requested,
              let platformValue = DestinationResolver.field(named: "platform", inDestination: requested)
              ?? DestinationResolver.field(named: "generic/platform", inDestination: requested),
              let sdkName = xcrunSDKName(forPlatformValue: platformValue)
        else { return (nil, true) }
        // `platform=macOS,variant=Mac Catalyst` builds for `-macabi`, not
        // plain macOS — a real, different SDK/ABI combination this catalog
        // does not otherwise model, on the same fail-closed footing
        // `SchemataRuntimePlatform.resolve`'s own doc comment already
        // documents for the identical destination shape. Never guessed as
        // plain `macosx`.
        if sdkName == "macosx",
           let variant = DestinationResolver.field(named: "variant", inDestination: requested),
           variant.localizedCaseInsensitiveContains("Catalyst") {
            return (nil, true)
        }

        async let versionOutcome = firstLine(
            of: "/usr/bin/xcrun", arguments: ["--sdk", sdkName, "--show-sdk-version"], in: workingDirectory
        )
        async let buildOutcome = firstLine(
            of: "/usr/bin/xcrun", arguments: ["--sdk", sdkName, "--show-sdk-build-version"], in: workingDirectory
        )
        let version = await versionOutcome
        let build = await buildOutcome

        if !Self.combinedIdentityEvidenceComplete(version, build) {
            // Never report a value alongside this: a version-probe-incomplete
            // case already fell through `guard let version` below as `nil`
            // before this type existed, and a build-probe-incomplete case
            // must not instead leak the version-only string — the caller-
            // visible signal that anything is wrong here is `complete: false`
            // and `RunContextProbe`/its cache-key computation refusing to
            // trust it, not a `nil` a reader might mistake for "no
            // destination".
            return (nil, false)
        }
        guard let versionValue = version.value else { return (nil, true) }
        let buildSuffix = build.value.map { "(\($0))" } ?? ""
        return ("sdk:\(sdkName):\(versionValue)\(buildSuffix)", true)
    }

    /// The exact platform-value spellings `xcodebuild -destination` accepts
    /// (confirmed against this project's own destination fixtures in
    /// `SchemataRuntimePlatformTests`/`DestinationResolverTests`), mapped to
    /// `xcrun`'s own canonical SDK names. Case-insensitive: `xcodebuild`
    /// itself treats `platform=iOS Simulator` and `platform=ios simulator`
    /// identically.
    private static func xcrunSDKName(forPlatformValue platformValue: String) -> String? {
        let normalized = platformValue.lowercased()
        switch normalized {
        case "macos": return "macosx"
        case "ios": return "iphoneos"
        case "ios simulator": return "iphonesimulator"
        case "tvos": return "appletvos"
        case "tvos simulator": return "appletvsimulator"
        case "watchos": return "watchos"
        case "watchos simulator": return "watchsimulator"
        case "visionos": return "xros"
        case "visionos simulator": return "xrsimulator"
        default: return nil
        }
    }

    /// Internal, not `private`: exercised directly by
    /// `ToolchainProbeVersionOutcomeTests` against scripted executables this
    /// suite controls, so the `.notPresent`/`.probeFailed`/`.incomplete`
    /// split below can be pinned against a real subprocess without waiting
    /// on `fingerprint`'s own hardcoded `/usr/bin/...` paths to fail in the
    /// right way.
    static func firstLine(
        of executable: String,
        arguments: [String],
        in workingDirectory: URL
    ) async -> VersionProbeOutcome {
        // A clean, reproducible absence: nothing was ever launched, so
        // nothing here can time out, be signalled, or answer differently on
        // a retry.
        guard FileManager.default.isExecutableFile(atPath: executable) else { return .notPresent }

        do {
            let result = try await ProcessSupervisor.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                // A version probe that has not answered in 30s is broken, and
                // waiting longer will not make it answer.
                timeoutSeconds: 30
            )
            // Checked before `succeeded`: an incomplete capture proves
            // nothing one way or the other about what the process actually
            // printed, so it gets its own outcome rather than being folded
            // into "probeFailed" — see `VersionProbeOutcome.incomplete`'s own
            // doc comment for why the two must stay distinguishable all the
            // way up through `identityEvidenceComplete`.
            guard result.outputComplete else { return .incomplete }
            // Non-zero exit, a timeout, and death by signal are all folded
            // into `succeeded == false` here — none of them is a
            // reproducible fact about this machine the way a missing
            // executable is: the identical probe against the identical,
            // unchanged toolchain could easily succeed on the very next
            // run. See `VersionProbeOutcome.probeFailed`'s own doc comment.
            guard result.succeeded else { return .probeFailed }
            guard let value = String(decoding: result.standardOutput, as: UTF8.self)
                .split(separator: "\n")
                .first
                .map({ $0.trimmingCharacters(in: .whitespaces) })
            else { return .probeFailed }
            return .value(value)
        } catch {
            // The executable exists (the guard above already confirmed
            // that) but could not actually be launched/piped — a transient,
            // unreproducible failure, not a clean absence.
            return .probeFailed
        }
    }
}
