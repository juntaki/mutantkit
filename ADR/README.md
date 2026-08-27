# Architecture Decision Records

Numbered `NNNN-slug.md` files, oldest first. An ADR captures a decision
and the reasoning behind it at the time it was made — including the
measurements, spikes, and evidence that justified it. Once accepted, an
ADR is not deleted or rewritten when new evidence changes the picture;
it is corrected in place, in a way that preserves what the original
decision looked like and why, alongside what is now known.

## Correcting a measurement-based ADR (or Research doc) conclusion

This applies whenever new evidence contradicts, narrows, or overturns a
conclusion an ADR previously stated as settled — a benchmark number, a
"this can't happen" claim, a root-cause attribution, a dismissed
anomaly later found to be real. It applies equally to `ADR/` and to
investigation write-ups under `Research/` (see that program's own
cross-cutting rule R6, which this convention formalizes).

**Never silently edit the original claim out of the historical
record.** A wrong conclusion that was reached in good faith from the
evidence available at the time is useful history — it shows what was
tried, what looked right, and what the eventual falsifier was. Erasing
it loses that.

Instead, add a dated correction:

```
1. Do not remove the original text from history.
2. Add a dated "**Correction YYYY-MM-DD:**" note (inline, immediately
   after the claim it corrects, for a narrow spec/derivation fix; or as
   its own new section near the end of the document, for a broader
   conclusion reversal).
3. State what was wrong.
4. State what was newly observed (the falsifier).
5. State the narrowest claim that now holds — don't over-correct into a
   new claim the new evidence doesn't actually support either.
6. Link the evidence: a commit, a CI run, a reproduction script, a
   stack sample — whatever made the correction possible, so the next
   reader can check it rather than take the correction on faith.
```

Two real precedents already follow this shape, before it was written
down here:

- `ADR/0007-budget-selection-v2-discovery-and-spec.md` — several inline
  `**Correction**:`/`**Overflow-safety (... correcting the bound's own
  derivation)**` notes fixing a spec derivation in place, keeping the
  original (now-corrected) reasoning visible alongside the fix.
- `Research/mutation-testing-hardening-2026-08/PROGRESS.md` — a
  `**Correction 2026-08-27 (R6):**` section reversing an earlier "likely
  a red herring" dismissal of a `Process.waitUntilExit()` hang, once a
  second, independent live stack sample showed it was real; and a
  second, distinct correction the same day reversing an assumption
  about which layer (CI's own stall-detector threshold vs. test/product
  code) was actually at fault. Both link directly to the commit/CI
  evidence that forced the correction.

### For investigation-heavy write-ups: prefer a Hypothesis / Evidence / Falsifier / Status table

When a document is chasing down a real bug rather than recording a
single decision, a running table keeps the correction discipline
lightweight instead of requiring a full prose correction section every
time the leading theory changes:

| Hypothesis | Evidence for | Falsifier | Status |
|---|---|---|---|
| e.g. CLOEXEC leak causes the CI hang | fixed, shipped, plausible mechanism | live stack sample under a real hang showed a different frame | superseded — see below |
| `blocking()`'s cooperative-pool deadlock | live stack sample, reproduced twice | — | confirmed root cause |

This is the same discipline as the six-step convention above, just
shaped for a live investigation instead of a closed decision: nothing
gets deleted when a hypothesis is superseded, it gets marked as such
with the evidence that superseded it.

## Numbering

New ADRs get the next sequential number. Don't renumber existing ADRs
when one is superseded — supersession is itself recorded as a
correction (per above) in the superseded ADR, pointing forward to the
one that replaces it, not by deleting or renumbering the old file.
