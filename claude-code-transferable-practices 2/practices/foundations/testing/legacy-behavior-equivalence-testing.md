---
title: "Legacy Behavior Equivalence Testing"
status: verified
kind: pattern
basis: evidence
scope: cross-stack-legacy-systems
stacks: []
versions: []
tags:
  - legacy
  - refactoring
  - equivalence-testing
  - regression-safety
source-projects:
  - internal-project-docs
created: 2026-07-11
updated: 2026-07-11
last-verified: 2026-07-11
supersedes: []
---

# Legacy Behavior Equivalence Testing

## Context

Performance and structural refactors frequently preserve types and pass unit
tests while changing ordering, fallback behavior, implicit filtering, permission
semantics, formatting, or side effects. Legacy systems often encode these
contracts in real data and framework behavior rather than explicit types.

## Rule

For an equivalent legacy refactor, run the old and new implementations against
the same production-shaped local data and require equal observable output.

Use real application code, not a SQL or mock reimplementation. Wrap execution in
a transaction and roll it back when legacy reads may perform incidental writes.
Intentional behavior changes must be separated and reported quantitatively.

## Why

Reimplementing the old path in a test duplicates the same assumptions that may
already be wrong. Running both real paths against the same input makes the old
behavior the temporary executable contract while the internals change.

High-volume and branch-rich data reveals ordering, fallback, null, and
relationship behavior that synthetic happy-path fixtures often miss.

## When to use

- Optimizing N+1 queries, caching, batching, eager loading, or serialization.
- Replacing framework, ORM, repository, or rendering internals while promising
  unchanged behavior.
- Moving legacy logic across services or runtimes.
- Consolidating duplicate implementations whose current parity matters.

## When not to use

- The old behavior is known to be unsafe or incorrect and must not execute even
  in an isolated test environment.
- The change intentionally modifies product behavior; define a new expected
  contract and measure its impact instead.
- External side effects cannot be isolated, stubbed, or safely rolled back.

## Implementation

1. Define observable output before writing the comparison: returned data,
   ordering, formatting, permissions, fallback selection, emitted events, and
   relevant state changes.
2. Choose a primary fixture with high volume and broad branch coverage.
3. Add targeted fixtures for important branches absent from the primary sample.
4. Boot the real application and run the old path with a fresh request or model
   context.
5. Reset request-local state, then run the new path against the same input.
6. Compare canonical observable output without normalizing away meaningful
   differences.
7. Roll back all database changes and discard temporary side effects.
8. Print assertion counts, mismatch counts, affected fields, and difference
   rates.

For a pure equivalent refactor, any mismatch is a failure. If a difference is
intentional, move it to a separate behavior-change review and quantify its real
data distribution before approval.

## Trade-offs

- Benefit: detects implicit legacy contracts without first documenting every
  historical rule.
- Cost: requires both implementations to coexist temporarily and a safe,
  production-shaped local dataset.
- Limitation: equivalence proves sameness, not that the old behavior is correct.

## Failure modes and anti-patterns

| Failure mode | Why it fails | How to identify it |
| --- | --- | --- |
| Recreate the old path with SQL or mocks | The test repeats assumptions instead of observing behavior | Old application code never executes |
| Use one convenient fixture | Important conditional branches remain uncovered | Coverage inventory lists branches with no sample |
| Compare only the main value | Ordering, fallback, permissions, or side effects drift | Observable contract is not written down |
| Normalize all differences away | The comparison becomes incapable of failing | Broad exclusions or lossy sorting hide output changes |
| Call differences “expected” without numbers | Large unintended blast radius looks harmless | Report lacks mismatch count and rate |
| Run against mutable production data | Results are unsafe and non-reproducible | Test connection or dataset is not hard-gated |

## Verification

- Old and new real code execute with identical inputs and isolated state.
- The test refuses to run against production.
- Database side effects are rolled back or verified absent.
- Primary and targeted fixtures cover all named critical branches.
- Equivalent changes report zero mismatches.
- Intentional changes are in a separate changeset with field-level counts and
  difference rates.

## Evidence and provenance

| Project | Commit | Evidence | Verified at |
| --- | --- | --- | --- |
| internal-project-docs | `7f713a463bf24eb1d062c20ae68f80917ad1438e` | `playbooks/legacy-equivalence-testing.md` | 2026-07-11 |
| internal-project-docs | `5cfaa2b2654cd453bd5dd49a94bdf3280c836554` | `playbooks/legacy-refactor-bug-prevention.md` | 2026-07-11 |

The source implementation reported hundreds of passing comparisons across
eager-loading, attachment, avatar, and aggregation paths. Fixed account IDs,
container names, and framework bootstrap details remain in the source project.

## Related practices

- [Legacy Refactor Blast-radius Safety](legacy-refactor-blast-radius-safety.md)
- [Evidence-driven Query Optimization](../../backend/data/evidence-driven-query-optimization.md)
