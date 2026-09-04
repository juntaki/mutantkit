# Core operator expansion (PR #6)

Started as an intentionally-RED slice — this file originally specified the
first operator-expansion contract without adding production implementations.
All six operators below are now implemented; the suites named here are green.
Kept as a record of the contract decisions, since those are still the scope
each operator is held to.

Implementation order:

1. `swift.core.ternary-branch-swap`
2. `swift.core.unary-not-removal`
3. `swift.core.arithmetic-operator-replacement`
4. `swift.core.assignment-operator-replacement`
5. `swift.core.nil-coalescing-fallback`
6. `swift.core.return-value-replacement`

The tests resolve operators through `MutationRegistry` by ID, not by
referencing the concrete types directly — a deliberate choice from before any
operator existed, so the test target stayed compilable and each family's
suite failed with a precise `MissingOperator` rather than a build error.

Scope decisions, revised since initial implementation based on later corpus
validation (nil-coalescing-fallback has since been demoted to experimental):

- Ternary swapping is high-confidence and conservative-profile eligible.
- Unary-not and restricted return-value replacement are medium-confidence,
  **default**-profile operators. Nil-coalescing was originally shipped at
  default too, but was demoted to **`defaultEnabled: false`** after a
  real-project corpus run showed low signal density — see the operator
  catalog for the current status.
- Arithmetic and assignment replacement are medium-confidence but
  **`defaultEnabled: false`** — reachable only via `experimental` or an
  explicit `enable`. Neither has symbol resolution, and Swift's arithmetic
  protocols/compound-assignment operators do not guarantee a matched pair
  (`Numeric` has no `/`, `String` has no `-=`, a custom type may overload
  only one side of a pair). `CoreOperatorCompileViabilityAcceptanceTests`
  confirms this empirically — real `swiftc -typecheck` failures against a
  generic-`Numeric`, `String`, `Array`, and custom-type fixture — rather than
  merely asserting it. Promotion to default needs a real project-corpus
  compile-failure measurement, not just these five hand-picked cases.
- Arithmetic v1 covers only `+ <-> -` and `* <-> /`.
- Assignment v1 covers only `+= <-> -=` and `*= <-> /=`.
- Nil coalescing emits only the type-safe fallback variant, replacing the
  whole expression, never narrowing to one side. What a surviving mutant
  proves: the original and the mutant agree exactly when the left-hand side
  is `nil` (both evaluate to the fallback), so survival means the suite never
  proved a non-nil left-hand value is preferred over the fallback — not that
  the nil path itself is untested. `NilCoalescingFallbackSemanticsAcceptanceTests`
  confirms this by compiling and running both forms.
- Return-value replacement is restricted to explicit returns whose neutral
  replacement is syntactically justified, and must not duplicate bool literal
  inversion or emit already-equivalent neutral values — checked by actual
  value/structure, not text comparison: `0x0`/`0b0`/`0o0` are parsed to
  confirm they equal zero, `nil as T?`/`Optional<T>.none`/`.none` are all
  recognized as nil-equivalent, and an empty raw string or a whitespace-only
  `[ ]` are recognized as already empty regardless of spelling.
- Every family produces deterministic Mutation IDs, unique candidates, and an
  exact byte-splice application result that survives `SourceAnchorVerifier`'s
  full re-verification.
- Ternary and nil-coalescing both need `SyntaxFolding` (precedence folding) —
  SwiftParser's raw parse leaves `?:` and `??` as unresolved flat sequences;
  `SourceAnchorVerifier` folds the same way so re-verification sees the same
  tree shape discovery did. Return-value replacement also folds, for the same
  reason applied to `nil as T?`'s `as` cast.
- Ternary's replacement is built from a byte-level splice of the original
  source (condition, `?`/`:` tokens, and each branch's own trivia all stay in
  place), not a full-node reconstruction from `trimmedDescription`d pieces —
  the latter would silently drop any comment attached to the condition, the
  `?`/`:` tokens, or either branch.
- Unary-not removal matches the operator token *exactly* against `"!"` — a
  run of `!` characters (`!!`, `!!!`) is a single lexed token that could be a
  user-defined `prefix operator !!` with unrelated semantics, not provably a
  stack of built-in negations. A genuine double negation written with
  parentheses (`!(!flag)`) lexes as two separate tokens and is found as two
  independent, non-colliding sites.

Conditional-clause deletion and side-effect-call removal remain separate design
work because their safe syntax boundaries and exclusion policies need dedicated
contracts rather than being bundled into this slice. Side-effect-call removal's
design contract is now written — see
`Research/operator-catalog/side-effect-call-removal-design.md` — but not yet
implemented.
