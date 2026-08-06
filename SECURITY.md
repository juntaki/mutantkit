# Security

MutantKit reads your source, rewrites copies of it, and runs your build and test
commands. That is a lot of trust. This document states what the tool guarantees,
so that the guarantees can be tested rather than assumed.

## Reporting a vulnerability

Open a private security advisory on the repository. Please do not open a public
issue for anything exploitable.

## Guarantees

### MutantKit itself does not transmit source code

MutantKit makes no network requests during `plan`, `run`, `verify`, `inspect` or
`reproduce`. It has no telemetry, no crash reporting, and no update check. There
is no opt-out because there is nothing to opt out of.

This is a guarantee about MutantKit's own code, not about your project's build:
see the threat model below — a build script it invokes can still make network
requests on its own.

The HTML report is a single self-contained file with no external assets — no
CDN, no web font, no analytics — so opening a report cannot leak the source it
displays.

### No shell interpretation, ever

Every subprocess is launched through `ProcessSupervisor`, which calls
`posix_spawn` with an argument array. No command is ever assembled by
concatenating strings, and `/bin/sh -c` is never used.

This matters because scheme names, destinations, file paths and test target
names all come from user configuration and all flow into build commands. Under
string concatenation, a scheme named `App; rm -rf ~` would be a command
injection. Under an argument array it is a scheme name that does not exist.

Contributors: if you find yourself building a command string, that is a bug, not
a shortcut.

### Nothing outside the sandbox is deleted

Mutation requires rewriting source, so MutantKit works exclusively on sandbox
copies and never edits your working tree.

Before any deletion, the target path is canonicalized — symlinks resolved, `..`
collapsed — and verified to lie inside MutantKit's own scratch root. A path that
does not is refused rather than cleaned. This is checked against the resolved
path, not the requested one, so a symlink inside the sandbox cannot be used to
reach outside it.

### Secrets are redacted

Environment variables are not logged wholesale. Values matching common
credential shapes (tokens, keys, signing identities, CI secrets) are redacted
from captured build and test output before it reaches a report, an evidence
record, or a diagnosis string.

Evidence records contain source diffs and command lines. Treat a MutantKit report
with the same care as the source it was generated from — it contains excerpts of
that source by design.

## Release integrity

Each release embeds its tool version, commit SHA, Swift version, SwiftSyntax
version, Xcode version, plan schema version and report schema version. `mutantkit
--version` prints them, and every plan and report records them, so an artifact
can always be traced to the toolchain that produced it.

Signed releases and an SBOM are planned but not yet implemented for v0.1. Until
then, verify a release by its embedded commit SHA and toolchain versions, or
build from source at a tagged commit.

## Threat model — what is *not* guaranteed

MutantKit runs your project's build and test commands. Those commands can do
anything your user account can do. MutantKit does not sandbox them, and cannot:
a build script that exfiltrates data will still exfiltrate data when run under
MutantKit.

**Do not run MutantKit against a repository you would not already run `swift build`
or `xcodebuild` against.** Cloning an untrusted repository and running MutantKit on
it is equivalent to executing that repository's code.
