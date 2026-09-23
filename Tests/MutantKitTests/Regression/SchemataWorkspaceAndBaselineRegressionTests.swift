import Foundation
import Testing

/// Turns three more of an internal structural-invariants audit's 14
/// uncovered findings into permanent, mechanical gates. See
/// `V2InvariantsAuditRegressionSupport`'s own doc comment for why a
/// real-source textual re-scan is the right method here: each fact below is
/// a structural property of `Sources/` (which of two `WorkspaceManager`
/// values one specific call passes, whether one specific field is ever
/// threaded through, whether one type has a stored `OperationalIssueLog`),
/// none of it reachable by a fast unit test that actually runs a schemata
/// build/test cycle.
@Suite("Regression: two WorkspaceManagers exist in a hybrid run, and establishSharedBaseline always uses the isolated/fallback one")
struct SchemataWorkspaceSeparationRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    /// §4: `RunCommand.execute`'s `.schemata` case constructs a **separate**
    /// `schemataWorkspaces` from the earlier `workspaces` (the
    /// isolated/fallback manager), explicitly "so the two passes' sandboxes
    /// never collide mid-run." If a future refactor ever collapsed these
    /// into one shared `WorkspaceManager` — the exact unification Step 1/
    /// Step 2's own plans explicitly declined to make — a schemata-chunk
    /// sandbox and an isolated-fallback sandbox for two different mutations
    /// could collide on the same sandbox ID mid-run, silently corrupting
    /// both mutants' evidence chains.
    @Test("RunCommand constructs exactly two independent WorkspaceManagers for a schemata run")
    func exactlyTwoIndependentWorkspaceManagers() throws {
        let text = try Support.read("CLI/Commands/RunCommand.swift")
        #expect(text.contains("let workspaces = try WorkspaceManager("))
        #expect(text.contains("let schemataWorkspaces = try WorkspaceManager("))
        #expect(
            Support.occurrenceCount(of: "try WorkspaceManager(", in: text) == 2,
            """
            expected exactly 2 WorkspaceManager constructions in RunCommand.swift (workspaces, schemataWorkspaces); \
            a third would mean either a new pass was added (update this test deliberately) or the two got merged
            """
        )
    }

    /// Both managers really do reach `HybridExecutionEngine.runHybrid` as
    /// two distinctly-named parameters — confirms the separation survives
    /// past construction into the one place both passes actually run,
    /// rather than one of the two locals going unused/shadowed.
    @Test("Both WorkspaceManagers are passed into runHybrid under their own distinct labels")
    func bothManagersReachRunHybridSeparately() throws {
        let text = try Support.read("CLI/Commands/RunCommand.swift")
        let call = try #require(
            Support.span(in: text, startMarker: "return try await HybridExecutionEngine.runHybrid(", untilLineEquals: ")"),
            "the runHybrid(...) call site moved or changed shape from what this test expects"
        )
        #expect(call.contains("workspaces: workspaces"))
        #expect(call.contains("schemataWorkspaces: schemataWorkspaces"))
    }

    /// §4's easy-to-miss half, per the audit's own framing: even though the
    /// schemata portion runs first, `establishSharedBaseline` is called
    /// with `workspaces:` — the isolated/fallback manager — **never**
    /// `schemataWorkspaces:`. If this argument were ever swapped, the shared
    /// baseline sandbox's own scratch-root location would silently move to
    /// a different directory tree, an observable `report.json`-adjacent
    /// behavior change nothing else currently catches.
    @Test("establishSharedBaseline is always called with the isolated/fallback workspaces, never schemataWorkspaces")
    func establishSharedBaselineUsesTheIsolatedWorkspaces() throws {
        let text = try Support.read("MutationExecution/HybridExecutionEngine.swift")
        let callLine = try #require(
            text.components(separatedBy: .newlines).first { $0.contains("await establishSharedBaseline(") },
            "the establishSharedBaseline(...) call site moved or changed shape from what this test expects"
        )
        #expect(callLine.contains("workspaces: workspaces"))
        #expect(!callLine.contains("schemataWorkspaces"), "establishSharedBaseline must never receive schemataWorkspaces: \(callLine)")
    }
}

/// §6: a schemata-scored mutant's `MutationEvidence.resultArtifact` is
/// always `nil` — `MutationEvidenceAssembler.preserve(_:for:in:label:)`, the
/// only path that ever populates it, is never called from
/// `SchemataMutationRunner.swift`, and neither of that file's two
/// `MutationEvidence(...)` constructions passes `resultArtifact:` at all
/// (it defaults to `nil`). A caller reading `report.json` and expecting to
/// inspect a schemata mutant's `.xcresult`/transcript bundle via this field
/// always gets `nil` today, by design — not by omission-that-happens-to-be-
/// empty. If a future change ever wired schemata into
/// `MutationEvidenceAssembler`, every schemata-scored mutant's evidence
/// would start carrying a `resultArtifact` path where none existed before —
/// a real, observable `report.json` shape change for that whole backend.
@Suite("Regression: a schemata MutationResult never carries a resultArtifact")
struct SchemataResultArtifactAlwaysNilRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    @Test("SchemataMutationRunner never passes resultArtifact: to MutationEvidence")
    func schemataNeverPassesResultArtifact() throws {
        let text = try Support.read("MutationExecution/SchemataMutationRunner.swift")
        #expect(
            !text.contains("resultArtifact:"),
            """
            SchemataMutationRunner.swift now passes resultArtifact: explicitly somewhere — if this is a deliberate, \
            reviewed decision to start populating it for schemata mode, update this test (and the audit doc) \
            deliberately; if not, this is the exact silent report.json shape change this test exists to catch
            """
        )
        #expect(
            Support.occurrenceCount(of: "MutationEvidence(", in: text) == 2,
            "expected exactly 2 MutationEvidence(...) constructions in SchemataMutationRunner.swift"
        )
    }

    /// `MutationEvidenceAssembler.preserve`, the only path that ever
    /// populates `resultArtifact`, is never referenced by
    /// `SchemataMutationRunner.swift` at all — confirms the previous test's
    /// finding isn't merely "no call site happens to spell the argument
    /// label," but that the whole preservation mechanism is unreachable
    /// from this file.
    @Test("SchemataMutationRunner never calls MutationEvidenceAssembler.preserve")
    func schemataNeverCallsPreserve() throws {
        let text = try Support.read("MutationExecution/SchemataMutationRunner.swift")
        #expect(!text.contains(".preserve("))
    }

    /// `resultArtifact`'s own default is `nil` on the initializer schemata's
    /// two omitting call sites actually rely on — confirms the previous
    /// tests' "omits the label" finding really does mean "gets nil," not
    /// some other default this test would otherwise be trusting blindly.
    @Test("MutationEvidence.resultArtifact defaults to nil when the label is omitted")
    func resultArtifactDefaultsToNil() throws {
        let text = try Support.read("MutationModel/MutationEvidence.swift")
        #expect(text.contains("resultArtifact: String? = nil,"))
        #expect(text.contains("public let resultArtifact: String?"))
    }
}

/// §8: three separate baseline implementations exist
/// (`MutationRunner.establishBaseline`, `SchemataMutationRunner
/// .establishBaseline`, `SharedBaselineEstablisher.establish`, the last one
/// "deliberately a parallel implementation, not a refactor of either
/// existing runner's internals"), with a deliberate split in how each
/// reports profiling issues: `MutationRunner`'s own path reports into
/// `self.operationalIssues` (an `OperationalIssueLog` it stores);
/// `SchemataMutationRunner`'s own non-shared path has no
/// `OperationalIssueLog` of its own at all and reports to **stderr only**.
/// A schemata run's own coverage-measurement failures never appear in
/// `RunReport.operationalIssues`/`report.json` today, by design. A future
/// collapse of these three implementations into fewer copies must preserve
/// this exact split, or a schemata run's failures would start silently
/// appearing in `report.json` where they never did — or the reverse,
/// `MutationRunner` silently losing its own reporting.
@Suite("Regression: schemata's own baseline path has no OperationalIssueLog; isolated's does")
struct SchemataBaselineStderrOnlySplitRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    @Test("SchemataMutationRunner has no OperationalIssueLog of its own, and says so at its stderr-only report site")
    func schemataHasNoOperationalIssueLog() throws {
        let text = try Support.read("MutationExecution/SchemataMutationRunner.swift")
        #expect(
            !text.contains("OperationalIssueLog()"),
            """
            SchemataMutationRunner.swift now constructs an OperationalIssueLog — if this runner has genuinely gained \
            one, update the doc comment at its coverage-measurement report site (and this test) deliberately
            """
        )
        #expect(
            text.contains(#"this runner has no `OperationalIssueLog`"#),
            """
            the doc comment explaining the stderr-only report is gone or reworded — this test pins the invariant it \
            documents, not the exact prose, so update the marker string here if the comment is deliberately reworded
            """
        )
    }

    /// The isolated-mode contrast: `MutationRunner` really does hold and
    /// report into an `OperationalIssueLog`, so "schemata has none" reads as
    /// a genuine backend asymmetry rather than a project-wide absence.
    @Test("MutationRunner stores exactly one OperationalIssueLog and reports into it")
    func mutationRunnerHasOperationalIssueLog() throws {
        let text = try Support.read("MutationExecution/MutationRunner.swift")
        #expect(text.contains("private let operationalIssues = OperationalIssueLog()"))
        #expect(
            Support.occurrenceCount(of: "OperationalIssueLog()", in: text) == 1,
            "expected exactly one OperationalIssueLog() construction in MutationRunner.swift"
        )
    }

    /// `SharedBaselineEstablisher` — the third, genuinely parallel
    /// implementation both runners' own `preEstablishedBaseline` can bypass
    /// — takes its own `operationalIssues` as an *Optional* parameter,
    /// confirming not every caller has one to hand it (consistent with
    /// `SchemataMutationRunner` having none).
    @Test("SharedBaselineEstablisher.establish takes operationalIssues as an Optional parameter")
    func sharedBaselineEstablisherOperationalIssuesIsOptional() throws {
        let text = try Support.read("MutationExecution/SharedBaselineEstablisher.swift")
        #expect(text.contains("operationalIssues: OperationalIssueLog? = nil"))
    }
}
