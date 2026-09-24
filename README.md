<img src="assets/logo.png" alt="MutantKit logo" width="96">

# MutantKit

[English](README.md) | [日本語](README.ja.md)

[![CI](https://github.com/juntaki/mutantkit/actions/workflows/ci.yml/badge.svg)](https://github.com/juntaki/mutantkit/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/juntaki/mutantkit/graph/badge.svg)](https://codecov.io/gh/juntaki/mutantkit)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=juntaki_mutantkit&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=juntaki_mutantkit)
[![CodeQL](https://github.com/juntaki/mutantkit/actions/workflows/codeql.yml/badge.svg)](https://github.com/juntaki/mutantkit/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/juntaki/mutantkit/badge)](https://securityscorecards.dev/viewer/?uri=github.com/juntaki/mutantkit)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14602/badge)](https://www.bestpractices.dev/projects/14602)
[![GitHub release](https://img.shields.io/github/v/release/juntaki/mutantkit)](https://github.com/juntaki/mutantkit/releases)
[![License](https://img.shields.io/github/license/juntaki/mutantkit)](LICENSE)

**Mutation testing for Swift and Apple platforms that scores only mutations it can prove were actually applied and exercised.**

MutantKit introduces small changes (mutants) into your code and checks whether your tests can detect them. It confirms a mutation actually reached the compiled binary and that the mutated code was executed before scoring the result.

## Getting started

### Requirements

* macOS 14+
* Apple Silicon Mac
* Swift 6.0+
* A SwiftPM package, or an Xcode project / workspace
* A working test suite

### Using the CLI directly

Install MutantKit.

```bash
brew install juntaki/mutantkit/mutantkit
```

From your project's root directory, run:

```bash
mutantkit setup
mutantkit dry-run
mutantkit plan --output plan.json
mutantkit run --plan plan.json
```

What each command does:

| Command             | What it does                                                     |
| -------------------- | ----------------------------------------------------------------- |
| `mutantkit setup`   | Detects your project, scheme, and test targets, and writes a config file |
| `mutantkit dry-run` | Confirms a normal build/test succeeds, without applying any mutation |
| `mutantkit plan`    | Builds the list of mutations to apply                              |
| `mutantkit run`     | Applies mutations and checks whether tests detect them             |

To make CI fail on survivors, add `--fail-on-survivors`:

```bash
mutantkit run --plan plan.json --fail-on-survivors
```

### Letting Claude Code drive it

Install MutantKit and its Claude Code plugin.

```bash
brew install juntaki/mutantkit/mutantkit

claude plugin marketplace add juntaki/mutantkit
claude plugin install mutantkit@mutantkit
```

Start Claude Code at the root of the target project.

```bash
claude
```

Then just ask, for example:

```text
Set up MutantKit for this project. Check the environment with setup and
dry-run first, run with a small mutation budget, confirm integrity, and
then analyze the survivors.
```

The MutantKit skill bundled with the plugin walks the agent through
`setup → dry-run → plan → run`, checking integrity, analyzing survivors,
and reproducing individual mutants.

To update the plugin:

```bash
claude plugin marketplace update mutantkit
claude plugin update mutantkit
```

### Letting Codex drive it

Install MutantKit and its Codex plugin.

```bash
brew install juntaki/mutantkit/mutantkit

codex plugin marketplace add juntaki/mutantkit
codex plugin add mutantkit@mutantkit
```

Start Codex at the root of the target project.

```bash
codex
```

You can ask it the same way, for example:

```text
Set up MutantKit for this project. Check the environment with setup and
dry-run first, run with a small mutation budget, confirm integrity, and
then analyze the survivors.
```

The Claude Code and Codex plugins both point at the same
`skills/mutantkit/SKILL.md`.

See [docs/agents.md](docs/agents.md) for more on agent integration and manual setup.

### What to check after a run

Once a run finishes, each mutation gets one of the following results:

| Result                   | Meaning                                                      |
| ------------------------- | ------------------------------------------------------------- |
| `killed`                | A test detected the change the mutation made                  |
| `survived`              | Code reached the mutation, but every test still passed          |
| `noCoverage`            | No test ever executed the mutated code                          |
| `notApplied`            | The mutation could not be safely applied                        |
| `baselineMismatch`      | What ran does not match the verified baseline                   |
| `infrastructureFailure` | The execution environment itself had a problem                  |

`survived` may mean your tests are too weak to catch that mutation. `noCoverage` means the mutated code was never exercised by any test at all.

To dig into a specific result, use its mutation ID:

```bash
mutantkit inspect mut_a1b2c3d4e5f6a7b8
mutantkit reproduce mut_a1b2c3d4e5f6a7b8
```

`inspect` shows the source diff, the operator, which tests ran, the outcome, the exact command, and the evidence. `reproduce` re-runs just that one mutation.

## Why another mutation testing tool?

In mutation testing, a mutation can be applied to the source but never reach the compiled binary, and infrastructure failures — a stale build, a crashed Simulator — can get treated as test results.

MutantKit verifies both that a mutation was applied and that it was executed. It never guesses at `killed` or `survived` for a mutant it cannot confirm — it fails closed instead.

* Compares compiled code against the baseline to confirm a mutation actually reached what ran
* Uses coverage to separate mutations that were actually executed from ones that were never reached
* Never folds a result it cannot reconcile with its evidence into the ordinary score

> **v1.0.3 (latest release).** SwiftPM and Xcode projects, isolated and schemata execution, CI gating, coverage-based test selection, caching, sharding, and resumable runs. Six operators are enabled by default; more are added as they clear validation — see [Operators](docs/operators.md) and [Supported today](#supported-today) below.

## Reading the results

**Tested**

```text
killed / (killed + survived)
```

The detection rate against mutations that were actually tested.

**Effective**

```text
killed / (killed + survived + noCoverage)
```

The detection rate across the whole suite, including coverage gaps.

`notApplied`, `baselineMismatch`, and `infrastructureFailure` are never folded into the ordinary mutation score — they're reported as a separate class of problem.

## Key features

* **Verified mutation activation** — confirms a mutation actually reached the binary under test
* **Fail-closed integrity model** — never scores a result it cannot prove
* **SwiftPM / Xcode support** — works with Swift packages and Xcode projects/workspaces
* **Coverage-based test selection** — narrows to tests relevant to each mutation
* **Resumable / shardable runs** — split and resume via plans, checkpoints, and sharding
* **Actionable survivors** — diffs, reproduction commands, and fix candidates
* **Coding agent integration** — drivable from Claude Code / Codex via a skill
* **CI quality gates** — checks score, regression, and new survivors in CI

## Supported today

| Area | Status |
| --- | --- |
| SwiftPM (macOS) | Supported |
| SwiftPM (Apple platforms) | Supported |
| Xcode project / workspace | Supported |
| iOS Simulator | Supported |
| Isolated execution | Supported |
| Schemata execution | Supported for specific operators/project kinds |
| XCUITest | Supported for Xcode + iOS Simulator + isolated mode |
| Physical devices | Unsupported for schemata; untested for isolated |
| tvOS / watchOS / visionOS | Isolated: best-effort. Schemata: unsupported |
| Apple-specific mutation operators | Some validated opt-in, some experimental |

See [docs/apple-support-matrix.md](docs/apple-support-matrix.md) for the full, citation-backed contract (including isolated/schemata execution-time comparisons).

## Install

### Homebrew

```bash
brew install juntaki/mutantkit/mutantkit
```

Installs a prebuilt binary for macOS 14+ on Apple Silicon.

### Using a release binary directly

```bash
curl -LO https://github.com/juntaki/mutantkit/releases/latest/download/mutantkit-macos-arm64.tar.gz
curl -LO https://github.com/juntaki/mutantkit/releases/latest/download/SHA256SUMS
shasum -a 256 -c SHA256SUMS
tar xzf mutantkit-macos-arm64.tar.gz
```

### Building from source

Requires Swift 6.0+.

```bash
git clone https://github.com/juntaki/mutantkit.git
cd mutantkit
swift build -c release
```

The binary is produced at `.build/release/mutantkit`.

### Upgrading / uninstalling

```bash
brew upgrade mutantkit
brew uninstall mutantkit
mutantkit --version
```

## Basic workflow

```text
setup → dry-run → plan → run
```

### Set up your project

```bash
mutantkit setup
```

Detects the project kind, scheme, and test targets, and writes `mutantkit.yml`.

To check your configuration:

```bash
mutantkit doctor
```

If `setup` cannot auto-detect a scheme or test target, edit the generated `mutantkit.yml` by hand and re-run `doctor`.

### Confirm the baseline

```bash
mutantkit dry-run
```

Builds and tests the unmutated project with the same settings a real run will use.

### Build a mutation plan

```bash
mutantkit plan --output plan.json
```

A Mutation Plan is a JSON file listing the mutations to run. It can be reused for a later re-run, or split across multiple workers.

### Run

```bash
mutantkit run --plan plan.json
```

To fail the command when a survivor exists:

```bash
mutantkit run --plan plan.json --fail-on-survivors
```

## Coding agents

The Quick Start plugins let an agent drive MutantKit and interpret the results for you.

The skill lives in one file, used as the single source of truth by both Claude Code and Codex:

```text
skills/mutantkit/SKILL.md
```

For an agent, this defines a workflow beyond just running `run`:

```text
setup
↓
dry-run
↓
small-budget run
↓
check trust / integrity
↓
analyze survivors
↓
inspect / reproduce
↓
fix-plan / next
```

An agent analyzing an existing report can also use these commands instead of just the raw score:

```bash
mutantkit trust --report report.json
mutantkit survivors --report report.json
mutantkit fix-plan --report report.json --format agent
mutantkit next --report report.json --format agent
```

See [docs/agents.md](docs/agents.md) for installing the skill manually, without the plugin, into Claude Code or `AGENTS.md`.

## CI

### GitHub Actions

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0

- uses: juntaki/mutantkit@<release-tag>
  with:
    mode: ci
    diff: origin/main
```

`mode: ci` runs `doctor → plan → run → gate`. Policy is managed in `mutantkit.yml`.

### Using another CI system

```bash
mutantkit plan --output plan.json
mutantkit shard plan.json --count 8
mutantkit run --plan plan.3.json --output results.3.json --no-history
mutantkit merge results/*.json
```

Checkpoints let an interrupted run resume.

### Quality gate

```bash
mutantkit gate --report report.json \
  --baseline main-report.json \
  --minimum-effective 70 \
  --regression-maximum-drop 2 \
  --new-survivors-maximum 0
```

You can gate a merge on more than a score threshold — regression against a baseline, and new survivors, too.

## Investigating and fixing survivors

To inspect an individual survivor:

```bash
mutantkit inspect mut_a1b2c3d4e5f6a7b8
mutantkit reproduce mut_a1b2c3d4e5f6a7b8
```

To inspect a whole report:

```bash
mutantkit trust --report report.json
mutantkit survivors --report report.json
mutantkit fix-plan --report report.json
mutantkit next --report report.json
```

Use `--format agent` for coding-agent-oriented output:

```bash
mutantkit fix-plan --report report.json --format agent
mutantkit next --report report.json --format agent
```

## How it works, and the trust model

* Compares the compiled code after mutation against the baseline to verify activation.
* Uses the Mutation Plan as the source of truth, keeping identity stable across sharding, resume, and reproduction.
* Never guesses at a nearby offset for stale source — an unresolvable mutation becomes `notApplied`.
* Uses `.xcresult` on Xcode, and process status plus a structured xUnit report on SwiftPM/macOS.
* Owns the timeout, and reclaims the process group and every traceable descendant process.
* Never folds a result it cannot reconcile with its evidence into the ordinary score.

## Choosing what to target

Mutation testing works best on deterministic domain/business logic where unit tests can pin down behavior precisely.

Thin boundaries to the OS or hardware, UI glue, and integration shims are often better excluded:

```yaml
sources:
  exclude:
    - Sources/AudioHAL/**
    - Sources/SystemIntegration/**
```

## Suppressing a specific mutation

```swift
// mutantkit:disable-next-line swift.core.relational-operator-replacement
if index < count { ... }

if index < count { ... } // mutantkit:disable-line swift.core.relational-operator-replacement
```

Or use a `.mutantkitignore` file:

```text
id:mut_a1b2c3d4e5f6a7b8
operator:swift.core.logical-connector-replacement
file:Sources/Generated/**
line:Sources/Foo.swift:42
```

A suppressed mutant stays in `plan.skipped` with a reason:

```text
discovered == planned + skipped
```

## Reports and integrations

Output formats include Mutation Testing Elements, self-contained HTML, a Markdown CI summary, GitHub Actions annotations, Sonar generic issues, and SARIF 2.1.0.

## Documentation

* [Evidence model](docs/evidence-model.md)
* [Operators](docs/operators.md)
* [CI](docs/ci.md)
* [Apple support matrix](docs/apple-support-matrix.md)
* [Agents](docs/agents.md)
* [ADR-0002](ADR/0002-the-mutation-plan-is-the-source-of-truth.md)

## Contributing

* [Report a bug or request an enhancement](https://github.com/juntaki/mutantkit/issues)
* [Contributing guide](CONTRIBUTING.md)
* Security vulnerabilities: see [SECURITY.md](SECURITY.md) rather than a public issue

## Licence

Apache 2.0. See [LICENSE](LICENSE), [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES), and [SECURITY.md](SECURITY.md).
