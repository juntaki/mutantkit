# MutantKit

Trustworthy mutation testing for Swift and Apple platforms.

```bash
brew install juntaki/mutantkit/mutantkit

mutantkit doctor
mutantkit init
mutantkit plan --output plan.json
mutantkit run --plan plan.json
```

> **MutantKit never scores a mutant unless it can prove the mutation was
> actually applied to your source and executed.** See
> [What makes this one different](#what-makes-this-one-different).

MutantKit introduces small faults into your code and checks whether your tests
notice. Tests that pass against broken code are not testing anything, and
coverage cannot tell you which ones those are.

> **Status: v0.1, in development.** Isolated execution, with incremental builds,
> batched testing, coverage-based test selection, and cross-run caching to keep
> it fast at real-project scale. Eleven core operators (three experimental-only
> on compile-safety grounds — arithmetic and assignment, both with
> fixture-confirmed compile risk, plus arithmetic's own 2 confirmed
> reproducible runtime hangs found in corpus validation; nil-coalescing
> experimental-only for a different reason, demoted for low signal density
> against a real-project corpus; ternary/unary-not/return-value are
> corpus-measured on two real projects so far, assignment on one, neither
> yet the additional project shapes this catalog's own promotion bar calls
> for; two further operators — else-clause-deletion and
> range-boundary-replacement — are new and not yet corpus-measured on any
> project — see [Operators](#operators)).
> See [Roadmap](#roadmap) for what is and is not implemented.

## What makes this one different

Not the operator count. The claim is narrower and, unusually for this category,
falsifiable:

> **Every mutant MutantKit reports can be proven to have been applied to your
> source and executed. If it cannot be proven, MutantKit reports no score.**

That is a strange thing to have to promise. It exists because the failure mode it
rules out is real and it is silent: a mutation testing tool can complete
successfully, print a confident score, and have applied no mutations at all. The
number looks fine. It is measuring nothing.

So MutantKit fails closed. A run that cannot reconcile its own invariants produces
integrity violations and **no score** — not a zero, not a partial number, no
score. A mutant with no source diff behind it is a phantom, and a phantom fails
the whole run rather than quietly joining the denominator.

Concretely:

- **Activation is measured, not assumed.** A mutant's compiled code is compared
  against the baseline's, so a mutation that reached the source but not the
  binary is caught rather than scored. This is why every sandbox path is the same
  length: the build path leaks into codegen, and unequal paths would make every
  mutant look activated for reasons having nothing to do with the mutation.
- **A mutation is a value, not a syntax node.** The Mutation Plan is plain JSON
  and is the only source of truth. Mutations are anchored to UTF-8 byte ranges
  and content hashes, never to SwiftSyntax node identity — so re-parsing is
  harmless, discovery can drop every AST it reads, and plans survive sharding,
  resuming and reproduction. ([ADR-0002](ADR/0002-the-mutation-plan-is-the-source-of-truth.md))
- **A stale anchor is a diagnosis, not a corruption.** If the file changed,
  you get `notApplied` with a precise reason. MutantKit never relocates an edit to
  a nearby offset by guesswork, and never lets an unknown become `survived`.
- **Test results come from `.xcresult`**, not from regexes over stdout. Output
  formats change; structured results do not lie about whether a test failed.
- **MutantKit owns the timeout, and reclaims what it starts.** A mutant that deletes
  a `continuation.resume()` hangs forever. MutantKit kills the process group *and*
  every descendant it can find by PID — because killing the group is not enough
  on its own: SwiftPM's test helper moves itself into a new group, and the one
  process that escapes is the one running your tests. It survives, spins, and
  holds the output pipe open. This is covered by a fixture that hangs on purpose.
- **Two scores, never one.** `Tested` and `Effective` answer different
  questions, and quietly reporting only the flattering one is how a suite with
  poor coverage comes to look excellent.

## Install

Requires macOS 14+ on Apple Silicon, Xcode 16+.

```bash
brew install juntaki/mutantkit/mutantkit
```

This is the recommended install path: Homebrew's downloader never applies
macOS's quarantine attribute to the binary, so there is no Gatekeeper
friction — `brew install` and running `mutantkit` just works.

### Alternative: direct tarball download

No Homebrew required, but read this before you use it: the binary in the
tarball is only ad-hoc/linker-signed (the toolchain default, not a
deliberate signing step) — v0.1.0 is not Developer ID signed or notarized.

```bash
curl -LO https://github.com/juntaki/mutantkit/releases/latest/download/mutantkit-macos-arm64.tar.gz
curl -LO https://github.com/juntaki/mutantkit/releases/latest/download/SHA256SUMS
shasum -a 256 -c SHA256SUMS
tar xzf mutantkit-macos-arm64.tar.gz
./mutantkit-macos-arm64/mutantkit --version   # run in place, or move it onto your PATH:
# mkdir -p ~/.local/bin && cp mutantkit-macos-arm64/mutantkit ~/.local/bin/ && export PATH="$HOME/.local/bin:$PATH"
```

**Gatekeeper**: whether the extra step below is needed depends on *how* you
downloaded the file, not on signing status alone — macOS only quarantines
files downloaded by apps that opt into the quarantine mechanism (Safari,
Mail, Finder AirDrop, etc.); a plain `curl` run from Terminal, as shown
above, does **not** set `com.apple.quarantine` and was verified (macOS
26.5.2, curl 8.7.1) to run with no Gatekeeper prompt at all. Mainstream
browsers (Safari, Chrome, etc.) do opt into the quarantine mechanism for
ordinary downloads, so if you instead get the tarball by clicking a link
in one of those, expect the copy to be quarantined and Gatekeeper to
refuse to run it with "cannot be opened because it is from an
unidentified developer" — expected behavior for an unsigned binary, not a
bug in the tool. (Quarantine behavior is ultimately the browser's choice,
not a macOS guarantee independent of it, so treat this as "likely," not an
absolute for every browser/configuration.) If you hit that block, resolve
it one of two ways:

- **Finder (recommended for a first run)**: right-click (Control-click) the
  `mutantkit` binary and choose "Open," then confirm in the dialog that
  appears. This is Apple's own supported one-time-approval flow for
  unsigned binaries — it is not the same as disabling Gatekeeper.
- **Terminal-only**: after you've verified the checksum above yourself,
  remove the quarantine attribute from that one file only:

  ```bash
  xattr -d com.apple.quarantine ./mutantkit-macos-arm64/mutantkit
  ```

  This clears quarantine on the single downloaded binary, not system-wide —
  do not run a recursive or wholesale Gatekeeper disable.

**Integrity beyond the checksum**: the checksum above only catches
corruption, not a maliciously replaced release asset (the tarball and
`SHA256SUMS` are both fetched from the same mutable GitHub Release). Every
release tarball also carries a Sigstore-backed build provenance attestation
generated by GitHub Actions at build time; verify it independently with
[`gh attestation verify`](https://cli.github.com/manual/gh_attestation_verify):

```bash
gh attestation verify mutantkit-macos-arm64.tar.gz --repo juntaki/mutantkit
```

### Building from source

For contributors, or platforms the prebuilt binary does not cover yet (Intel
Macs, CI images without Homebrew). Requires Swift 6.0+.

```bash
git clone https://github.com/juntaki/mutantkit.git && cd mutantkit
swift build -c release
# binary at .build/release/mutantkit
```

### In CI

The tarball path (above) needs no Homebrew and no repo checkout. `release.yml`'s
`clean-machine-e2e` job verifies the same effective install path — checksum
verify, extract, put on `PATH`, run — against the freshly built artifact
(via `actions/download-artifact`, not a live `curl` against a published
GitHub Release, since no release exists yet for a not-yet-tagged build); a
real CI job installing an already-published release looks like this:

```yaml
- name: Install mutantkit
  run: |
    curl -LO https://github.com/juntaki/mutantkit/releases/latest/download/mutantkit-macos-arm64.tar.gz
    curl -LO https://github.com/juntaki/mutantkit/releases/latest/download/SHA256SUMS
    shasum -a 256 -c SHA256SUMS
    tar xzf mutantkit-macos-arm64.tar.gz
    echo "$PWD/mutantkit-macos-arm64" >> "$GITHUB_PATH"
- run: mutantkit doctor && mutantkit plan --output plan.json && mutantkit run --plan plan.json
```

Pin to a specific release instead of `latest` (e.g.
`.../releases/download/v0.1.0/...`) for a CI job that shouldn't change
behavior mid-week on its own.

### Upgrading / uninstalling

```bash
brew upgrade mutantkit       # Homebrew install
mutantkit --version          # confirm what's actually running after upgrading

brew uninstall mutantkit     # when you're done — mutantkit is no longer on PATH after this
```

A manually-extracted tarball install has no state to remove beyond the
binary itself and whatever `mutantkit.yml`/report files the project
accumulated — nothing is written outside the project directory.

## Use as an agent skill (Claude Code / Codex)

MutantKit ships a ready-to-use skill file at
[`skills/mutantkit/SKILL.md`](skills/mutantkit/SKILL.md) — practical
operating knowledge for an agent driving the CLI: doctor-first discipline,
how to read `integrity` before trusting a score, how to tell a real
survivor from an unkillable OS/hardware boundary, the suppression and
CI-gate patterns, and what not to do (report a score without checking
integrity, run unbudgeted before `doctor`, hand-edit `plan.json`). Point an
agent at it instead of re-deriving MutantKit's CLI surface from `--help`
output every session.

**Claude Code**: skills are auto-discovered from `.claude/skills/<name>/SKILL.md`
— personal (all projects) or project-scoped (this repo only):

```bash
# personal — available in every project
mkdir -p ~/.claude/skills/mutantkit
cp skills/mutantkit/SKILL.md ~/.claude/skills/mutantkit/SKILL.md

# project-scoped — this repo only, commit it if the whole team should have it
mkdir -p .claude/skills/mutantkit
cp skills/mutantkit/SKILL.md .claude/skills/mutantkit/SKILL.md
```

**Codex CLI**: Codex reads `AGENTS.md` automatically from the project root
(and parent directories). Fold the skill's contents in directly, or keep it
as a separate file and reference it:

```bash
mkdir -p .codex   # if you keep project-local Codex config here
cat skills/mutantkit/SKILL.md >> AGENTS.md
# or, to keep it separate and just point Codex at it:
echo "See skills/mutantkit/SKILL.md for MutantKit usage." >> AGENTS.md
```

The file itself has no Claude- or Codex-specific syntax beyond the YAML
frontmatter Claude Code's skill loader reads (`name`/`description`) — the
body is plain instructions any agent can follow, so copying it into
whichever context file your tool of choice loads (`AGENTS.md`, a custom
system prompt, an MCP resource) works the same way.

## Use

```bash
mutantkit doctor    # check the environment BEFORE writing any config
mutantkit init      # generate mutantkit.yml
mutantkit plan --output plan.json
mutantkit run --plan plan.json
```

Start with `doctor`. It tells you what kind of project you have, which schemes
and test targets it found, whether `build-for-testing` actually succeeds, and
whether the `.xctestrun` really exists — before you spend an hour finding out
otherwise.

### Shell completion

```bash
# zsh
mutantkit --generate-completion-script zsh > ~/.zsh/completions/_mutantkit  # any dir on $fpath

# bash
mutantkit --generate-completion-script bash > /usr/local/etc/bash_completion.d/mutantkit

# fish
mutantkit --generate-completion-script fish > ~/.config/fish/completions/mutantkit.fish
```

Tab-completes subcommands and flag names. Re-run after upgrading if a new
flag doesn't show up.

### Inspecting a mutant

A score is not actionable; a diff is. For any mutant:

```bash
mutantkit inspect mut_a1b2c3d4e5f6a7b8
```

shows the original and mutated source, the operator's reasoning, which tests ran,
the outcome, the exact build and test commands, the evidence, and a command to
reproduce it on its own:

```bash
mutantkit reproduce mut_a1b2c3d4e5f6a7b8
```

### CI

```bash
mutantkit plan --output plan.json
mutantkit shard plan.json --count 8       # deterministic: a mutant always lands in the same shard
mutantkit run --plan plan.3.json --output results.3.json
mutantkit merge results/*.json
```

Plans are machine-independent JSON and every mutant checkpoints on completion, so
an interrupted run resumes rather than restarting.

Run profiles follow what large-scale practice has settled on — surface a few
actionable mutants in review rather than a full report nobody reads:

| Profile   | Scope                              | Operators             |
| --------- | ---------------------------------- | --------------------- |
| PR        | changed declarations, under budget | high confidence only  |
| Nightly   | affected modules                   | default               |
| Weekly    | whole project                      | including experimental |

Diff-scoped PR runs do not replace full runs: mutants relevant to a change
routinely live outside the changed lines, which is what nightly and weekly are
for.

### Quality gate: turning a score into a merge decision

A report is not a merge decision. `mutantkit gate` is:

```bash
mutantkit gate --report report.json \
  --baseline main-report.json \
  --minimum-effective 70 \
  --regression-maximum-drop 2 \
  --new-survivors-maximum 0
```

or the same policy checked into `mutantkit.yml`, so it travels with the repo
instead of living in a CI YAML file:

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

`--minimum-tested`/`--minimum-effective`/`--maximum-survivors` are absolute
thresholds against one report. `regression`/`survived` answer a different,
usually more useful question in day-to-day CI: **did this PR make things
worse**, not just "is the number above some fixed bar." A codebase can carry a
stable, reviewed backlog of survivors and still fail CI the moment a genuinely
new one shows up — that's what `survived.newMaximum` catches, by diffing
MutationIDs against `--baseline`, not just comparing counts. Both regression
checks require `--baseline` (a prior report, typically the target branch's
last run); the gate fails closed with a clear message if they are configured
without one, rather than silently skipping the check.

`qualityGate` is checked only by `gate`, never by `plan`/`run` — changing a CI
threshold does not change what gets mutated, so it does not invalidate a plan
or a checkpoint.

### What to point MutantKit at

Mutation testing is most valuable on deterministic domain/business logic,
where a test suite is expected to fully pin down behavior. Thin boundaries to
OS/hardware — CoreAudio/HAL wrappers, `SMAppService`, other hardware or OS
service adapters, network integration shims, UI glue — are often poor
mutation targets: a unit suite frequently cannot kill a mutant there even
when the code is correct, because the behavior it changes only manifests
through the real OS/hardware, not through anything a unit test observes. A
surviving mutant in that kind of code is not necessarily "insufficient
tests" — exclude it, or read its survival as an integration-boundary finding
rather than a coverage gap:

```yaml
sources:
  exclude:
    - Sources/AudioHAL/**
    - Sources/SystemIntegration/**
```

### Suppressing one mutation

`sources.exclude` is file-level: the mutation is never even discovered. For a
single known-noisy mutant inside an otherwise-worth-mutating file, that's the
wrong granularity — MutantKit has two finer-grained options instead, both of
which keep the mutation **visible in the plan as suppressed, with a reason**,
never a silent drop:

An inline comment, right next to the code it's about — no separate file to
keep in sync as lines move:

```swift
// mutantkit:disable-next-line swift.core.relational-operator-replacement
if index < count { ... }

if index < count { ... } // mutantkit:disable-line swift.core.relational-operator-replacement
```

Omit the operator list to suppress every operator on that line. Both forms
work in any Swift file, no import or macro needed.

Or a `.mutantkitignore` file at the project root (or `--ignore-file`), for
suppressions that don't map to one line — a whole operator, a whole file
pattern, or a specific `MutationID` once you already know it from `inspect`:

```
# .mutantkitignore
id:mut_a1b2c3d4e5f6a7b8
operator:swift.core.logical-connector-replacement
file:Sources/Generated/**
line:Sources/Foo.swift:42
```

Either source produces the same audit trail: a suppressed mutant stays in
`plan.skipped` with `reason: userRequested` and a `detail` naming the exact
rule that matched, so `discovered == planned + skipped` always holds and
`mutantkit plan`'s own output reports how many were suppressed and why —
never a mutation that just quietly stopped appearing.

## Configuration

```yaml
version: 1

project:
  kind: auto                 # or swiftPackageMacOS | swiftPackageApple | xcodeProject | xcodeWorkspace
  scheme: App
  destination: platform=iOS Simulator,name=iPhone 16

sources:
  include: [Sources/**]
  exclude: ["**/Generated/**", "**/*Mock.swift"]

tests:
  targets: [AppTests]
  # Swift packages only. Off by default: SwiftPM writes the XCTest half of its
  # structured report only when tests run in parallel, so leaving this off costs
  # per-test counts (`inspect` cannot name which test caught a mutant). Outcomes
  # stay correct either way. Turning it on is a real trade: a suite that is not
  # parallel-safe flakes, and a flaky failure during a mutant's run is recorded
  # as that mutant being killed — silently inflating the score. Only enable it if
  # `swift test --parallel` already passes reliably.
  parallel: false

operators:
  profile: default           # conservative | default | experimental

execution:
  strategy: isolated
  workers: auto
  budget:
    maxMutants: 50
  # Off by default. When on, a mutant that looks killed is re-run once before
  # the verdict is trusted; if the second run does not fail the same way, it is
  # reported `flaky` and excluded from the score instead of silently inflating
  # it. Doubles the test invocation for every mutant that looks killed, which is
  # the common case in a well-tested project — real cost for a suite you already
  # suspect of flaking under `tests.parallel`.
  retestKilledMutants: false
  # Narrows each mutant's test run to only the tests that cover its mutated
  # line, measured once against the unmutated baseline. A mutant on a line no
  # test reaches is `noCoverage` without ever being built. The single largest
  # speedup available before touching incrementalBuild/testBatchSize below —
  # cached across runs against an unchanged source tree and test suite.
  selectCoveringTests: true
  # Reuses one persistent, incrementally-recompiled sandbox per worker across
  # its mutants instead of a fresh build for each — real Swift incremental
  # compilation savings on a project with more than a handful of mutants.
  incrementalBuild: true
  # Merges several mutants' test runs into one xcodebuild invocation instead
  # of one per mutant, amortizing the fixed simulator install/launch cost.
  # Requires selectCoveringTests (a batch narrows every configuration to its
  # own selection) and an Xcode project or workspace destination.
  testBatchSize: 10

timeouts:
  mutant:
    strategy: adaptive      # baseline × multiplier + overheadAllowance
    multiplier: 3
    overheadAllowance: 60s
    minimum: 30s
    maximum: 5m

reports: [console, xcode, stryker-json, html]
```

`overheadAllowance` is additive for a reason. The baseline measures a suite that
*passes*; a mutant that gets killed makes it *fail*, and failing costs extra
fixed time — xcodebuild collects diagnostics and finishes writing the result
bundle. That cost does not shrink with the suite, so on a small suite a pure
multiplier under-budgets exactly the mutants that were about to be killed,
reporting them as `timedOut` and dropping them from the score entirely. Budget
generously: a `timedOut` should mean "this mutant hangs", not "the limit was
tight", because the result cannot tell you which.

Precedence: CLI > project config > environment > defaults.

### Coming from Muter

```bash
mutantkit migrate --from-muter muter.conf.yml
```

The importer reports every field it translated, every field it dropped, and why.
It does not silently discard settings it cannot carry.

**MutantKit does not aim for behavioural compatibility with Muter, and will not
reproduce its mutation scores.** The two tools measure differently — notably,
MutantKit excludes mutants it cannot prove were applied, where Muter's score
has counted them — so expect different, and typically lower, numbers. That
difference is deliberate: see [What makes this one different](#what-makes-this-one-different).

## Reports

MutantKit emits the [Mutation Testing Elements](https://github.com/stryker-mutator/mutation-testing-elements)
schema, so its output works with the same HTML renderer and dashboards used by
Stryker, PIT and others. Its own JSON is richer than that schema — Stryker has no
vocabulary for `notApplied` or `baselineMismatch` — and the mapping documents
where information is lost rather than flattening the distinction.

Also available: console, Xcode warnings (they appear in the issue navigator),
self-contained HTML, and a markdown CI summary.

## Architecture

```
CLI
Core          MutationModel · MutationPlanner · Integrity · Configuration
SwiftFrontend Discovery · Application · SourceAnchorVerifier   (SwiftSyntax)
Execution     Workspace · ProcessSupervisor · Timeout · Checkpoint · Classifier ·
              CoverageProfileCache · MutationResultCache
AppleAdapters SwiftPM · xcodebuild · XCResult · SimulatorPool
Operators     SwiftCoreOperators · ApplePlatformOperators
Reporting     Console · Xcode · JSON · Stryker · HTML
```

Modules talk through protocols and immutable value types. There is no shared
mutable state. Operators are pure functions from syntax to candidates — they
cannot save files, build, or run tests, so an operator can never be the reason a
result is wrong.

## Roadmap

| Phase | Status | Contents |
| ----- | ------ | -------- |
| 1 · Correctness core | in progress | Plan, stable IDs, eleven core operators (see [Operators](#operators): bool literal, logical connector, relational, ternary, unary-not, return-value default-enabled; arithmetic/assignment experimental-only, 0 unviable in a real-project corpus but arithmetic showed 2 confirmed reproducible runtime hangs there; nil-coalescing experimental-only, demoted for low signal density against a real-project corpus; else-clause-deletion/range-boundary-replacement experimental-only, brand new and not yet corpus-measured), isolated execution, baseline, timeout, evidence, JSON/text reports |
| 2 · Apple integration | in progress | `.xcodeproj`, `.xcworkspace`, iOS packages, `.xcresult`, XCTest, Swift Testing, `doctor` |
| 3 · Scale | in progress | coverage-based test selection, incremental build, batched testing, historical test prioritization with early abort (wave-based batched kill on a batchable adapter, serial per-invocation otherwise), cross-run coverage and result caches, diff mode, budget, checkpoint/resume, shard/merge, warm simulator pool, APFS clone sandboxes |
| 4 · Schemata | in progress | one shared build embeds every mutation; a verifier-only trust chain (per-image build receipts, binary runtime protocol, confirmation parity with isolated mode) decides every verdict; per-operator, gated by a lowerer registry — all six default/conservative operators (`bool-literal-inversion`, `relational-operator-replacement`, `logical-connector-replacement`, `unary-not-removal`, `return-value-replacement`, `ternary-branch-swap`) are embeddable today, each promoted only after its own zero-disagreement isolated-vs-schemata differential proof on real projects (the first two operators' own formal measurement, +3–8% wall-time over isolated mode, is in [Benchmarks](Benchmarks/results/ror-schemata-performance/report.md); later promotions carried the same correctness gate, not necessarily the same speedup — see each operator's own promotion history), every other (experimental-only) operator automatically falls back to isolated mode |
| 5 · Apple operators | **blocked on research** | lifecycle, cancellation, continuation, persistence, SwiftUI, accessibility |

Phase 5 is blocked deliberately. Apple-specific operators must be derived from a
classified corpus of real bug-fix commits in shipping open-source apps — the
method MDroid+ used for Android — not from plausible-sounding guesses. Until that
study exists, `ApplePlatformOperators` contains one operator,
`LifecycleSuperCallRemovalOperator`, purely as a demonstration of the
extension point — it is not registered, has no RED tests, and is not
reachable from the CLI by any profile or `operators.enable` entry. See
`Research/fault-taxonomy/` and the operator's own doc comment.

### Not in v0.1

UI tests · on-device runs · external binary plugins · LLVM IR mutation · LLM
generated mutations · automatic equivalent mutant detection · exhaustive Swift
syntax coverage · Muter score parity · arbitrary runners (Fastlane, Buck).

## Contributing

### Tests

```bash
swift test                            # unit, regression, integrity — under a second
MUTANTKIT_ACCEPTANCE=1 swift test        # + the fixtures, built and mutated for real
```

The acceptance suites plan and run the real binary against the projects in
`Fixtures/`, and assert the exact mutants expected to live and die rather than a
score — a score is one number that many different wrong runs can agree on. They
are off by default because they take minutes; CI runs them on every push.

They are not optional rigour. Every wiring bug this project has had was invisible
to the unit tests and produced a confident, wrong number: a sandbox handed
source-file globs where it wanted workspace excludes, `xcodebuild` pointed at the
original sources while the mutated copy sat unread beside it, concurrent mutants
fighting over one simulator. If you touch the execution path, run them.

Add `MUTANTKIT_ACCEPTANCE_SIMULATOR=0` to skip the suites needing a simulator.

### Operators

An operator earns `defaultEnabled` by evidence, not by being interesting:

- it corresponds to a documented real fault pattern
- it has positive **and** negative syntax fixtures
- ≥99% compile success rate
- zero phantom mutants
- few trivial or duplicate mutants
- isolated and schemata execution agree
- validated on multiple real projects
- its diff is understandable to the developer who has to act on it

| Operator | Profile | Confidence | Notes |
| --- | --- | --- | --- |
| `swift.core.bool-literal-inversion` | conservative | high | `true` ↔ `false` |
| `swift.core.relational-operator-replacement` | conservative | high | boundary shift + negation, e.g. `<` → `<=`, `>=` |
| `swift.core.logical-connector-replacement` | conservative | high | `&&` ↔ `\|\|` |
| `swift.core.ternary-branch-swap` | conservative — **provisional** | high | `a ? b : c` → `a ? c : b`; preserves comments/trivia around the condition and both branches. Always compile-viable, but a targeted single-operator corpus run against a real project (50 mutants, 0 unviable) measured only a **13.3%** kill rate on buildable mutants — in the same low range that got nil-coalescing-fallback demoted. Not yet demoted here because this is one project's data, not a confirmed pattern; see the operator catalog for the open question |
| `swift.core.unary-not-removal` | default — **provisional** | medium | `!x` → `x`; never assumes a multi-`!` token (`!!x`) is stacked built-in negation, since it could be a user-defined operator. A targeted corpus run against a real project (50 mutants, 0 unviable) measured a healthy **40.0%** kill rate — no signal-density concern found so far |
| `swift.core.return-value-replacement` | default — **provisional** | medium | restricted to explicit `return`s whose neutral replacement the syntax alone proves safe; excludes equivalent spellings (`0x0`, `nil as T?`, `Optional<T>.none`, an empty raw string, ...) by value/structure, not text comparison. Measured at **29.4%** kill rate in the same real-project corpus run, 0 unviable |
| `swift.core.nil-coalescing-fallback` | **experimental** | medium | `a ?? b` → `b`; a surviving mutant means the suite never proved a non-nil left-hand value is preferred over the fallback, not that the nil path is untested. Always compile-viable, but a real-project corpus run showed it alone occupying half a 100-mutant sample with **8.3%** kill rate on buildable mutants, mostly re-stating the same low-value "defensive `?? fallback`, never tested against a non-nil value" gap — demoted for signal density, not compile safety |
| `swift.core.arithmetic-operator-replacement` | **experimental** | medium | `+` ↔ `-`, `*` ↔ `/`; no symbol resolution, and Swift's arithmetic protocols do not guarantee a matched pair (`Numeric` has no `/`) — confirmed to produce real compile failures against representative fixtures. A targeted 50-mutant corpus run against a real project measured 0 unviable (this codebase's arithmetic usage didn't happen to hit those patterns — not evidence the fixture risk is false). The same run originally reported a much larger flaky/infrastructure-failure count than any other operator; most of that turned out to be a batch-timeout attribution bug, since fixed — **2 genuine, reproducible hangs remain**, clustered in loop/index-arithmetic code |
| `swift.core.assignment-operator-replacement` | **experimental** | medium | `+=` ↔ `-=`, `*=` ↔ `/=`; same compile-viability gap as arithmetic replacement one syntactic level up. A targeted 50-mutant corpus run against a real project measured 0 unviable and a healthy 37.5% kill rate, without arithmetic's instability pattern (1/50 flaky, no timeouts) |
| `swift.core.else-clause-deletion` | **experimental** | experimental | `if a { X } else { Y }` → `if a { X }`; only the trailing `else`/`else if` clause is ever removed, never the `if` branch or the condition, and discovery skips sites where deleting `else` would break Swift's exhaustiveness rules for an `if`/`switch` expression or the last statement of a non-`Void` body. Brand new — no Muter analogue and no real-project corpus measurement yet |
| `swift.core.range-boundary-replacement` | **experimental** | experimental | `a..<b` ↔ `a...b`; covers only the binary infix form. Not proven safe to compile (the two forms produce different concrete range types) or safe to run (`..<` → `...` can turn a valid upper-bound-exclusive index into an out-of-bounds access) by default. Brand new — no real-project corpus measurement yet |

"**provisional**" above means: corpus-measured against real projects, but not
yet against the additional project shapes this catalog's own
default-promotion bar calls for (see `Research/operator-catalog/README.md`
§ "Quality gate for every operator"). Ternary-branch-swap, unary-not-removal
and return-value-replacement have now each been corpus-measured on **two**
real projects — a second project's run reproduced the first project's
overall pattern for all three, and ternary-branch-swap's low kill rate in
particular held up on the second project too, mirroring the pattern that
got nil-coalescing-fallback demoted; this is flagged as an open decision
rather than resolved here. Assignment-operator-replacement has been
corpus-measured on only one real project so far. Else-clause-deletion and
range-boundary-replacement are new and have not yet been corpus-measured on
any project. Full methodology and results (internal, not part of this
public repo): `Research/corpus-validation/`.

Arithmetic, assignment, else-clause-deletion and range-boundary-replacement
are reachable via the `experimental` profile or an explicit
`operators.enable` entry, not by default — see
`Research/operator-catalog/README.md` for the measured compile-viability
evidence and what promoting them to default would require. Nil-coalescing
fallback is reachable the same way, for a different reason: see
`Research/operator-catalog/README.md` for the corpus signal-density
evidence — a second real project's measurement did not reproduce the first
project's low kill rate, an unresolved discrepancy, not a reversal of the
demotion — and what re-promoting it would require.

## Licence

Apache 2.0. See [LICENSE](LICENSE), [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES),
and [SECURITY.md](SECURITY.md).
