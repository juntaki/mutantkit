# Operators

The operator catalog: what each operator changes, which profile enables it, and
what to know before acting on its results. See the [README](../README.md) for
the short "what is enabled by default" summary.

## Profiles

`operators.profile` takes `default`, `stronger` or `all`. `stronger` selects the
six `default` operators plus `swift.core.nil-coalescing-fallback`; it is the tier
operators move into as they are evaluated. The v1.x values keep their meaning exactly and are still
accepted: `conservative` (only the four high-confidence operators, fewer than
`default`) and `experimental` (everything, the same as `all`). The Profile
column below uses the v1.x names, except `stronger` for the one operator in that tier.

An operator is enabled by default only when it corresponds to a documented real
fault pattern, has positive and negative syntax fixtures, compiles reliably,
produces no phantom or duplicate mutants, behaves the same in isolated and
schemata execution, and yields a diff the developer can act on. Everything else
stays opt-in through `operators.profile: all` or an explicit `operators.enable`
entry.

## Stability

**Operator IDs.** An operator's `id` is part of every `MutationID` it produces,
so renaming an `id` is, downstream, the same as removing the operator and adding
a new one. The six default operators, `swift.core.bool-literal-inversion`,
`swift.core.logical-connector-replacement`,
`swift.core.relational-operator-replacement`, `swift.core.unary-not-removal`,
`swift.core.return-value-replacement` and `swift.core.ternary-branch-swap`, keep
their `id` within the `v1.x` release line, so a baseline recorded with any `v1.x`
release stays comparable for them. An operator promoted to default later gets
the same guarantee from that release on. Experimental operators come with no
`id` stability guarantee, and their matcher (which mutations are found in the
same source) may change without a version bump; treat a baseline pinned against
an experimental operator as more likely to need re-establishing after an
upgrade.

**Removed or renamed operators.** A baseline survivor whose operator no longer
exists would simply stop appearing in a new report, which reads as "fixed". To
avoid that, `mutantkit gate --baseline <path>` prints a warning on stderr naming
every operator ID in the baseline that this build does not know. It warns
instead of failing, because an operator can be legitimately absent from one
build (for example through `operators.disable`).

## Core operators

| Operator | Profile | Confidence | Mutation | Notes | Schemata |
| --- | --- | --- | --- | --- | --- |
| `swift.core.bool-literal-inversion` | conservative | high | `true` ↔ `false` | | yes |
| `swift.core.relational-operator-replacement` | conservative | high | boundary shift and negation, e.g. `<` → `<=`, `>=` | | yes |
| `swift.core.logical-connector-replacement` | conservative | high | `&&` ↔ `\|\|` | | yes |
| `swift.core.ternary-branch-swap` | conservative | high | `a ? b : c` → `a ? c : b` | Keeps the comments and trivia around the condition and both branches. Always compiles. | yes |
| `swift.core.unary-not-removal` | default | medium | `!x` → `x` | A multi-`!` token (`!!x`) is not assumed to be stacked built-in negation, because it could be a user-defined operator. | yes |
| `swift.core.return-value-replacement` | default | medium | an explicit `return` value → a neutral value | Only `return`s whose neutral replacement the syntax alone proves safe. Equivalent spellings (`0x0`, `nil as T?`, `Optional<T>.none`, an empty raw string, ...) are excluded by value, not by text. | yes |
| `swift.core.nil-coalescing-fallback` | stronger | medium | `a ?? b` → `b` | A survivor means the suite never showed that a non-nil left-hand value is preferred over the fallback, not that the nil path is untested. Code with many defensive fallbacks can produce many low-value survivors. | yes |
| `swift.core.arithmetic-operator-replacement` | experimental | medium | `+` ↔ `-`, `*` ↔ `/` | No symbol resolution, and Swift's arithmetic protocols do not guarantee a matched pair (`Numeric` has no `/`), so a mutant can fail to compile (reported as `unviable`). Mutants in loop and index arithmetic can hang. | no |
| `swift.core.assignment-operator-replacement` | experimental | medium | `+=` ↔ `-=`, `*=` ↔ `/=` | Same compile-viability caveat as arithmetic replacement. | no |
| `swift.core.else-clause-deletion` | experimental | experimental | `if a { X } else { Y }` → `if a { X }` | Only a trailing `else` or `else if` clause is removed, never the `if` branch or the condition. Sites where removing `else` would break exhaustiveness (an `if`/`switch` expression, the last statement of a non-`Void` body) are skipped. | no |
| `swift.core.range-boundary-replacement` | experimental | experimental | `a..<b` ↔ `a...b` | Binary infix form only. The two forms are different range types, so a mutant can fail to compile, and `..<` → `...` can turn a valid index into an out-of-bounds access. | no |
| `swift.core.side-effect-call-removal` | experimental | experimental | deletes a standalone call statement whose result is discarded (logging, caching, a UI update, cleanup) | Never removes `fatalError`, `preconditionFailure`, `exit` or `abort`, the sole statement of a `guard`-else or `switch` case, the sole statement of an implicit-return body, or anything inside a result-builder body. `operators.sideEffectCallRemoval.excludeCalls` excludes calls by name. | no |

## Apple-platform operators

These target fault patterns specific to Apple platforms: lifecycle, task
cancellation, continuations, persistence, SwiftUI and accessibility. All are
experimental and off by default; enable them with `operators.profile: all` or
`operators.enable`.

| Operator | Profile | Confidence | Mutation | Notes | Schemata |
| --- | --- | --- | --- | --- | --- |
| `apple.concurrency.continuation-resume-removal` | experimental | medium | removes a bare `.resume()`, `.resume(returning:)`, `.resume(throwing:)` or `.resume(with:)` call | Skips the sole statement of a `switch` case, the sole statement of an implicit-parameter (`$0`) closure, and the last remaining `resume`-family call inside a `with*Continuation` closure. | no |
| `apple.persistence.required-decode-introduction` | experimental | medium | `try container.decodeIfPresent(T.self, forKey: key) ?? fallback` → `try container.decode(T.self, forKey: key)` | Turns a schema-evolution-safe optional field back into a required one. | no |
| `apple.concurrency.post-await-cancellation-guard-removal` | experimental | experimental | removes `guard !Task.isCancelled else { return }` when it directly follows an item containing an `await` | A cancelled task then publishes its stale result. | no |
| `apple.swiftui.task-id-removal` | experimental | experimental | removes the `id:` argument of `.task(id:)` and `.task(id:priority:)` | The view's async task no longer restarts when its identity-driving input changes. | no |
| `apple.lifecycle.foreground-event-replacement` | experimental | experimental | `UIApplication.didBecomeActiveNotification` ↔ `UIApplication.willEnterForegroundNotification` | Matched only in the exact `UIApplication.<member>` form; each direction models a different fault. | no |
| `apple.accessibility.explicit-label-removal` | experimental | experimental | `view.accessibilityLabel(label)` → `view` | Replaces the whole call with its receiver, so closure-returning shapes stay valid `View` expressions. Needs the UI-test execution substrate to observe (see [Execution](execution.md#ui-test-targets-xcodeprojectxcodeworkspace-only)). | no |
| `apple.swiftui.hit-area-shape-removal` | experimental | experimental | removes `.contentShape(Rectangle())` attached to a SwiftUI `Button`'s label | Only the exact single-argument `Rectangle()` form. The control keeps only its rendered content as tap area. Needs the UI-test execution substrate to observe. | no |

## Schemata execution

With `execution.strategy: schemata`, one shared build embeds every mutation and a
verifier decides each verdict from build and runtime evidence. This is
per-operator: the six default operators above are embeddable, and every other
operator automatically falls back to isolated execution. See the
[schemata support matrix](schemata-support-matrix.md) for the supported
platforms.
