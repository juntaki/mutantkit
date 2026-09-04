import Foundation
import MutationModel

/// For one surviving/uncovered mutant, the specific, concrete distinction a
/// new test would need to make in order to kill it — derived mechanically
/// from the mutation's own real operator semantics, never a generic
/// "add more tests" suggestion.
///
/// Every case below is grounded in the *actual* implementation of one of
/// this codebase's real default-profile (`OperatorDescriptor.defaultEnabled
/// == true`) operators in `Sources/SwiftCoreOperators/` — as of this type's
/// writing, exactly six: `RelationalOperatorReplacementOperator` (two
/// distinct obligations, boundary and negation — it emits two candidate
/// mutations per comparison, see its own doc comment),
/// `LogicalConnectorReplacementOperator`, `TernaryBranchSwapOperator`,
/// `UnaryNotRemovalOperator`, `BoolLiteralInversionOperator`, and
/// `ReturnValueReplacementOperator`. `.reachability` is not operator-derived
/// at all — it is `SurvivorActionabilityReport.Reason.mutationSiteNotCovered`
/// itself, restated as an obligation, since "reach the site" is the entire
/// content of what a `.noCoverage` outcome proves.
///
/// `.unmodeledOperator` is the honest fallback for any operator ID this
/// analyzer has not had its real source read against — a non-default
/// operator that reached this report via `--profile experimental`/
/// `conservative`-with-a-manual-`enable`, or a future operator this file
/// predates. It deliberately says less, rather than guess at semantics
/// nobody has verified here — the same trust discipline
/// `SurvivorActionabilityReport`'s own doc comment already applies to
/// `.noCoverage`/`.survived`.
public struct TestObligation: Codable, Sendable, Equatable {
    /// What *kind* of gap this is — stable, machine-matchable, one case per
    /// mechanically-distinct obligation shape.
    public enum Kind: String, Codable, Sendable {
        /// `SurvivorActionabilityReport.Reason.mutationSiteNotCovered`: no
        /// test executed this line at all.
        case reachability
        /// `RelationalOperatorReplacementOperator`'s boundary form
        /// (`<`⇄`<=`, `>`⇄`>=`): the mutant and the original disagree only
        /// on inputs exactly at the shared boundary.
        case relationalBoundary
        /// `RelationalOperatorReplacementOperator`'s negation form (`<`⇄`>=`,
        /// `<=`⇄`>`, `==`⇄`!=`): the mutant is the exact logical complement
        /// of the original.
        case relationalNegation
        /// `LogicalConnectorReplacementOperator` (`&&`⇄`||`): the mutant
        /// disagrees with the original only on the two mixed-truth operand
        /// combinations.
        case logicalConnectorCombination
        /// `TernaryBranchSwapOperator`: the true/false result expressions
        /// were exchanged.
        case ternaryBranchObservation
        /// `UnaryNotRemovalOperator`: a `!` was removed, so the mutant is
        /// the original condition's exact complement.
        case unaryNotPolarity
        /// `BoolLiteralInversionOperator`: a `true`/`false` literal default
        /// was flipped.
        case boolLiteralValue
        /// `ReturnValueReplacementOperator`: the returned value was replaced
        /// with a syntactically-neutral default (`nil`/`0`/`""`/`[]`/`[:]`).
        case returnValueAssertion
        /// An operator ID this analyzer has no real, source-read semantics
        /// for — see this type's own doc comment.
        case unmodeledOperator
    }

    /// How directly the obligation above is *derivable* from the operator's
    /// own mechanical semantics — not a general sense of "how important" or
    /// "how easy to fix." Deliberately a separate scale from
    /// `MutationConfidence` (`OperatorDescriptor.confidence`), which grades
    /// an operator's overall compile/runtime viability across a whole
    /// corpus; this grades one specific claim about one surviving mutant.
    public enum Confidence: String, Codable, Sendable, Comparable {
        /// The (original, replacement) pair is a closed-form lookup in the
        /// operator's own fixed table (a boundary/negation pair, a
        /// connector swap, a literal flip, a branch swap, a negation
        /// removal) with exactly one well-defined semantic delta, provable
        /// without looking at anything outside the two token strings
        /// themselves.
        case high
        /// The obligation is precise about *what* changed, but resolving it
        /// requires a fact one hop away from the mutation site itself, not
        /// visible from what this analyzer actually has (the recorded
        /// `original`/`replacement` text): for `.returnValueAssertion`,
        /// whether some caller elsewhere asserts on the return value — a
        /// fact about the call site, not this declaration; for
        /// `.ternaryBranchObservation`'s ordinary (branches-differ-in-text)
        /// case, whether the two branch expressions actually evaluate to
        /// different values — a fact about those two expressions'
        /// semantics, not the swap itself; for `.relationalNegation` on an
        /// ordering comparison (`<`/`<=`/`>`/`>=`, not `==`/`!=`), whether
        /// the compared type can take a value (`NaN`, for Swift's
        /// floating-point types) for which ordering comparisons are not
        /// exact complements — a fact about the operand's static type, not
        /// the two bare operator tokens.
        case medium
        /// `.unmodeledOperator` only: no operator-specific derivation was
        /// attempted at all.
        case low

        private var rank: Int {
            switch self {
            case .high: 2
            case .medium: 1
            case .low: 0
            }
        }

        public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
    }

    public let kind: Kind
    public let confidence: Confidence
    /// Why this `kind`/`confidence` follows from the operator's own real
    /// semantics — grounded, citable, never "seems likely."
    public let rationale: String
    /// The concrete, mechanically-derived obligation itself, built from this
    /// mutant's own real `originalText`/`replacementText` — never a
    /// template that only names the operator.
    public let description: String

    public init(kind: Kind, confidence: Confidence, rationale: String, description: String) {
        self.kind = kind
        self.confidence = confidence
        self.rationale = rationale
        self.description = description
    }
}

/// Derives a `TestObligation` for one surviving/uncovered mutant, and builds
/// the full, report-wide fix plan `mutantkit fix-plan` prints.
///
/// Pure and deterministic, matching every other type in this module: no I/O,
/// nothing reused from the plan/discovery pass (which is long gone by the
/// time a `report.json` is read back) — every derivation reads only
/// `operatorID`/`originalText`/`replacementText`, the same fields already on
/// `SurvivorActionabilityReport.Member`, plus the `Reason` that member's
/// cluster was built with.
///
/// Deliberately does not import `SwiftCoreOperators` or call into a real
/// `MutationOperator`: those types answer "what could be mutated here" from
/// a live syntax tree, a question this analyzer never asks. What it needs —
/// each operator's fixed replacement vocabulary and what surviving actually
/// proves about it — is read once, by a human, from that module's real
/// source (see each `switch` case below for exactly which file and which
/// claim), and encoded here as a lookup over the two strings a finished
/// report already carries.
public enum TestObligationAnalyzer {
    // MARK: - Fix plan (report-wide)

    /// One entry per surviving/uncovered mutant, in the exact deterministic
    /// order `SurvivorActionabilityReport.build(from:)` already establishes
    /// (declaration, then severity band, then cluster size, then mutant ID)
    /// — reused, not re-derived, so a fix plan and `mutantkit survivors`
    /// never silently disagree about ordering or which mutants are in
    /// scope.
    public static func buildFixPlan(from report: RunReport) -> [MutantFixPlanEntry] {
        let actionability = SurvivorActionabilityReport.build(from: report)
        // Keyed by the mutant's own ID string — the same value
        // `Member.mutantID` already carries (`result.point.id.rawValue`),
        // so no `MutationID` round-trip is needed to look a member's own
        // full `MutationResult` back up.
        //
        // Deliberately `uniquingKeysWith`, not `uniqueKeysWithValues`: this
        // reads a `report` that this analyzer did not itself produce in this
        // run — a hand-edited or otherwise malformed `report.json` can
        // repeat a mutant ID across two `MutationResult`s, and
        // `RunReport.init(from:)` decodes `results` as a plain array with no
        // uniqueness re-check (only `RunReport`'s own `ResultLedger`-backed
        // initializer enforces that, and that path is long gone by the time
        // a report is read back from disk). `uniqueKeysWithValues` would
        // trap the entire `fix-plan`/`next` command on that input; a command
        // a user runs directly by hand must fail with a readable error, or
        // degrade, never crash.
        // Policy on a collision: keep the first `MutationResult` in
        // `report.results`'s own order and discard the later duplicate(s) —
        // deterministic, and no worse a guess than any other tie-break for
        // an ID that should never have repeated in the first place.
        let resultsByMutantID = Dictionary(
            report.results.map { ($0.point.id.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return actionability.groups.flatMap { group in
            group.clusters.flatMap { cluster -> [MutantFixPlanEntry] in
                let clusterMutantIDs = cluster.mutantIDs
                return cluster.members.compactMap { member -> MutantFixPlanEntry? in
                    // Every member here was itself built from `report.results`
                    // by `SurvivorActionabilityReport.build` a few lines
                    // above, so this can never actually miss — guarded
                    // rather than force-unwrapped so a future refactor that
                    // breaks that invariant drops one entry from a report
                    // instead of crashing whatever is reading it.
                    guard let result = resultsByMutantID[member.mutantID] else { return nil }
                    return makeEntry(group: group, cluster: cluster, member: member, result: result, clusterMutantIDs: clusterMutantIDs)
                }
            }
        }
    }

    private static func makeEntry(
        group: SurvivorActionabilityReport.DeclarationGroup,
        cluster: SurvivorActionabilityReport.IssueCluster,
        member: SurvivorActionabilityReport.Member,
        result: MutationResult,
        clusterMutantIDs: [String]
    ) -> MutantFixPlanEntry {
        let testScope: SurvivorActionabilityReport.TestScope? = if case let .coveredButNotCaught(scope) = cluster.reason {
            scope
        } else {
            nil
        }
        let knownCoveringTests: [String]? = if case let .narrowed(tests) = testScope { tests } else { nil }

        let facts = MutantFixPlanEntry.Facts(
            mutantID: member.mutantID,
            operatorID: member.operatorID,
            file: member.file,
            line: member.line,
            column: member.column,
            declaration: group.declaration,
            original: member.original,
            replacement: member.replacement,
            outcome: result.outcome,
            diagnosis: member.diagnosis,
            testsRun: result.testSummary?.total,
            testsPassed: result.testSummary?.passed,
            testsFailed: result.testSummary?.failed,
            knownCoveringTests: knownCoveringTests,
            testScope: testScope,
            clusterSize: cluster.members.count,
            clusterMutantIDs: clusterMutantIDs
        )
        let derived = obligation(
            reason: cluster.reason, operatorID: member.operatorID, originalText: member.original, replacementText: member.replacement
        )
        return MutantFixPlanEntry(
            facts: facts,
            inference: MutantFixPlanEntry.Inference(kind: derived.kind, confidence: derived.confidence, rationale: derived.rationale),
            obligation: MutantFixPlanEntry.Obligation(description: derived.description),
            reproduceCommand: member.reproduceCommand
        )
    }

    // MARK: - Per-mutant obligation

    /// The single entry point every derivation below funnels through.
    /// `.mutationSiteNotCovered` always wins regardless of operator: an
    /// operator-specific claim about assertion strength presupposes the
    /// site was reached at all, which `.noCoverage` proves it was not.
    public static func obligation(
        reason: SurvivorActionabilityReport.Reason,
        operatorID: String,
        originalText: String,
        replacementText: String
    ) -> TestObligation {
        guard case .coveredButNotCaught = reason else {
            return reachabilityObligation(original: originalText, replacement: replacementText)
        }

        return switch operatorID {
        case "swift.core.relational-operator-replacement":
            relationalObligation(original: originalText, replacement: replacementText)
        case "swift.core.logical-connector-replacement":
            logicalConnectorObligation(original: originalText, replacement: replacementText)
        case "swift.core.ternary-branch-swap":
            ternaryObligation(original: originalText, replacement: replacementText)
        case "swift.core.unary-not-removal":
            unaryNotObligation(original: originalText, replacement: replacementText)
        case "swift.core.bool-literal-inversion":
            boolLiteralObligation(original: originalText, replacement: replacementText)
        case "swift.core.return-value-replacement":
            returnValueObligation(original: originalText, replacement: replacementText)
        default:
            unmodeledObligation(operatorID: operatorID, original: originalText, replacement: replacementText)
        }
    }

    /// `SurvivorActionabilityReport.Reason.mutationSiteNotCovered` /
    /// `MutationOutcome.noCoverage`: "tests ran and passed, but nothing
    /// executed the mutated line" (that outcome's own doc comment). Not
    /// operator-derived — every operator's mutant is equally unreachable
    /// here, so the obligation is the same shape regardless of which
    /// operator produced it.
    private static func reachabilityObligation(original: String, replacement: String) -> TestObligation {
        TestObligation(
            kind: .reachability,
            confidence: .high,
            rationale: """
            MutationOutcome.noCoverage means tests ran and passed but nothing executed this exact mutated line — \
            reachability, not assertion strength, is the proven gap, so there is nothing to guess at.
            """,
            description: """
            Not reached: no test in the deciding run executed this line at all. Add or extend a test that reaches \
            this exact site — an assertion distinguishing `\(original)` from `\(replacement)` cannot matter until \
            execution gets here first.
            """
        )
    }

    /// `RelationalOperatorReplacementOperator` (`Sources/SwiftCoreOperators/
    /// RelationalOperatorReplacementOperator.swift`). Its own fixed
    /// `replacements` table pairs each of `<`/`<=`/`>`/`>=`/`==`/`!=` with a
    /// boundary form (only for the four ordering operators) and a negation
    /// form (all six) — mirrored here only to classify an already-reported
    /// (original, replacement) pair back into which of the two it was, not
    /// to re-run discovery.
    private static func relationalObligation(original: String, replacement: String) -> TestObligation {
        let boundaryPairs: Set<[String]> = [["<", "<="], ["<=", "<"], [">", ">="], [">=", ">"]]
        let negationPairs: Set<[String]> = [
            ["<", ">="], ["<=", ">"], [">", "<="], [">=", "<"], ["==", "!="], ["!=", "=="]
        ]
        let pair = [original, replacement]

        if boundaryPairs.contains(pair) {
            // Widened when the original had no `=` (`<`/`>`): the mutant now
            // additionally accepts the equal case. Narrowed the other way.
            let widened = original == "<" || original == ">"
            return TestObligation(
                kind: .relationalBoundary,
                confidence: .high,
                rationale: """
                RelationalOperatorReplacementOperator's boundary form is a fixed, order-theoretic table lookup \
                (`<`⇄`<=`, `>`⇄`>=`) with exactly one semantic delta — the shared boundary value — independent \
                of what is actually being compared.
                """,
                description: """
                Boundary \(widened ? "widened" : "narrowed"): `\(original)` → `\(replacement)`. The two agree \
                everywhere except when the compared operands are exactly equal — \(widened
                    ? "`\(replacement)` now includes that case, `\(original)` excluded it"
                    : "`\(replacement)` now excludes that case, `\(original)` included it"). A test whose input \
                lands exactly on that boundary (not merely nearby) is the one thing that can tell them apart.
                """
            )
        }

        if negationPairs.contains(pair) {
            // `==`⇄`!=` is unconditionally exact: `!=` is defined as the
            // Boolean negation of `==` for every `Equatable` conformance in
            // Swift, with no type-dependent exception (see below). The four
            // ordering pairs are not: they are exact complements only for a
            // genuine total order.
            if original == "==" || original == "!=" {
                return TestObligation(
                    kind: .relationalNegation,
                    confidence: .high,
                    rationale: """
                    RelationalOperatorReplacementOperator's negation form pairs `==` with `!=` — `!=` is defined, \
                    unconditionally, as the Boolean negation of `==` for every `Equatable` conformance in Swift \
                    (floating-point included: `Double.nan == .nan` is `false`, so `.nan != .nan` is `true`, \
                    still an exact complement). There is no type for which the two can ever agree — a fixed \
                    logical fact provable from the two tokens alone, independent of the operands.
                    """,
                    description: """
                    Negated: `\(original)` reversed to `\(replacement)`. `==` and `!=` are exact complements for \
                    every value of every type, so this can only survive when no assertion in the deciding \
                    test(s) actually depends on this comparison's result — the input reaches the line, but \
                    nothing checks which way the comparison went.
                    """
                )
            }
            // An ordering pair (`<`⇄`>=`, `<=`⇄`>`). Exact complements for
            // any genuine total order — the overwhelming majority of real
            // `Comparable` usage (`Int`, `String`, ...) — but Swift's
            // floating-point types deliberately deviate from `Comparable`'s
            // implied total order for `NaN` (IEEE 754): `x < 10` and
            // `x >= 10` are *both* `false` when `x` is `.nan`, so the pair
            // agrees, rather than disagrees, at that one value. Whether that
            // possibility applies depends on the compared operand's static
            // type, which is not visible from the two bare operator tokens
            // this analyzer actually has — so this ranks medium, not high,
            // unlike the boundary form above (whose "agree everywhere except
            // the boundary value" claim holds even for `NaN`, since `NaN` is
            // never the boundary value either).
            return TestObligation(
                kind: .relationalNegation,
                confidence: .medium,
                rationale: """
                RelationalOperatorReplacementOperator's negation form pairs each ordering comparison with its \
                complement (`<`⇄`>=`, `<=`⇄`>`) — an exact logical complement for any genuine total order, \
                which is true of the overwhelming majority of `Comparable` usage, but not unconditionally: \
                Swift's floating-point types return `false` from *every* ordering comparison against `NaN`, \
                including both halves of this pair, so they agree instead of disagreeing there. Whether the \
                compared operand's static type admits that case is a fact this analyzer cannot see from the two \
                operator tokens alone — one hop from the mutation site, not a closed-form fact about the tokens \
                themselves.
                """,
                description: """
                Negated: `\(original)` reversed to `\(replacement)`. For an ordinary total-ordered comparison \
                (`Int`, `String`, most `Comparable` types), these are exact complements, so this can only \
                survive when no assertion in the deciding test(s) actually depends on this comparison's result \
                — the input reaches the line, but nothing checks which way the comparison went. If the compared \
                value is a floating-point type (`Double`/`Float`/`CGFloat`), also check whether the deciding \
                test(s) ever exercised this comparison with `.nan`: both `\(original)` and `\(replacement)` \
                evaluate to `false` there, so a test relying only on a `.nan` input cannot distinguish them no \
                matter what it asserts.
                """
            )
        }

        return unmodeledObligation(
            operatorID: "swift.core.relational-operator-replacement", original: original, replacement: replacement
        )
    }

    /// `LogicalConnectorReplacementOperator` (`Sources/SwiftCoreOperators/
    /// LogicalConnectorReplacementOperator.swift`): swaps `&&`⇄`||`,
    /// unconditionally — its own `replacements` table has exactly these two
    /// entries.
    private static func logicalConnectorObligation(original: String, replacement: String) -> TestObligation {
        TestObligation(
            kind: .logicalConnectorCombination,
            confidence: .high,
            rationale: """
            LogicalConnectorReplacementOperator swaps `&&`⇄`||`, which disagree only on the two mixed-truth \
            operand combinations — a fixed logical fact independent of what either operand computes.
            """,
            description: """
            Connector swapped: `\(original)` replaced with `\(replacement)`. `&&` and `||` disagree exactly on \
            the two "one true, one false" operand combinations (in either order). A test exercising both \
            combinations, with an assertion that depends on the compound condition's result, distinguishes them \
            — the deciding run's tests did not supply both.
            """
        )
    }

    /// `TernaryBranchSwapOperator` (`Sources/SwiftCoreOperators/
    /// TernaryBranchSwapOperator.swift`): exchanges the ternary's
    /// `thenExpression`/`elseExpression` text only — the condition and the
    /// `?`/`:` tokens are untouched (see that type's own doc comment).
    private static func ternaryObligation(original: String, replacement: String) -> TestObligation {
        // `TernaryBranchSwapOperator.Visitor.visit` records a candidate for
        // *every* ternary it finds, with no check that the two branches
        // differ — unlike, say, `ReturnValueReplacementOperator`'s own
        // skip-if-already-neutral check for its own candidates (a real
        // check, but on a different operator's candidates, not this one's;
        // it proves nothing about whether this operator's branches differ).
        // When the two branches are literally identical source text
        // (`flag ? x : x`), swapping them yields the exact same source, so
        // `original == replacement` here — a fact provable directly from
        // the two token strings, with no operand semantics needed at all.
        guard original != replacement else {
            return TestObligation(
                kind: .ternaryBranchObservation,
                confidence: .high,
                rationale: """
                TernaryBranchSwapOperator records a candidate for every ternary it finds, with no check that the \
                `thenExpression`/`elseExpression` it swaps actually differ. Here they are the same source text, \
                so swapping them produces the identical source — `original == replacement`, provable from the \
                two token strings alone, no operand semantics required.
                """,
                description: """
                Branches swapped: `\(original)` → `\(replacement)` — the same text before and after, because \
                the true and false result expressions were already identical. No test, however constructed, \
                can distinguish this mutant from the original: they are the same program. This is not a missing \
                assertion; it is an equivalent mutant this operator's own discovery does not filter out. \
                Consider simplifying the source (a ternary whose branches are identical is redundant \
                conditional logic) rather than writing a test aimed at killing it.
                """
            )
        }

        // The branches differ in text — the common case, and the one this
        // operator's own doc comment and fault-evidence example both
        // describe. Whether that text difference is also a *value*
        // difference for the inputs a test actually exercises is not
        // something the swap operation itself guarantees (two differently
        // written expressions can still be equal, e.g. `flag ? [] :
        // [Int]()`), and is not visible from the (original, replacement)
        // text pair alone — one hop from the mutation site, like
        // `.returnValueAssertion` above, hence medium rather than high.
        return TestObligation(
            kind: .ternaryBranchObservation,
            confidence: .medium,
            rationale: """
            TernaryBranchSwapOperator only ever exchanges the two result expressions, never the condition, and \
            the two are textually distinct here. In the overwhelming common case distinct branch text also \
            means distinct runtime values, so an assertion on the actual result is what is missing — but that \
            is a fact about what these two specific expressions evaluate to, not something the swap operation \
            itself proves; this analyzer cannot verify it from the recorded text alone.
            """,
            description: """
            Branches swapped: the true/false result expressions were exchanged (`\(original)` → `\(replacement)`). \
            A test that asserts on the actual returned value — once with a condition that is true, once with one \
            that is false — observes different results before and after the swap, provided `\(original)` and \
            `\(replacement)` really do evaluate to different values for the inputs used; the deciding run's \
            assertions did not depend on which branch's value was produced.
            """
        )
    }

    /// `UnaryNotRemovalOperator` (`Sources/SwiftCoreOperators/
    /// UnaryNotRemovalOperator.swift`): removes a boolean prefix `!`,
    /// leaving the inner expression's own text as the replacement (see its
    /// `record(... replacementText: node.expression.trimmedDescription ...)`).
    private static func unaryNotObligation(original: String, replacement: String) -> TestObligation {
        TestObligation(
            kind: .unaryNotPolarity,
            confidence: .high,
            rationale: """
            UnaryNotRemovalOperator removes exactly one `!` — the resulting condition is the exact logical \
            complement of the original at every input, a fixed fact independent of what the condition computes.
            """,
            description: """
            Negation removed: `\(original)` became `\(replacement)`. The mutant takes the branch the original's \
            complement would have taken. A test exercising the case where `\(replacement)` evaluates `true` \
            (where `\(original)` would have been `false`), with an assertion whose result depends on that, \
            distinguishes them.
            """
        )
    }

    /// `BoolLiteralInversionOperator` (`Sources/SwiftCoreOperators/
    /// BoolLiteralInversionOperator.swift`): flips a `true`/`false` literal
    /// to its opposite — the complete, closed set of alternatives for a
    /// `Bool`.
    private static func boolLiteralObligation(original: String, replacement: String) -> TestObligation {
        TestObligation(
            kind: .boolLiteralValue,
            confidence: .high,
            rationale: """
            BoolLiteralInversionOperator flips exactly the two Boolean values — the complete, closed alternative \
            set for a `Bool` — so the mutant differs from the original in only that one dimension.
            """,
            description: """
            Literal flipped: `\(original)` → `\(replacement)`. A test asserting on behavior that actually depends \
            on this literal's value — not merely that some value exists — distinguishes the two.
            """
        )
    }

    /// `ReturnValueReplacementOperator` (`Sources/SwiftCoreOperators/
    /// ReturnValueReplacementOperator.swift`): replaces an explicit
    /// `return <expr>`'s value with `nil` (syntactically-`Optional` return
    /// types) or a literal-kind-specific neutral default (`0`/`""`/`[]`/
    /// `[:]`) — see `neutralLiteralReplacement`/the `isSyntacticallyOptional`
    /// branch in that file for the fixed, closed set this analyzer mirrors
    /// only for classification, below.
    private static func returnValueObligation(original: String, replacement: String) -> TestObligation {
        let neutralDefaults: Set<String> = ["nil", "0", "\"\"", "[]", "[:]"]
        guard neutralDefaults.contains(replacement) else {
            return unmodeledObligation(operatorID: "swift.core.return-value-replacement", original: original, replacement: replacement)
        }
        return TestObligation(
            kind: .returnValueAssertion,
            confidence: .medium,
            rationale: """
            ReturnValueReplacementOperator substitutes a fixed, syntactically-determined neutral default \
            (`nil`/`0`/`""`/`[]`/`[:]`) for the real computed value — precise about *what* changed, but whether \
            any test actually asserts on the return (as opposed to merely calling the function) is a fact about \
            the caller, one hop away from this mutation site, which is why this ranks medium rather than high.
            """,
            description: """
            Return value neutralized: this call site now always returns `\(replacement)` here, regardless of \
            what `\(original)` actually computes. A test that calls this function and asserts the return equals \
            its real expected value — not merely that it is non-nil, non-empty, or present — distinguishes them; \
            checking only "a value came back" cannot.
            """
        )
    }

    /// The honest fallback: an operator ID this analyzer has no real,
    /// source-read semantics for (see `TestObligation`'s own doc comment for
    /// when this is reachable). Still grounded in this mutant's own real
    /// `original`/`replacement` text — it just declines to claim a
    /// mechanically-specific obligation kind it has not verified.
    private static func unmodeledObligation(operatorID: String, original: String, replacement: String) -> TestObligation {
        TestObligation(
            kind: .unmodeledOperator,
            confidence: .low,
            rationale: """
            `\(operatorID)` is not one of the default-profile operators this analyzer has real, source-read \
            semantics for (RelationalOperatorReplacementOperator, LogicalConnectorReplacementOperator, \
            TernaryBranchSwapOperator, UnaryNotRemovalOperator, BoolLiteralInversionOperator, \
            ReturnValueReplacementOperator) — asserting more than "the text changed" here would be guessing.
            """,
            description: """
            Real change at this site: `\(original)` → `\(replacement)`. No mechanically-specific obligation is \
            derived automatically for this operator — inspect the diff and add an assertion whose outcome \
            depends on this exact change.
            """
        )
    }
}

/// One surviving/uncovered mutant's own fix-plan entry — real facts, a
/// typed inference, a concrete obligation, and a working reproduce command,
/// as four separate, stable, agent-consumable fields. Every field traces
/// back to real data already in `RunReport`/`SurvivorActionabilityReport`;
/// nothing here is fabricated to fill out a schema.
public struct MutantFixPlanEntry: Codable, Sendable, Equatable {
    /// What actually happened — read straight off `MutationResult`/
    /// `SurvivorActionabilityReport`, nothing re-derived or guessed.
    public struct Facts: Codable, Sendable, Equatable {
        public let mutantID: String
        public let operatorID: String
        public let file: String
        public let line: Int
        public let column: Int
        public let declaration: String
        public let original: String
        public let replacement: String
        public let outcome: MutationOutcome
        /// `MutationResult.diagnosis` — the verifier's own one-sentence
        /// explanation, not re-derived here.
        public let diagnosis: String
        /// From `MutationResult.testSummary` — `nil` for `.noCoverage`
        /// (never populated for that outcome; see `ExecutedMutationProof`'s
        /// own doc comment) and, honestly, whenever the run's own test
        /// adapter reported no per-test summary for a `.survived` result
        /// either.
        public let testsRun: Int?
        public let testsPassed: Int?
        public let testsFailed: Int?
        /// The exact tests known to have run in the deciding attempt, only
        /// when `testScope` is `.narrowed` — `nil` otherwise, matching
        /// `SurvivorActionabilityReport.TestScope`'s own discipline against
        /// overclaiming which tests actually ran.
        public let knownCoveringTests: [String]?
        /// `SurvivorActionabilityReport.Reason.coveredButNotCaught`'s own
        /// `TestScope` — `nil` for a `.noCoverage` mutant, where no test
        /// scope applies at all.
        public let testScope: SurvivorActionabilityReport.TestScope?
        /// How many mutants share this exact root cause (same declaration,
        /// same `Reason`) — `SurvivorActionabilityReport.IssueCluster
        /// .members.count`, reused rather than recomputed.
        public let clusterSize: Int
        public let clusterMutantIDs: [String]

        public init(
            mutantID: String, operatorID: String, file: String, line: Int, column: Int, declaration: String,
            original: String, replacement: String, outcome: MutationOutcome, diagnosis: String,
            testsRun: Int?, testsPassed: Int?, testsFailed: Int?, knownCoveringTests: [String]?,
            testScope: SurvivorActionabilityReport.TestScope?, clusterSize: Int, clusterMutantIDs: [String]
        ) {
            self.mutantID = mutantID
            self.operatorID = operatorID
            self.file = file
            self.line = line
            self.column = column
            self.declaration = declaration
            self.original = original
            self.replacement = replacement
            self.outcome = outcome
            self.diagnosis = diagnosis
            self.testsRun = testsRun
            self.testsPassed = testsPassed
            self.testsFailed = testsFailed
            self.knownCoveringTests = knownCoveringTests
            self.testScope = testScope
            self.clusterSize = clusterSize
            self.clusterMutantIDs = clusterMutantIDs
        }

        public var displayLocation: String { "\(file):\(line):\(column)" }
    }

    /// What kind of gap this is, and how confidently that kind was derived
    /// — `TestObligation.kind`/`.confidence`/`.rationale`, kept as their own
    /// real (`Codable`, `RawRepresentable<String>`) types rather than
    /// flattened to plain strings, so a `--json` consumer and `NextFixRecommendation`'s
    /// own ranking read the identical typed value.
    public struct Inference: Codable, Sendable, Equatable {
        public let gapKind: TestObligation.Kind
        public let confidence: TestObligation.Confidence
        public let rationale: String

        public init(kind: TestObligation.Kind, confidence: TestObligation.Confidence, rationale: String) {
            gapKind = kind
            self.confidence = confidence
            self.rationale = rationale
        }
    }

    /// The concrete, mechanically-derived distinction a new test would need
    /// to make — `TestObligation.description`.
    public struct Obligation: Codable, Sendable, Equatable {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    public let facts: Facts
    public let inference: Inference
    public let obligation: Obligation
    /// `mutantkit reproduce <id>` — the exact syntax `ReproduceCommand`
    /// accepts, identical to `SurvivorActionabilityReport.Member
    /// .reproduceCommand`.
    public let reproduceCommand: String

    public init(facts: Facts, inference: Inference, obligation: Obligation, reproduceCommand: String) {
        self.facts = facts
        self.inference = inference
        self.obligation = obligation
        self.reproduceCommand = reproduceCommand
    }
}

/// The whole-report envelope `mutantkit fix-plan --json` prints — one
/// `schemaVersion`-stamped document, matching every other `--json` shape in
/// this codebase (`TrustReport`, `SurvivorActionabilityReport`, ...).
public struct TestObligationFixPlan: Codable, Sendable {
    public let schemaVersion: Int
    public let planID: String
    public let entries: [MutantFixPlanEntry]

    public init(planID: String, entries: [MutantFixPlanEntry]) {
        schemaVersion = SchemaVersion.testObligationFixPlan
        self.planID = planID
        self.entries = entries
    }

    public static func build(from report: RunReport) -> TestObligationFixPlan {
        TestObligationFixPlan(planID: report.planID, entries: TestObligationAnalyzer.buildFixPlan(from: report))
    }
}
