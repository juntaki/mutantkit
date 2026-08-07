# ADR-0001: Independent implementation rather than a Muter fork

- **Status:** Accepted
- **Date:** 2026-07-17

## Context

Muter is the established Swift mutation testing tool, is MIT licensed, and has
years of accumulated knowledge about Xcode and SwiftPM integration that would be
expensive to rediscover. Forking it is the obvious move.

Muter's architecture holds SwiftSyntax node identity from its discovery pass and
uses that identity to map mutations onto the tree again at apply time, re-parsing
the source in between to keep memory bounded on large codebases. Node identity
does not survive a re-parse, so the two passes work against different trees by
construction.

We considered this class of design and decided against it: an architecture where
a later pass depends on node identity established by an earlier, since-invalidated
parse ties correctness to memory strategy in a way we did not want to inherit.

## Decision

Start a new repository. Do not fork.

Treat Muter as a reference asset under its MIT licence:

- its issue history, as a corpus of failure modes to encode as regression tests
- its `muter.conf.yml` schema, as the input to a migration importer
- its Xcode/SPM integration knowledge, as prior art to learn from
- its code, as MIT-licensed material we may vendor with attribution if useful

Explicitly do **not** carry over: node-identity-based mutation mapping, large
shared mutable state, or regex-over-stdout result classification.

Behavioural compatibility with Muter is a non-goal, and reproducing Muter's
mutation scores is a non-goal. Our mutations are anchored to byte ranges and
verified against the actual compiled artifact (ADR-0002) — a different
correctness model, not a superset or subset of Muter's.

## Consequences

**We accept:** rediscovering some Xcode integration knowledge the hard way; no
existing user base on day one; the migration importer is a compatibility surface
we now own.

**We get:** the freedom to make the data model the primary design decision rather
than something inherited. Specifically, mutations become plain serializable
values anchored to byte ranges (ADR-0002), so discovery can drop every AST it
parses precisely because nothing downstream refers to a node.

**We must prove this was worth it**, not assert it. The claim is falsifiable:
every reported mutant carries a source diff, and a run whose invariants do not
reconcile produces no score at all.
