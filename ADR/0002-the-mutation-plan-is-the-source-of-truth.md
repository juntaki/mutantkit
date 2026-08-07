# ADR-0002: The Mutation Plan is the source of truth

- **Status:** Accepted
- **Date:** 2026-07-17

## Context

A mutation testing tool has to answer "what is a mutation?" before anything else.
The answer determines whether the tool can be correct.

Answering "a mutation is a node in a syntax tree" makes the mutation a reference
into a data structure that is expensive to keep, impossible to serialize, and
invalidated by re-parsing. Every downstream capability then fights the model:
sharding needs it serialized, resuming needs it to survive a process exit,
`reproduce` needs it to survive a week, and bounded memory needs the tree gone.

## Decision

**A mutation is a value, not a reference.** The Mutation Plan — plain JSON — is
the only source of truth. Discovery produces a plan and writes nothing else.
Execution reads the plan and works only from what it says.

A mutation is anchored by **UTF-8 byte range plus content**, never by node
identity:

```
utf8Range + originalText + sourceFileHash
          + prefixTokenFingerprint + suffixTokenFingerprint
          + enclosingDeclaration + expectedSyntaxKind
```

Applying a mutation is a byte splice. No `SyntaxRewriter`, no node lookup, no
tree edit.

The Mutation ID is derived from content, never from position in a traversal:

```
relative file path + enclosing declaration identity + operator ID
  + operator version + original token fingerprint + local occurrence index
```

## Consequences

### Re-parsing becomes safe

This is the point. Re-parsing was fatal to node identity; it is harmless to
content. A fresh parse of identical bytes necessarily re-derives identical
fingerprints, because the fingerprints are functions of the bytes. So discovery
can release every tree the moment it has copied the facts out, and memory stays
bounded by file size rather than by project size — while the results stay
correct. The conflict in ADR-0001 dissolves rather than being traded away.

### A stale anchor is a diagnosis, not a corruption

If the file changed, the hash mismatches and the mutation is reported
`notApplied` with a precise reason. It is **never** relocated to a nearby offset
by guesswork, and never silently counted as `survived`. Guessing is what produces
invalid Swift and mutations of the wrong expression.

### IDs are stable under things that should not matter

Parallel discovery, shard boundaries, machine identity, and edits to unrelated
declarations all leave IDs untouched — the ID's inputs mention none of them.
Scoping occurrence index to the *enclosing declaration* rather than the file is
what buys the last one: adding a function at the top of a file would renumber
every mutation below it under a file-wide counter.

IDs deliberately *do* change when the operator version changes, when the
declaration is renamed, or when the mutated text changes. Those are different
mutations, and a stale cache hit on them would be a wrong answer.

### The ID is verifiable

Every ID input is stored on the `MutationPoint` that carries it, so `verify`
recomputes each ID from its own components. A plan whose IDs do not reproduce is
rejected before a single build runs — not after an hour of them.

### Costs we accept

- One re-parse per application, to re-check the anchor in full. Milliseconds
  against a build measured in seconds. Correctness first.
- Plans are large. They compress well and they are the artifact that makes
  sharding, resume, and reproduction possible at all.
- Byte offsets demand care with multi-byte characters. This is covered by tests
  rather than by hoping.
