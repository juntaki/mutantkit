# Evidence model

What a verdict actually proves, in full. See
[What makes this one different](../README.md#what-makes-this-one-different)
in the README for the short version and the falsifiable claim this all
serves.

## What a surviving mutant means

A mutant is one small, deliberate change to your source — a `<` flipped to
`<=`, a `&&` flipped to `||`, a return value replaced with a value the
syntax alone proves is safe. MutantKit builds and tests a copy of your
project with that one change applied, and classifies what happened:

- **`survived`** — the tests ran, covered the mutated line, and all passed
  anyway. This is the real finding: some test that exercises this code path
  never actually asserted on the behavior the mutation changed. Line
  coverage cannot show this — a line can run inside a test with nothing
  checking what it produced. Precisely: **a test that still passes after a
  relevant behavior is mutated did not detect that particular fault** — it
  may well be exercising other properties of the same code perfectly well.
- **`noCoverage`** — the tests passed, but nothing ran the mutated line at
  all. A coverage gap, not a suite-quality gap, and scored separately
  (below) rather than folded into `survived`.
- **`notApplied` / `baselineMismatch` / `infrastructureFailure`** — the run
  itself has a problem (a stale source anchor, an unmutated baseline that
  did not behave as recorded, a toolchain or simulator failure, or a
  mutation whose activation could not be proven), not a statement about the
  test suite. `notApplied` and `baselineMismatch` are integrity violations:
  they fail the whole run and withhold the score rather than being counted
  toward one. `infrastructureFailure` is narrower — it excludes just that
  one unprovable mutant from the score (`MutationScore.excluded`) without
  failing the rest of the run, since one orphaned source file or one flaky
  toolchain hiccup should not discard every other mutant's real evidence.

## Two scores, never one

Two scores are reported, deliberately, because reporting only one is how a
suite with poor coverage comes to look excellent:

- **Tested** (`killed / (killed + survived)`) answers "of the code my tests
  actually run, how much do they check?"
- **Effective** (`killed / (killed + survived + noCoverage)`) answers "of
  the code I asked to be mutated, how much is checked?"

**MutantKit never classifies a mutant as killed or survived unless it can
prove the mutation was applied and the mutated program was executed.**
Mutants proven unreachable from baseline coverage are reported separately
as `noCoverage`, not folded into either score's numerator, and not withheld
from the denominator either — `noCoverage` is real information about your
test suite's reach, not a run MutantKit is unsure about.

## Not every survivor means "write a test"

A unit suite frequently cannot kill a mutant at a thin OS/hardware boundary
— CoreAudio/HAL wrappers, `SMAppService`, other hardware or OS service
adapters, network integration shims, UI glue — even when the code is
correct, because the behavior it changes only manifests through the real
OS/hardware. Read a survivor there as an integration-boundary finding, not
a missing test — see
[What to point MutantKit at](../README.md#what-to-point-mutantkit-at) — and
either exclude the file with `sources.exclude`, or suppress the one mutant
if it's already a known, accepted gap — see
[Suppressing one mutation](../README.md#suppressing-one-mutation).

For any specific survivor, a score is not actionable but a diff is:

```bash
mutantkit inspect mut_a1b2c3d4e5f6a7b8   # original/mutated source, the tests that ran, why it survived
mutantkit reproduce mut_a1b2c3d4e5f6a7b8 # rerun just this one mutant, in isolation
```

By default, a survivor does not fail the build — a surviving mutant is a
finding, not a tool failure, and a suite is not broken for having one. Pass
`--fail-on-survivors` to `mutantkit run` to change that for a single
report, or use `mutantkit gate` to turn a report into an actual merge
decision — new survivors versus a baseline, a regression budget, a minimum
score — see
[Quality gate](../README.md#quality-gate-turning-a-score-into-a-merge-decision).

## Activation: measured, not assumed

A mutant's compiled code is compared against the baseline's, so a mutation
that reached the source but not the binary is caught rather than scored.
This is why every sandbox path is the same length: the build path leaks
into codegen, and unequal paths would make every mutant look activated for
reasons having nothing to do with the mutation.

## A mutation is a value, not a syntax node

The Mutation Plan is plain JSON and is the only source of truth. Mutations
are anchored to UTF-8 byte ranges and content hashes, never to SwiftSyntax
node identity — so re-parsing is harmless, discovery can drop every AST it
reads, and plans survive sharding, resuming and reproduction.
([ADR-0002](../ADR/0002-the-mutation-plan-is-the-source-of-truth.md))

## A stale anchor is a diagnosis, not a corruption

If the file changed, you get `notApplied` with a precise reason. MutantKit
never relocates an edit to a nearby offset by guesswork, and never lets an
unknown become `survived`.

## Test results come from structured output, not from regexes over stdout

For Xcode, verdict evidence comes from `.xcresult`. For SwiftPM/macOS,
MutantKit uses `swift test`'s exit status as the contract for the verdict,
plus `--xunit-output`'s structured xUnit report for counts and failing-test
names. Either way, it does not infer verdicts by regex-matching console
output, which lies whenever a test framework's own console formatting
changes.

## MutantKit owns the timeout, and reclaims what it starts

A mutant that deletes a `continuation.resume()` hangs forever. MutantKit
kills the process group *and* every descendant it can find by PID —
because killing the group is not enough on its own: SwiftPM's test helper
moves itself into a new group, and the one process that escapes is the one
running your tests. It survives, spins, and holds the output pipe open.
This is covered by a fixture that hangs on purpose.
