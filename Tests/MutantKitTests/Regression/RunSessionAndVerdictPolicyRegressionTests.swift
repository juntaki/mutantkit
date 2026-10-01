import Foundation
import Testing

/// Turns four of an internal structural-invariants audit's 14 uncovered
/// findings into permanent, mechanical gates. See
/// `V2InvariantsAuditRegressionSupport`'s own doc comment for why a
/// real-source textual re-scan, not an executed test, is the correct method
/// for this whole audit-to-regression-test task — every fact pinned below
/// was itself established by direct source reading plus `grep`, never by
/// running the code (`RunSession`/`SchemataMutationRunner`/
/// `HybridExecutionEngine` all require a real toolchain/adapter to execute
/// meaningfully).
@Suite("Regression: RunSession's force-unwrap asymmetry stays honest")
struct RunSessionForceUnwrapAsymmetryRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    /// §1: `RunSession.projectRoot`/`.toolchain` are `Optional` at the
    /// shared-type level (`RunSession.swift:52-60`) *specifically* because
    /// `SchemataMutationRunner` has no real value to supply — not because
    /// `MutationRunner` ever needs them to be. `MutationRunner`'s own two
    /// computed properties force-unwrap them
    /// (`private var projectRoot: URL { session.projectRoot! }`,
    /// `MutationRunner.swift:101`, and the analogous `toolchain` property)
    /// and that is safe *only* because `MutationRunner`'s own `init` always
    /// supplies a real value when it builds its `session`
    /// (`MutationRunner.swift:234-242`). If a future refactor ever let that
    /// construction pass `nil` for either field — e.g. by sharing
    /// construction logic with `SchemataMutationRunner`'s own `nil, nil`
    /// path without preserving this asymmetry — `MutationRunner`'s own
    /// force-unwraps would crash on the very first read, with no compiler
    /// warning, since the type itself is `Optional` and always was.
    @Test("RunSession's two Optional fields are Optional, and MutationRunner force-unwraps both")
    func runSessionFieldsAreOptionalAndMutationRunnerForceUnwrapsThem() throws {
        let runSession = try Support.read("MutationExecution/RunSession.swift")
        #expect(runSession.contains("let projectRoot: URL?"))
        #expect(runSession.contains("let toolchain: ToolchainFingerprint?"))

        let mutationRunner = try Support.read("MutationExecution/MutationRunner.swift")
        #expect(mutationRunner.contains("private var projectRoot: URL { session.projectRoot! }"))
        #expect(mutationRunner.contains("private var toolchain: ToolchainFingerprint { session.toolchain! }"))
    }

    /// §1's actual load-bearing half: `MutationRunner`'s own `session`
    /// construction never passes `nil` for either field — it always passes
    /// its own real, non-Optional local `projectRoot`, and `toolchain ??
    /// plan.toolchain` (never `nil`, since a `MutationPlan`'s own
    /// `toolchain` is non-Optional). This is what makes the two
    /// force-unwraps above safe *today*; a change to either argument here
    /// (e.g. threading through a genuinely Optional value, or literally
    /// writing `nil`) is exactly the regression this test exists to catch
    /// before it reaches `MutationRunner.swift:101`'s `!`.
    @Test("MutationRunner's own RunSession construction never supplies nil for projectRoot/toolchain")
    func mutationRunnerSessionConstructionNeverPassesNil() throws {
        let text = try Support.read("MutationExecution/MutationRunner.swift")
        let call = try #require(
            Support.span(in: text, startMarker: "self.session = RunSession(", untilLineEquals: ")"),
            "MutationRunner.init no longer builds `self.session = RunSession(...)` the way this test expects"
        )
        #expect(call.contains("projectRoot: projectRoot"))
        #expect(call.contains("toolchain: toolchain ?? plan.toolchain"))
        #expect(!call.contains(": nil"), "MutationRunner's own session construction must never pass nil here: \(call)")
    }

    /// The other side of the same asymmetry: `SchemataMutationRunner`'s own
    /// `session` construction always passes `projectRoot: nil, toolchain:
    /// nil`, explicitly, every time — it has no real value of either type to
    /// give (see `RunSession`'s own doc comment for why). If a future edit
    /// ever supplied a real value here instead, nothing would break — but if
    /// this ever reverted to matching `MutationRunner`'s pattern by
    /// copy-paste (`projectRoot: projectRoot` referencing a value this
    /// runner does not have), it would fail to compile; this test instead
    /// guards the documented, intentional shape itself.
    @Test("SchemataMutationRunner's own RunSession construction always supplies nil for projectRoot/toolchain")
    func schemataMutationRunnerSessionConstructionAlwaysPassesNil() throws {
        let text = try Support.read("MutationExecution/SchemataMutationRunner.swift")
        let call = try #require(
            Support.span(in: text, startMarker: "self.session = RunSession(", untilLineEquals: ")"),
            "SchemataMutationRunner.init no longer builds `self.session = RunSession(...)` the way this test expects"
        )
        #expect(call.contains("projectRoot: nil"))
        #expect(call.contains("toolchain: nil"))
    }
}

/// §2: exactly one place derives `VerdictVerificationPolicy` from
/// `ExecutionSettings`'s three booleans — the `init(_:)` factory on
/// `VerdictVerificationPolicy` itself
/// (`MutationModel/MutationVerdictVerifier.swift:62-71`). Before this
/// factory existed, the identical derivation was written three times
/// independently; a future edit to only one of three re-independent copies
/// would silently make isolated mode, schemata mode, and
/// `CheckpointStore`/`MutationResultCache` construction disagree about which
/// confirmations a run promises. This is a structural fact ("exactly one
/// factory, exactly four total constructions of the type it produces"), not
/// a runtime behavior — a fifth, independent construction elsewhere would
/// not change any single test's observed output today, only the number of
/// places a future edit would have to remember to touch.
@Suite("Regression: VerdictVerificationPolicy has exactly one canonical construction site")
struct VerdictVerificationPolicyCanonicalFactoryRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    /// Every `.swift` file under `Sources/` (mirrors
    /// `ProcessSupervisorBypassRegressionTests.productionSwiftFiles()`,
    /// without the allow-list machinery that test needs and this one does
    /// not — every target is in scope here).
    private static func productionSwiftFiles() throws -> [(url: URL, relativePath: String)] {
        let fileManager = FileManager.default
        let root = Support.sourcesRoot
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [(url: URL, relativePath: String)] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
            files.append((fileURL, relativePath))
        }
        return files
    }

    /// The full, current set of places `Sources/` constructs a
    /// `VerdictVerificationPolicy(...)` — three real call sites deriving one
    /// from a run's `ExecutionSettings`, plus the type's own `.permissive`
    /// static default. Anything beyond these four is a new, independent
    /// derivation this test does not yet know about.
    private static let knownConstructionSites: Set<String> = [
        "MutationExecution/MutationRunner.swift",
        "MutationExecution/HybridExecutionEngine.swift",
        "CLI/Commands/RunCommand+ExecutionContext.swift",
        "MutationModel/MutationVerdictVerifier.swift"
    ]

    @Test("Sources/ constructs VerdictVerificationPolicy in exactly the four known places")
    func exactlyFourConstructionSites() throws {
        var sitesFound: Set<String> = []
        var totalOccurrences = 0
        for file in try Self.productionSwiftFiles() {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            let count = Support.occurrenceCount(of: "VerdictVerificationPolicy(", in: text)
            guard count > 0 else { continue }
            totalOccurrences += count
            sitesFound.insert(file.relativePath)
        }
        #expect(
            sitesFound == Self.knownConstructionSites,
            """
            VerdictVerificationPolicy(...) construction sites changed.
            Expected exactly: \(Self.knownConstructionSites.sorted())
            Found:            \(sitesFound.sorted())
            A new file constructing this type independently reintroduces the exact duplication the
            canonical init(_ execution: ExecutionSettings) factory (MutationVerdictVerifier.swift) exists
            to remove — route through that factory instead of deriving the three booleans again.
            """
        )
        #expect(
            totalOccurrences == 4,
            "expected exactly 4 total VerdictVerificationPolicy(...) constructions (3 call sites + .permissive), found \(totalOccurrences)"
        )
    }

    /// The three real call sites all route through the one canonical
    /// factory (`VerdictVerificationPolicy(<execution settings>)`) rather
    /// than the six-argument member-wise initializer — confirms it is
    /// actually *used* at each site, not merely that the file happens to
    /// mention the type name for some unrelated reason.
    @Test("Every real call site derives the policy via the ExecutionSettings-taking factory, not by hand")
    func realCallSitesUseTheFactory() throws {
        let runner = try Support.read("MutationExecution/MutationRunner.swift")
        #expect(runner.contains("VerdictVerificationPolicy(configuration.execution)"))

        let hybrid = try Support.read("MutationExecution/HybridExecutionEngine.swift")
        #expect(hybrid.contains("VerdictVerificationPolicy(context.configuration.execution)"))

        let runCommand = try Support.read("CLI/Commands/RunCommand+ExecutionContext.swift")
        #expect(runCommand.contains("VerdictVerificationPolicy(settings.execution)"))
    }
}

/// §3's schemata-side gap: `SchemataMutationRunner.confirmSchemataToken`
/// never rebuilds to confirm — it re-runs the exact same, already-built
/// `artifact` (ADR-0006 Stage 3), unlike isolated mode's own
/// `MutationConfirmationCoordinator.confirmCrashKill`/`.confirmTimeout`,
/// which always create a fresh sandbox and rebuild before retesting (that
/// isolated-mode half already has direct test coverage today —
/// `MutationRunnerCrashConfirmationTests`/`MutationRunnerTimeoutConfirmationTests`
/// — only the schemata half was uncovered). If a future change made
/// `confirmSchemataToken` start rebuilding, or start creating a fresh
/// sandbox, it would not be *wrong*, but it would silently multiply
/// schemata confirmation cost and diverge from the documented ADR-0006/0008
/// proof model without any caller asking for that.
@Suite("Regression: schemata confirmation never rebuilds, isolated confirmation always does")
struct SchemataConfirmationNeverRebuildsRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    @Test("confirmSchemataToken's body never creates a sandbox or rebuilds — it reruns the given artifact")
    func confirmSchemataTokenNeverRebuilds() throws {
        let text = try Support.read("MutationExecution/SchemataMutationRunner.swift")
        let body = try #require(
            Support.span(
                in: text, startMarker: "func confirmSchemataToken(",
                endLinePrefix: "    static func infrastructureFailureRun(_ diagnosis: String) -> TestRunResult {"
            ),
            "confirmSchemataToken(...) not found, or its own next sibling declaration moved, in SchemataMutationRunner.swift"
        )
        #expect(!body.contains("buildMutant("), "schemata confirmation must never rebuild: \(body)")
        #expect(!body.contains("createSandbox("), "schemata confirmation must never create a fresh sandbox: \(body)")
        #expect(
            body.contains("runSchemataToken(") && body.contains("artifact, in: sandbox"),
            "expected confirmSchemataToken to rerun the same already-built artifact in the given sandbox"
        )
    }

    /// The isolated-mode contrast this test's own doc comment relies on:
    /// both confirmation methods really do create a fresh sandbox and
    /// rebuild, so "schemata never rebuilds" reads as a genuine asymmetry,
    /// not a project-wide absence of any rebuild-on-confirm behavior at all.
    @Test("Isolated confirmation (crash and timeout) both create a fresh sandbox and rebuild")
    func isolatedConfirmationAlwaysRebuilds() throws {
        let text = try Support.read("MutationExecution/MutationConfirmationCoordinator.swift")

        let crashBody = try #require(Support.span(in: text, startMarker: "func confirmCrashKill", endLinePrefix: "    func "))
        #expect(crashBody.contains("workspaces.createSandbox"))
        #expect(crashBody.contains("build.buildMutant"))

        let timeoutBody = try #require(Support.span(in: text, startMarker: "func confirmTimeout", endLinePrefix: "    func "))
        #expect(timeoutBody.contains("workspaces.createSandbox"))
        #expect(timeoutBody.contains("build.buildMutant"))
    }
}

/// §7: one `mutantkit run --strategy schemata` invocation can construct
/// *two* runner instances — a `SchemataMutationRunner` always, and a
/// `MutationRunner` conditionally, only for whatever mutations fell back
/// (`HybridExecutionEngine.runFallbackPortion`'s own `guard
/// !fallbackIDs.isEmpty else { return nil }`). Each still builds its own
/// internal `RunSession` independently (§1 above) — there is no `Backend`
/// protocol or single shared session both runners read from, a deliberate
/// choice Step 2's own plan declined to unify as "materially bigger,
/// riskier" than its mandate. A future refactor that introduced a `Backend`
/// abstraction, or unified the two runners' sessions, would have to
/// simultaneously resolve this and the two-`WorkspaceManager` split
/// (`SchemataWorkspaceAndBaselineRegressionTests`) — this test only pins
/// that today it has not.
@Suite("Regression: a hybrid run may construct two runner instances; their sessions stay unmerged")
struct HybridRunTwoRunnerInstancesRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    @Test("The fallback MutationRunner is constructed only conditionally, guarded on a non-empty fallback set")
    func fallbackRunnerConstructionIsConditional() throws {
        let text = try Support.read("MutationExecution/HybridExecutionEngine.swift")
        let body = try #require(
            Support.span(in: text, startMarker: "private static func runFallbackPortion(", endLinePrefix: "    private static func "),
            "runFallbackPortion(...) not found where this test expects it in HybridExecutionEngine.swift"
        )
        #expect(body.contains("guard !fallbackIDs.isEmpty else { return nil }"))
        #expect(body.contains("MutationRunner("), "expected the fallback portion to construct a real MutationRunner")
    }

    @Test("The schemata portion constructs a distinct SchemataMutationRunner, not the same runner type")
    func schemataPortionConstructsADistinctRunnerType() throws {
        let text = try Support.read("MutationExecution/HybridExecutionEngine.swift")
        let body = try #require(
            Support.span(in: text, startMarker: "private static func runSchemataPortion(", endLinePrefix: "    private static func "),
            "runSchemataPortion(...) not found where this test expects it in HybridExecutionEngine.swift"
        )
        #expect(body.contains("SchemataMutationRunner("))
    }

    /// No `Backend` protocol exists anywhere in `Sources/` that either
    /// runner conforms to — the two runners are unified only by
    /// `HybridExecutionEngine`'s own orchestration, never by a shared
    /// abstraction both implement. Scanning all of `Sources/` (not just
    /// `MutationExecution/`) so this would also catch such a protocol being
    /// introduced anywhere else the two runners could plausibly conform to
    /// it from.
    @Test("No Backend protocol exists anywhere in Sources/ for the two runners to share")
    func noBackendProtocolExists() throws {
        let fileManager = FileManager.default
        let root = Support.sourcesRoot
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            Issue.record("could not enumerate Sources/")
            return
        }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(
                !text.contains("protocol Backend"),
                """
                found a `protocol Backend` declaration at \(fileURL.path) — if this is now the shared abstraction the two \
                runners unify through, update this test (and HybridRunTwoRunnerInstancesRegressionTests's own doc comment) \
                deliberately rather than letting it appear silently
                """
            )
        }
    }
}
