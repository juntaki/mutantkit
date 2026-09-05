---
name: mutantkit
description: Run and interpret MutantKit mutation testing for Swift and Apple-platform projects — check the environment, plan, run, inspect survivors, and gate CI on real test-suite strength rather than line coverage. Use whenever the user asks about mutation testing, test-suite quality, "are these tests actually testing anything", or mentions mutantkit/muter directly.
---

# MutantKit

MutantKit introduces small faults ("mutants") into Swift source and checks
whether the test suite notices. A mutant that survives means some test that
exercises that code path never actually asserts on the behavior the mutation
changed — line coverage alone cannot show this, since a line can run inside a
test without anything checking what it produced.

**Every mutant MutantKit reports has been proven applied to source and
executed against the real binary.** A run that cannot prove that produces
integrity violations and no score — never a silent phantom counted as if it
were real. Trust this tool's numbers accordingly, and be equally suspicious
of any other mutation-testing tool's output that does not make the same
claim.

> _Skill last verified against MutantKit's plan/report schema version 1 (the
> golden path this file describes: `setup` → `dry-run` → `plan` → `run
> --fail-on-survivors`). Check `mutantkit --version` (which prints both
> schema versions) and `mutantkit --help`; if either disagrees with anything
> below, trust the CLI's own output and treat this file as stale._

## Before doing anything else: `mutantkit setup`

Always run this first in a project MutantKit hasn't touched yet. `setup`
composes what `init` and `doctor` each do into one step: it detects project
kind (SwiftPM vs Xcode), schemes, and test targets; writes `mutantkit.yml`
(never overwriting an existing one unless you pass `--force`); then runs the
same readiness checks `doctor` performs, against the config it just wrote —
whether `build-for-testing` actually succeeds, whether the resulting
`.xctestrun` really exists — and tells you the exact next command to run.

```bash
mutantkit setup
```

Pass `--dry-run` to preview exactly what `setup` would detect and write,
without writing anything — safe to run repeatedly, including from an agent
still deciding whether to proceed. (This is a flag on `setup` itself, not
the separate `mutantkit dry-run` command in the workflow below — the two
are unrelated commands that happen to share a name; don't conflate them.)

If `setup` reports a problem, fix that before touching `plan`/`run` — a
misconfigured scheme or destination does not produce a wrong score, it
produces no usable run at all.

`mutantkit doctor` (readiness checks alone, writes nothing) and `mutantkit
init` (writes `mutantkit.yml` alone, checks nothing) still exist and work
standalone — reach for `doctor` on its own for a CI diagnostics step or a
project that already has a config and just needs re-checking. For a
brand-new project, `setup` is the one entry point to use.

## Core workflow

```bash
mutantkit setup                                              # detect project, check readiness, write mutantkit.yml
mutantkit dry-run                                             # build + test the baseline once, no mutants yet
mutantkit plan --output plan.json                             # discovers mutants, no source ever touched
mutantkit run --plan plan.json --output report.json --fail-on-survivors
```

`dry-run` builds and tests the unmutated project exactly once, using the
same adapters, destination resolution, and timeouts a real mutation run
will use. Run it before a first real `plan`/`run` on a project — it turns a
broken baseline into one clear failure instead of into every one of
hundreds of mutants failing for the same underlying reason.

`plan` never mutates a file — it is pure discovery, safe to run repeatedly
and safe to run unbudgeted (no `execution.budget.maxMutants`) to see the
full candidate pool before deciding a budget. `run` is the step that
actually builds and tests mutated copies, in an isolated sandbox — never the
user's working tree. `--fail-on-survivors` makes `run` itself exit non-zero
on any surviving mutant — for the more nuanced "did this change make things
worse against a baseline" question, see `mutantkit gate` below instead.

For a first run on an unfamiliar project, set a small budget
(`execution.budget.maxMutants: 20-50`) before running the full pool — a
misconfigured scheme turns into 50 failed builds instead of 500.

### Reading the result

Do not report a score in isolation. Read `report.json`'s `integrity` block
first:

```bash
python3 -c "import json; r=json.load(open('report.json')); print(r['integrity'])"
```

`violations: []` and `discovered == planned + skipped` is what makes the
`score` block trustworthy at all. If `integrity.violations` is non-empty,
say so plainly and do not quote the score — MutantKit itself refuses to
treat that run as scorable, and neither should you.

For any specific mutant — especially one you plan to discuss with the user
or act on — pull the real diff and diagnosis rather than working from the ID
alone:

```bash
mutantkit inspect mut_a1b2c3d4e5f6a7b8
```

This shows the original/mutated source, which tests ran, the exact outcome
and why, and a `mutantkit reproduce` command to rerun that one mutant in
isolation.

### Distinguishing a real gap from noise

A survived mutant is not automatically "add a test." Read the operator and
location before recommending anything:

- Thin OS/hardware boundaries (CoreAudio/HAL wrappers, system-service
  adapters, UI glue) routinely can't be killed by a unit suite even when the
  code is correct — the mutation's effect only manifests through the real
  OS/hardware. A survivor there is an integration-boundary finding, not
  necessarily a missing unit test. Suggest `sources.exclude` for whole
  files/directories in that category, not more unit tests.
- `noCoverage` (not `survived`) means no test reached the line at all — a
  coverage gap, not a suite-quality gap. Don't conflate the two when
  reporting results.
- `notApplied`/`baselineMismatch`/`infrastructureFailure` are tool/run
  problems, never a statement about the test suite. Never describe these as
  "the tests didn't catch it."

### Suppressing a specific mutant

For a single known-noisy mutant inside an otherwise-worth-mutating file,
don't reach for `sources.exclude` (file-level, too coarse). Use the
finer-grained options, both of which keep the mutation visible in the plan
as suppressed with a reason, never a silent drop:

```swift
// mutantkit:disable-next-line swift.core.relational-operator-replacement
if index < count { ... }
```

or a `.mutantkitignore` entry (`id:`/`operator:`/`file:`/`line:`) at the
project root. Prefer the inline comment when the suppression is about one
specific line the user is already looking at.

### CI / quality gates

```bash
mutantkit gate --report report.json --baseline main-report.json \
  --minimum-effective 70 --regression-maximum-drop 2 --new-survivors-maximum 0
```

`regression`/`survived.newMaximum` (diffed against `--baseline` by
`MutationID`) answer "did this change make things worse" — usually the more
useful CI question than a fixed absolute threshold. When asked to set up a
mutation-testing gate, default to this pattern rather than an absolute
minimum alone, and put the policy in `mutantkit.yml`'s `qualityGate:` block
so it travels with the repo instead of living only in CI YAML.

For large runs, shard rather than looping serially:

```bash
mutantkit plan --output plan.json
mutantkit shard plan.json --count 8   # deterministic: same mutant, same shard, every time
mutantkit run --plan plan.3.json --output results.3.json
mutantkit merge results/*.json
```

Every mutant checkpoints on completion, so an interrupted shard resumes
instead of restarting from zero.

## Configuration reference

`mutantkit.yml` at the project root (or `--config`). Full schema:
`mutantkit config --schema`. Key sections an agent commonly needs to touch:
`project.kind`/`scheme`/`destination` (Xcode projects only),
`sources.include`/`exclude`, `tests.targets`, `operators.profile`
(`conservative`/`default`/`experimental`), `execution.budget.maxMutants`,
`execution.strategy` (`isolated` default; `schemata` is supported for
`swiftPackageMacOS` and `xcodeProject` only — see
`docs/schemata-support-matrix.md` for the full support matrix, including
`swiftPackageApple`/`xcodeWorkspace`, which still fall back to isolated for
every mutation today; that document is a support matrix, not a benchmark,
and makes no speed claim). `schemata` is not uniformly faster, so never
switch a project to it for speed alone: on SwiftPM/macOS it measured
modestly faster than isolated (wall-clock ratio 1.034x–1.088x, ROR-only,
n=5 — roughly break-even), but on Xcode/iOS-Simulator it measured **62.5%
slower** on a real 100-mutant corpus (6383s vs 3928s, and the gap widened
with scale), which is why `isolated` is the default there and `schemata`
is an explicit opt-in for advanced or research use — see
`ADR/0009-ios-execution-default.md`. Every mutation's own result is
fail-closed regardless
of strategy: a schemata verdict that cannot prove its own runtime evidence
never gets guessed at, it re-runs isolated instead. CLI flags
override the config file, which overrides environment, which overrides
defaults.

## What NOT to do

- Don't report a `score` without checking `integrity.violations` first.
- Don't run `mutantkit run` unbudgeted on a project you haven't run
  `mutantkit setup` (or at least `doctor` + `dry-run`) against yet —
  diagnose config and baseline problems on a small budget first.
- Don't treat every survivor as a missing test — see "Distinguishing a real
  gap from noise" above.
- Don't hand-edit `plan.json` — it's the single source of truth and is
  content-hashed; a hand edit makes the plan internally inconsistent and
  `mutantkit run`/`decode` will reject it.
- Don't compare MutantKit's score numerically against Muter's or another
  tool's — they measure differently by design (MutantKit excludes anything
  it cannot prove was applied), so lower numbers from MutantKit are
  expected, not a regression.

## Full documentation

The project README (`README.md` at the repo root, or
https://github.com/juntaki/mutantkit) covers installation, the full
operator catalog with confidence levels, report formats, and the
architecture. Read it directly for anything this skill doesn't cover.
