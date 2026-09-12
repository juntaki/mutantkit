import MutationModel
import MutationPlanner
import Testing

@Suite("Mutation suppression")
struct MutationSuppressionTests {
    @Test("parses all supported .mutantkitignore rule kinds")
    func parsesSupportedRules() throws {
        let set = try MutationSuppressionSet.parse("""
        # comment
        id:mut_deadbeef
        operator:swift.core.logical-connector-replacement
        file:Sources/Generated/**
        line:Sources/Foo.swift:42
        """)

        #expect(set.rules.count == 4)
    }

    @Test("rejects unknown suppression syntax")
    func rejectsUnknownRule() {
        #expect(throws: MutationSuppressionError.self) {
            _ = try MutationSuppressionSet.parse("something:else")
        }
    }

    @Test("rejects invalid line numbers")
    func rejectsInvalidLineNumber() {
        #expect(throws: MutationSuppressionError.self) {
            _ = try MutationSuppressionSet.parse("line:Sources/Foo.swift:0")
        }
    }

    /// v1 contract (2026-09-12): `.mutantkitignore`'s `file:` rule uses
    /// MutantKit's own `Glob` grammar (`SourceFileWalker.swift`) —
    /// segment-bounded `*`/`?`, whole-segment `**` — not POSIX `fnmatch`,
    /// which this rule used before this fix. The two disagree on real
    /// patterns: `fnmatch(pattern, path, 0)` (no `FNM_PATHNAME`) lets a
    /// bare `*` cross a `/`, so `Sources/*.swift` matched
    /// `Sources/A/B.swift` under the old engine — `Glob` never does.
    @Test("file: uses Glob's segment-bounded *, not fnmatch's slash-crossing *")
    func fileGlobUsesGlobNotFnmatchSegmentBoundary() {
        let nested = point(file: "Sources/A/B.swift", line: 1, operatorID: "swift.core.unary-not-removal")
        let plan = makePlan(mutations: [nested])

        let set = MutationSuppressionSet(rules: [.fileGlob("Sources/*.swift")])
        let result = set.applying(to: plan)

        #expect(result.mutations.map(\.id) == [nested.id], "a single-segment * must not cross a path separator")
        #expect(result.skipped.isEmpty)
    }

    /// The other half of the same contract: `file:` matches with `Glob`'s
    /// *bare grammar* (`Glob.matches`), never the ancestor convenience
    /// `sources.exclude` gets (`Glob.matchesAny`). Naming a directory in
    /// `file:` does not implicitly cover its contents — the descendant
    /// must be named explicitly (`Sources/Generated/**`), unlike
    /// `sources.exclude: ["Sources/Generated"]`, which does cover it. This
    /// keeps `sources.exclude`'s convenience (documented as a distinct,
    /// additive source-selection-layer semantic, not part of `Glob`'s own
    /// grammar) from silently leaking into a different YAML surface that
    /// deliberately does not opt into it.
    @Test("file: naming a directory does not implicitly suppress its contents — Glob's grammar, not the ancestor convenience")
    func fileGlobHasNoAncestorConvenience() {
        let nested = point(file: "Sources/Generated/X.swift", line: 1, operatorID: "swift.core.unary-not-removal")
        let plan = makePlan(mutations: [nested])

        let bareDirectory = MutationSuppressionSet(rules: [.fileGlob("Sources/Generated")])
        #expect(bareDirectory.applying(to: plan).mutations.map(\.id) == [nested.id])

        let explicitDescendant = MutationSuppressionSet(rules: [.fileGlob("Sources/Generated/**")])
        let suppressed = explicitDescendant.applying(to: plan)
        #expect(suppressed.mutations.isEmpty)
        #expect(suppressed.skipped.map(\.id) == [nested.id])
    }

    @Test("a fileLineOperator rule (from an inline comment) suppresses only its named operator on that line")
    func fileLineOperatorSuppressesOnlyItsOperator() {
        let relational = point(file: "F.swift", line: 3, operatorID: "swift.core.relational-operator-replacement")
        let unaryNot = point(file: "F.swift", line: 3, operatorID: "swift.core.unary-not-removal")
        let plan = makePlan(mutations: [relational, unaryNot])

        let set = MutationSuppressionSet(rules: [
            .fileLineOperator(file: "F.swift", line: 3, operatorID: "swift.core.relational-operator-replacement")
        ])
        let result = set.applying(to: plan)

        #expect(result.mutations.map(\.id) == [unaryNot.id])
        #expect(result.skipped.map(\.id) == [relational.id])
    }

    private func point(file: String, line: Int, operatorID: String) -> MutationPoint {
        MutationPoint(
            id: MutationID(rawValue: "mut_\(file)_\(line)_\(operatorID)"),
            file: file,
            enclosingDeclaration: DeclarationIdentity(path: ["Test/test"]),
            operatorID: operatorID,
            operatorVersion: 1,
            occurrenceIndex: 0,
            utf8Range: ByteRange(0 ..< 1),
            originalText: "x",
            replacementText: "y",
            prefixTokenFingerprint: "pre",
            suffixTokenFingerprint: "post",
            sourceFileHash: "hash",
            expectedSyntaxKind: "kind",
            confidence: .high,
            executionMode: .isolated,
            line: line,
            column: 1
        )
    }
}
