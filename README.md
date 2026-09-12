# MutantKit

Trustworthy mutation testing for Swift and Apple platforms.

## Why another mutation testing tool?

1. A mutation can silently fail to reach the binary — a tool can complete,
   print a confident score, and have applied nothing at all.
2. A runner can misclassify infrastructure failure (a stale build, a
   crashed simulator, an unlinked source file) as a test result.
3. Coverage and mutation score answer different questions, and folding one
   into the other hides which is failing.

MutantKit records evidence for each step and fails closed when that
evidence cannot be reconciled: **a test-quality verdict is never inferred
from an unverified mutation run.** See
[What makes this one different](#what-makes-this-one-different).

```bash
brew install juntaki/mutantkit/mutantkit

mutantkit setup
mutantkit dry-run
mutantkit plan --output plan.json
mutantkit run --plan plan.json --fail-on-survivors
```

MutantKit introduces small faults into your code and checks whether your
tests notice. A test that still passes after a relevant behavior is
mutated did not detect that particular fault — and line coverage cannot
tell you which tests those are, since a line can run inside a test with
nothing checking what it produced.

## What makes this one different

Not the operator count. The claim is narrower and, unusually for this
category, falsifiable:

> **MutantKit never classifies a mutant as killed or survived unless it can
> prove the mutation was applied to your source and the mutated program was
> executed.** Mutants proven unreachable from baseline coverage are
> reported separately as `noCoverage` — never silently folded into either
> verdict.

That is a strange thing to have to promise. It exists because the failure
mode it rules out is real and it is silent: a mutation testing tool can
complete successfully, print a confident score, and have applied no
mutations at all. The number looks fine. It is measuring nothing.

So MutantKit fails closed. A run that cannot reconcile its own invariants
produces integrity violations and **no score** — not a zero, not a partial
number, no score. A mutant with no source diff behind it is a phantom, and
a phantom fails the whole run rather than quietly joining the denominator.

Concretely:

- **Activation is measured, not assumed.** A mutant's compiled code is
  compared against the baseline's, so a mutation that reached the source
  but not the binary is caught rather than scored.
- **A mutation is a value, not a syntax node.** The Mutation Plan is plain
  JSON and the only source of truth — mutations are anchored to UTF-8 byte
  ranges and content hashes, never SwiftSyntax node identity, so plans
  survive sharding, resuming and reproduction.
  ([ADR-0002](ADR/0002-the-mutation-plan-is-the-source-of-truth.md))
- **A stale anchor is a diagnosis, not a corruption.** If the file changed,
  you get `notApplied` with a precise reason — MutantKit never relocates an
  edit to a nearby offset by guesswork, and never lets an unknown become
  `survived`.
- **Test results come from structured output, not regexes over stdout.**
  `.xcresult` for Xcode; `swift test`'s exit status plus its structured
  xUnit report for SwiftPM/macOS. Never inferred from console text, which
  lies whenever a test framework's own formatting changes.
- **MutantKit owns the timeout, and reclaims what it starts.** A mutant
  that deletes a `continuation.resume()` hangs forever; MutantKit kills the
  process group *and* every descendant it can find by PID, because
  SwiftPM's test helper moves itself into a new group and would otherwise
  escape, spin, and hold the output pipe open.
- **Two scores, never one.** `Tested` and `Effective` answer different
  questions — see [Evidence model](docs/evidence-model.md) — and quietly
  reporting only the flattering one is how a suite with poor coverage comes
  to look excellent.

Full depth — integrity violation kinds, the `noCoverage` fast path's own
history, what "activation" actually means end to end — lives in
[docs/evidence-model.md](docs/evidence-model.md).

> **v0.3.0 (latest release).** SwiftPM and Xcode projects, isolated and
> schemata execution, CI gating, coverage-based test selection, caching,
> sharding, and resumable runs. Six operators are enabled by default;
> more remain experimental pending further validation — see
> [Operators](docs/operators.md) and [Supported today](#supported-today).

## Install

The release binary runs on macOS 14+ (Apple Silicon). The supported
development/execution environment — what CI actually builds and tests
against, and what a target project's own toolchain is verified with — is
Xcode 26.x; see [apple-support-matrix.md](docs/apple-support-matrix.md)
for the exact pinned version and what an older toolchain's status actually
is.

```bash
brew install juntaki/mutantkit/mutantkit
```

Prebuilt binary, no Swift toolchain build required. Verify manually instead:

```bash
curl -LO https://github.com/juntaki/mutantkit/releases/latest/download/mutantkit-macos-arm64.tar.gz
curl -LO https://github.com/juntaki/mutantkit/releases/latest/download/SHA256SUMS
shasum -a 256 -c SHA256SUMS
tar xzf mutantkit-macos-arm64.tar.gz
```

This confirms the download matches what was published — it protects against
corruption or an incomplete transfer, not against tampering. The [CI Action
path](#in-ci) below is stronger: it also verifies a `gh attestation`, which
this manual/Homebrew path does not.

### Building from source

For contributors, or platforms the prebuilt binary does not cover yet
(Intel Macs, CI images without Homebrew). Requires Swift 6.0+.

```bash
git clone https://github.com/juntaki/mutantkit.git && cd mutantkit
swift build -c release
# binary at .build/release/mutantkit
```

### In CI

On GitHub Actions, the bundled composite action wraps the tarball recipe
above (checksum-verified, attestation-verified) in one step:

```yaml
- uses: juntaki/mutantkit@v0.3.0   # pin an exact release tag
```

That is the entire effect — install, verify, add to `PATH`, stop. See
[CI](#ci) below for the `mode: ci` variant that also runs
doctor/plan/run/gate for you.

### Upgrading / uninstalling

```bash
brew upgrade mutantkit      # Homebrew install
brew uninstall mutantkit

mutantkit --version          # confirm what's actually running after either
```

A manually-extracted tarball install has no state to remove beyond the
binary itself and whatever `mutantkit.yml`/report files the project
accumulated — nothing is written outside the project directory.

## First local run

```bash
mutantkit setup      # detect the project, check the environment, write mutantkit.yml
mutantkit dry-run    # build + test the unmutated baseline once, prove the harness works
mutantkit plan --output plan.json
mutantkit run --plan plan.json --fail-on-survivors
```

Start with `setup`. It detects what kind of project you have, which scheme
and test targets it found, writes a best-effort starting `mutantkit.yml`
filling in everything it could detect, and then runs the same readiness
diagnostics `doctor` does — whether `build-for-testing` actually succeeds,
whether the `.xctestrun` really exists — against the config it just wrote,
before you spend an hour finding out otherwise. If it reports an ambiguous
scheme or an empty test-target list, resolve that in `mutantkit.yml` by
hand; `setup` deliberately never guesses at an ambiguous choice on your
behalf.

Prefer one step at a time? `mutantkit doctor` checks the environment alone
(worth re-running after an Xcode upgrade) and `mutantkit init` writes the
config alone — `setup` is a thin composition of exactly those two.

Before spending minutes planning and running the full mutant pool,
`mutantkit dry-run` builds and tests the unmutated baseline once, through
the same adapters and destination resolution a mutation run itself will
use — the cheapest way to confirm the harness actually works before any
mutant is involved.

`mutantkit run` does not fail the build just because a mutant survived —
see [What a surviving mutant means](#what-a-surviving-mutant-means). Pass
`--fail-on-survivors`, as above, to make a run mean something to CI.

### Shell completion

```bash
mutantkit --generate-completion-script zsh > ~/.zsh/completions/_mutantkit   # zsh
mutantkit --generate-completion-script bash > /usr/local/etc/bash_completion.d/mutantkit  # bash
mutantkit --generate-completion-script fish > ~/.config/fish/completions/mutantkit.fish   # fish
```

### Inspecting a mutant

A score is not actionable; a diff is. For any mutant:

```bash
mutantkit inspect mut_a1b2c3d4e5f6a7b8
```

shows the original and mutated source, the operator's reasoning, which
tests ran, the outcome, the exact build and test commands, the evidence,
and a command to reproduce it on its own:

```bash
mutantkit reproduce mut_a1b2c3d4e5f6a7b8
```

## Using MutantKit with coding agents

Using Claude Code or Codex? MutantKit ships an agent skill
([`skills/mutantkit/SKILL.md`](skills/mutantkit/SKILL.md)) that teaches the
CLI's integrity model and CI workflow — setup-first discipline, how to read
`integrity` before trusting a score, how to tell a real survivor from an
unkillable OS/hardware boundary, and what not to do. Point an agent at it
instead of re-deriving MutantKit's CLI surface from `--help` every session.

See [docs/agents.md](docs/agents.md) for plugin installation (Claude Code,
Codex) and manual fallbacks (`.claude/skills/`, `AGENTS.md`).

## CI

### Using the bundled GitHub Action

`- uses: juntaki/mutantkit@<ref>` on its own only installs the binary. Add
`mode: ci` to run doctor → plan → run → gate end to end against the
checked-out project's own `mutantkit.yml`, with a persisted baseline for
regression checks, a job summary, and a downloadable report artifact:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0        # only needed if you pass `diff:` below

- uses: juntaki/mutantkit@v0.3.0
  with:
    mode: ci
    diff: origin/main      # optional — scope planning to lines changed against this ref
```

This is the same doctor/plan/run/gate sequence as the manual recipe below —
the action does not invent scope, thresholds, or report formats of its
own; those still live entirely in the project's own `mutantkit.yml`. See
[docs/ci.md](docs/ci.md) for every input, version pinning, diff scoping,
the baseline cache mechanics, run profiles, and how to read the exit code.

### Manual CI recipe

Useful directly for a CI system other than GitHub Actions:

```bash
mutantkit plan --output plan.json
mutantkit shard plan.json --count 8       # deterministic: a mutant always lands in the same shard
mutantkit run --plan plan.3.json --output results.3.json --no-history
mutantkit merge results/*.json
```

Plans are machine-independent JSON and every mutant checkpoints on
completion, so an interrupted run resumes rather than restarting. Full
recipe, including sharding and GitHub Actions inline annotations:
[docs/ci.md](docs/ci.md).

### Quality gate: turning a score into a merge decision

A report is not a merge decision. `mutantkit gate` is:

```bash
mutantkit gate --report report.json \
  --baseline main-report.json \
  --minimum-effective 70 \
  --regression-maximum-drop 2 \
  --new-survivors-maximum 0
```

or the same policy checked into `mutantkit.yml`, so it travels with the
repo instead of living in a CI YAML file:

```yaml
qualityGate:
  effectiveScore:
    minimum: 70
  regression:
    maximumDrop: 2       # percentage points versus --baseline
  survived:
    newMaximum: 0         # mutants surviving now that didn't survive in --baseline
  integrityViolations:
    maximum: 0             # the only accepted value — this is not configurable higher
```

`regression`/`survived` answer a different, usually more useful question
in day-to-day CI: **did this PR make things worse**, not just "is the
number above some fixed bar." `survived.newMaximum` diffs MutationIDs
against `--baseline`, so a codebase can carry a stable, reviewed backlog of
survivors and still fail CI the moment a genuinely new one shows up. Both
regression checks require `--baseline`; the gate fails closed with a clear
message if they are configured without one.

`qualityGate` is checked only by `gate`, never by `plan`/`run` — changing a
CI threshold does not change what gets mutated, so it does not invalidate
a plan or a checkpoint.

## What to point MutantKit at

Mutation testing is most valuable on deterministic domain/business logic,
where a test suite is expected to fully pin down behavior. Thin boundaries
to OS/hardware — CoreAudio/HAL wrappers, `SMAppService`, other hardware or
OS service adapters, network integration shims, UI glue — are often poor
mutation targets: a unit suite frequently cannot kill a mutant there even
when the code is correct, because the behavior it changes only manifests
through the real OS/hardware. A surviving mutant in that kind of code is
not necessarily "insufficient tests" — exclude it, or read its survival as
an integration-boundary finding rather than a coverage gap:

```yaml
sources:
  exclude:
    - Sources/AudioHAL/**
    - Sources/SystemIntegration/**
```

## Suppressing one mutation

`sources.exclude` is file-level: the mutation is never even discovered. For
a single known-noisy mutant inside an otherwise-worth-mutating file,
MutantKit has two finer-grained options instead, both of which keep the
mutation **visible in the plan as suppressed, with a reason**, never a
silent drop:

```swift
// mutantkit:disable-next-line swift.core.relational-operator-replacement
if index < count { ... }

if index < count { ... } // mutantkit:disable-line swift.core.relational-operator-replacement
```

Omit the operator list to suppress every operator on that line. Or a
`.mutantkitignore` file at the project root (or `--ignore-file`), for
suppressions that don't map to one line:

```
# .mutantkitignore
id:mut_a1b2c3d4e5f6a7b8
operator:swift.core.logical-connector-replacement
file:Sources/Generated/**
line:Sources/Foo.swift:42
```

Either source produces the same audit trail: a suppressed mutant stays in
`plan.skipped` with `reason: userRequested` and a `detail` naming the exact
rule that matched, so `discovered == planned + skipped` always holds.

**`file:`'s glob and `sources.exclude`'s glob are not quite the same
contract.** Both use the same underlying grammar (`*`/`?` bounded to one
path segment, never crossing `/`; a whole-segment `**` for zero or more
segments) — but `sources.exclude` additionally treats naming a directory
as covering everything inside it (`exclude: ["Sources/Generated"]` drops
the whole tree, the same convenience a `.gitignore` entry gives you).
`.mutantkitignore`'s `file:` rule does not: it matches the grammar alone,
so suppressing a directory's contents needs the explicit `Sources/Generated/**`
shown above, not the bare directory name.

## What a surviving mutant means

- **`survived`** — the tests ran, covered the mutated line, and all passed
  anyway.
- **`noCoverage`** — the tests passed, but nothing ran the mutated line at
  all — a coverage gap, scored separately rather than folded into
  `survived`.
- **`notApplied` / `baselineMismatch` / `infrastructureFailure`** — the run
  itself has a problem, not the test suite. The first two fail the whole
  run and withhold the score; `infrastructureFailure` excludes just that
  one unprovable mutant.

Two scores are reported, deliberately: **Tested**
(`killed / (killed + survived)`) and **Effective**
(`killed / (killed + survived + noCoverage)`). Full definitions, and why a
single score hides which failure mode you're looking at:
[docs/evidence-model.md](docs/evidence-model.md).

## Trust and actionability

A finished report answers "what survived" — these four commands answer
"can I trust this run, and what do I do about it":

```bash
mutantkit trust --report report.json      # is this report trustworthy? fails if it can't be
mutantkit survivors --report report.json  # survivors grouped by declaration, one entry per root cause
mutantkit fix-plan --report report.json   # per-survivor: facts, inference, obligation, how to reproduce
mutantkit next --report report.json       # the single recommended-next survivor to fix, with why
```

`trust` checks the report's own evidence (coverage completeness, integrity
violations, batching/attribution soundness) rather than assuming a
finished run is automatically a sound one, and fails closed if it isn't.
`survivors`, `fix-plan`, and `next` all take `--json` for machine
consumption, and `fix-plan`/`next` additionally accept `--format agent` for
a terser, LLM-oriented text format meant for a coding agent acting on the
result directly.

## Supported today

| Area | Status |
| --- | --- |
| SwiftPM (macOS) | Supported |
| SwiftPM (Apple platforms, e.g. iOS) | Supported |
| Xcode project / workspace | Supported |
| iOS Simulator | Supported |
| Isolated execution | Supported |
| Schemata execution | Supported for the six promoted operators, on `swiftPackageMacOS` and `xcodeProject`+iOS Simulator only — `swiftPackageApple` and `xcodeWorkspace` fall back to isolated mode regardless of operator |
| UI tests (XCUITest) | Supported for an existing Xcode project/workspace target and scheme, `isolated` mode, on iOS Simulator — proven end to end by a real operator-generated mutation campaign; no UI-automation DSL, no new project kind |
| On-device (physical hardware) tests | Unsupported for schemata (fails closed); untried for isolated — no claim either way |
| tvOS / watchOS / visionOS | Isolated: best-effort, real-simulator proof deferred. Schemata: not supported |
| Apple-specific mutation operators (lifecycle, concurrency, persistence, SwiftUI, accessibility) | Experimental — seven research-derived operators landed (two validated opt-in, five experimental for documented empirical reasons); see [docs/operators.md](docs/operators.md) |

See `docs/apple-support-matrix.md` for the full, citation-backed contract
(supported / tested / best-effort / unsupported) across Swift/Xcode/macOS
versions, project kind, test framework, and execution mode.

## Reports

MutantKit emits the [Mutation Testing Elements](https://github.com/stryker-mutator/mutation-testing-elements)
schema, so its output works with the same HTML renderer and dashboards
used by Stryker, PIT and others — its own JSON is richer (Stryker has no
vocabulary for `notApplied` or `baselineMismatch`), and the mapping
documents where information is lost rather than flattening the distinction.

Also available: console, Xcode warnings, self-contained HTML, a markdown
CI summary, `github-actions` (inline PR annotations — see
[docs/ci.md](docs/ci.md)), `sonar` ([generic issue import format](https://docs.sonarsource.com/sonarqube-server/latest/analyzing-source-code/importing-external-issues/generic-issue-import-format/)),
and `sarif` ([SARIF 2.1.0](https://docs.oasis-open.org/sarif/sarif/v2.1.0/os/sarif-v2.1.0-os.html)).
Killed mutants are not issues in either format — a quality gate needs to
know what to fix, not what already passed.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for running tests, the acceptance
suite, and the architecture sketch.

## Licence

Apache 2.0. See [LICENSE](LICENSE), [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES),
and [SECURITY.md](SECURITY.md).
