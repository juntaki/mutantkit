import Foundation
import Testing

/// Turns two more of an internal structural-invariants audit's 14
/// uncovered findings into permanent, mechanical gates. See
/// `V2InvariantsAuditRegressionSupport`'s own doc comment for why a
/// real-source textual re-scan is the right method: both facts below are
/// about *which spelling* one specific guard uses, and *what order* three
/// specific statements execute in inside one CLI function — neither
/// reachable by a fast unit test that does not itself require a real
/// schemata-capable Xcode toolchain and a deliberately slow `classify(_:)`
/// to observe timing against.
@Suite(
    "Regression: the schemata M/N capability guard's test-half stays a dynamic cast, never the construction-time property"
)
struct SchemataCapabilityGuardStaysDynamicRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    /// §9: `RunCommand.execute`'s `.schemata` capability guard reads
    /// `context.adapter.schemataBuild` (construction-time, static) for the
    /// build half, but `context.testAdapter is SchemataTestable` — a
    /// genuine, dynamic runtime cast, **not** `context.adapter.schemataTest`
    /// — for the test half. `context.testAdapter` is a *separate*,
    /// per-run field from `context.adapter.test`: it may be
    /// `PrioritizingTestAdapter`-wrapped by `RunCommand.resolveTestAdapter`,
    /// a fact only knowable after CLI-layer wrapping decisions, not at
    /// `ProjectAdapter` construction time. If this check were ever migrated
    /// to the construction-time property, a `--strategy schemata` run with
    /// test-selection/early-abort both on (which wraps the test adapter)
    /// would silently pass a capability guard it should fail, routing a
    /// non-schemata-capable wrapped adapter into schemata execution instead
    /// of failing closed.
    @Test("RunCommand's schemata guard uses a dynamic `is SchemataTestable` check, not the construction-time property")
    func runCommandGuardStaysDynamic() throws {
        let text = try Support.read("CLI/Commands/RunCommand.swift")
        #expect(text.contains("guard context.adapter.schemataBuild != nil, context.testAdapter is SchemataTestable else {"))
        #expect(
            !text.contains("context.adapter.schemataTest"),
            """
            RunCommand.swift now reads context.adapter.schemataTest somewhere — if the capability guard itself was \
            migrated to it, this is exactly the false-negative-guard regression this test exists to catch: \
            context.testAdapter can be PrioritizingTestAdapter-wrapped and is never reflected in that property
            """
        )
    }

    /// The same split, preserved a second time at the engine layer per the
    /// audit's own citation — `HybridExecutionEngine.runHybrid`'s own doc
    /// comment calls this "the second check of the same fact... kept here
    /// too... so this function stays correct on its own."
    @Test("HybridExecutionEngine's own guard also uses a dynamic `as? SchemataTestable` cast, not the property")
    func hybridExecutionEngineGuardStaysDynamic() throws {
        let text = try Support.read("MutationExecution/HybridExecutionEngine.swift")
        let body = try #require(
            Support.span(in: text, startMarker: "public static func runHybrid(", endLinePrefix: "    public static func "),
            "runHybrid(...) not found where this test expects it in HybridExecutionEngine.swift"
        )
        #expect(body.contains("let schemataTest = context.testAdapter as? SchemataTestable"))
        #expect(
            !body.contains("context.adapter.schemataTest"),
            """
            runHybrid's own capability guard now reads context.adapter.schemataTest — see this suite's sibling test \
            for why that silently defeats PrioritizingTestAdapter-wrapped detection
            """
        )
    }

    /// The concrete counterexample the audit's own reasoning depends on:
    /// `PrioritizingTestAdapter` — the wrapper `RunCommand.resolveTestAdapter`
    /// can produce — conforms to `TestSelecting`, never `SchemataTestable`.
    /// If the guard above were migrated to the construction-time property,
    /// this is the exact type whose wrapped presence the migrated guard
    /// would silently stop detecting (a wrapped, non-schemata-capable
    /// adapter would need to fail the guard; the construction-time property
    /// only reflects the *unwrapped* adapter it was built from).
    @Test("PrioritizingTestAdapter never conforms to SchemataTestable")
    func prioritizingTestAdapterNeverConformsToSchemataTestable() throws {
        let text = try Support.read("MutationExecution/PrioritizingTestAdapter.swift")
        let declarationLine = try #require(
            text.components(separatedBy: .newlines).first { $0.contains("struct PrioritizingTestAdapter") },
            "PrioritizingTestAdapter's own struct declaration moved or was renamed"
        )
        #expect(declarationLine.contains("TestSelecting, TestAdapterWrapping, Sendable"))
        #expect(!declarationLine.contains("SchemataTestable"))
        #expect(
            !text.contains("extension PrioritizingTestAdapter"),
            """
            a new extension on PrioritizingTestAdapter exists — if it adds SchemataTestable conformance, the guard \
            above's own reasoning (this type is the concrete non-conforming counterexample) is now false
            """
        )
    }
}

/// §10: in `RunCommand.execute`'s `.schemata` case, the order is: (1) the
/// capability guard; (2) `let startedAt = Date()`; (3)
/// `SchemataRunOrchestration.classify(context)`. This exact order is
/// preserved from before Step 2, per that step's own doc comments — moving
/// `startedAt`'s capture to after `classify(_:)` would silently start
/// excluding classification's own (potentially slow: target resolution,
/// source reads, chunk planning) wall-clock time from a schemata run's
/// reported `RunReport.startedAt`, and everything `PerformanceSummary`/
/// `RunHistory` derive from it.
///
/// Deliberately checked by relative substring position, not fixed line
/// numbers: the invariant is the *order* these three statements execute in
/// within the same function body, which survives an unrelated line being
/// inserted or removed elsewhere in `RunCommand.swift` — exactly the kind
/// of accidental false failure a hardcoded `:424`/`:432`/`:457` assertion
/// would otherwise produce for a change that never touched this ordering at
/// all.
@Suite("Regression: startedAt is captured before classify(_:); the capability guard runs before both")
struct SchemataStartedAtOrderingRegressionTests {
    typealias Support = V2InvariantsAuditRegressionSupport

    @Test("guard, then startedAt = Date(), then classify(context), strictly in that order")
    func guardThenStartedAtThenClassify() throws {
        let text = try Support.read("CLI/Commands/RunCommand.swift")

        let guardMarker = "guard context.adapter.schemataBuild != nil, context.testAdapter is SchemataTestable else {"
        let startedAtMarker = "let startedAt = Date()"
        let classifyMarker = "SchemataRunOrchestration.classify(context)"

        let guardRange = try #require(text.range(of: guardMarker), "capability guard not found")
        let startedAtRange = try #require(
            text.range(of: startedAtMarker, range: guardRange.upperBound ..< text.endIndex),
            "`let startedAt = Date()` not found after the capability guard — either it moved before the guard, or was removed"
        )
        let classifyRange = try #require(
            text.range(of: classifyMarker, range: startedAtRange.upperBound ..< text.endIndex),
            "classify(context) not found after `let startedAt = Date()` — either it moved before startedAt's capture, or was removed"
        )

        // The three ranges being found in strictly increasing order (each
        // search starting after the previous match's end) IS the ordering
        // assertion — nothing further to compare. These #expects exist so a
        // failure reads as "ordering broken" rather than only surfacing via
        // the #require messages above, and to guard against a second,
        // earlier, coincidental match of a later marker confusing the story.
        #expect(guardRange.upperBound <= startedAtRange.lowerBound)
        #expect(startedAtRange.upperBound <= classifyRange.lowerBound)
    }

    /// The guard, `startedAt`, and `classify(_:)` call must all live inside
    /// the *same* `.schemata` case body — otherwise the ordering test above
    /// could pass by accident (e.g. an unrelated `let startedAt = Date()` in
    /// a completely different function, later in the file, would still
    /// satisfy a pure substring-position check). Confirms all three appear
    /// within one continuous span that starts at the guard and has no
    /// intervening `case .` (a new `switch` case boundary) before
    /// `classify(_:)` is reached.
    @Test("The guard, startedAt, and classify(_:) are not separated by an intervening switch case boundary")
    func allThreeShareOneCaseBody() throws {
        let text = try Support.read("CLI/Commands/RunCommand.swift")
        let lines = text.components(separatedBy: .newlines)

        let guardIndex = try #require(
            lines.firstIndex { $0.contains("guard context.adapter.schemataBuild != nil, context.testAdapter is SchemataTestable else {") }
        )
        let classifyIndex = try #require(
            lines.firstIndex { $0.contains("SchemataRunOrchestration.classify(context)") }
        )
        #expect(guardIndex < classifyIndex)

        let between = lines[(guardIndex + 1) ..< classifyIndex]
        let interveningCaseBoundaries = between.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("case .") || trimmed.hasPrefix("case let")
        }
        #expect(
            interveningCaseBoundaries.isEmpty,
            """
            found a switch-case boundary between the capability guard and classify(_:) — they are no longer \
            in the same case body: \(interveningCaseBoundaries)
            """
        )
    }
}
