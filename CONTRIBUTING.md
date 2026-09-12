# Contributing

## How to propose a change

Changes are proposed through GitHub pull requests. Fork the repository,
push a topic branch, and open a PR against `main` — `merge-gate`
(`.github/workflows/ci.yml`) must pass before it can be merged.

## Acceptance requirements

Major new functionality and bug fixes must include appropriate automated
tests: a unit test for isolated logic, an acceptance test (see below) for
anything on the execution path, and a regression test for a fixed bug —
the same standard this project holds its own history to (see `Tests/
MutantKitTests/Regression/` for examples of turning a one-time audit
finding into a permanent, mechanical check).

Before opening a PR: run `swift test`. If your change touches the
execution path — building, running, or classifying a mutant, not just
planning or reporting one — also run `MUTANTKIT_ACCEPTANCE=1 swift test`
(see below for what that covers and why it isn't optional there). New
SwiftLint/SwiftFormat violations must not be introduced — `merge-gate`'s
`Lint & format` job runs the same checks and blocks the PR on a new one.

## Tests

```bash
swift test                            # unit, regression, integrity — under a second
MUTANTKIT_ACCEPTANCE=1 swift test        # + the fixtures, built and mutated for real
```

The acceptance suites plan and run the real binary against the projects in
`Fixtures/`, and assert the exact mutants expected to live and die rather
than a score — a score is one number that many different wrong runs can
agree on. They are off by default because they take minutes; CI runs them
on every push.

They are not optional rigour. Every wiring bug this project has had was
invisible to the unit tests and produced a confident, wrong number: a
sandbox handed source-file globs where it wanted workspace excludes,
`xcodebuild` pointed at the original sources while the mutated copy sat
unread beside it, concurrent mutants fighting over one simulator. If you
touch the execution path, run them.

Add `MUTANTKIT_ACCEPTANCE_SIMULATOR=0` to skip the suites needing a
simulator.

See `docs/apple-support-matrix.md` for the real, stated support contract
across Swift/Xcode/macOS versions, project kind, test framework, iOS
Simulator, and `isolated`/`schemata` mode — separated into supported,
tested, best-effort, and unsupported, each backed by a citation.

Schemata execution (`execution.strategy: schemata`) links a small C runtime
(`MutantKitSchemataRuntime`) into the project under test. A released
`mutantkit` binary resolves this on its own — it bundles both the macOS and
iOS-Simulator archives under `lib/mutantkit/schemata/` next to itself, no
extra setup required (see `docs/schemata-support-matrix.md`). For running
the acceptance suite from a source checkout, though, `swift test` itself
has no bundled runtime to fall back on, so point
`MUTANTKIT_SCHEMATA_RUNTIME_LIB_OVERRIDE` at the directory `swift build
--build-tests` puts `libMutantKitSchemataRuntime.a` in (e.g.
`.build/arm64-apple-macosx/debug`). For an Xcode/iOS-Simulator project
specifically, that directory also needs an `iphonesimulator/`
subdirectory — `swift build` never produces one (it only builds for the
host, macOS), so run `scripts/build-schemata-runtime.sh` once first.

## Operators

See [docs/operators.md](docs/operators.md) for the full catalog, promotion
criteria, and corpus-validation status of every operator, plus the schemata
per-operator promotion gate.

## Architecture

```
CLI
Core               MutationModel · MutationPlanner · Integrity · Configuration
SwiftFrontend      Discovery · Application · SourceAnchorVerifier   (SwiftSyntax)
Execution          Workspace · ProcessSupervisor · Timeout · Checkpoint · Classifier ·
                   CoverageProfileCache · MutationResultCache
AppleBuildAdapters SwiftPM · xcodebuild · XCResult · SimulatorPool
Operators          SwiftCoreOperators · ApplePlatformOperators
Reporting          Console · Xcode · JSON · Stryker · HTML · Sonar · GitHub Actions
```

A simplified sketch, grouped by responsibility rather than a literal
listing of `Sources/` directories — it omits internal tooling that supports
development but sits outside the pipeline a mutation run itself executes
(the benchmark harness, the Muter-config importer, standalone measurement
probes).

Modules talk through protocols and immutable value types. There is no
shared mutable state. Operators are pure functions from syntax to
candidates: they cannot save files, build, or run tests, nor mutate runner
state or affect execution outside the candidate they produce — a wrong
result can never trace back to an operator reaching outside its own inputs.
(This does not mean every operator-produced candidate is itself high-value
or even always valid; equivalent mutants, invalid transformations, and
low-signal mutants are real and are evaluated separately — see
[Operators](docs/operators.md) for how each one earns its profile and
confidence rating.)

## Roadmap

See [GitHub Issues](https://github.com/juntaki/mutantkit/issues) for
in-progress and planned work. [What's not yet implemented](README.md#supported-today)
in the README lists the current scope boundary.
