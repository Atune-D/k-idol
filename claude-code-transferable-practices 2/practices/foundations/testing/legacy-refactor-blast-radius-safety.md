---
title: "Legacy Refactor Blast-radius Safety"
status: verified
kind: pattern
basis: evidence
scope: cross-stack-legacy-systems
stacks: []
versions: []
tags:
  - legacy
  - refactoring
  - smoke-testing
  - regression-safety
  - consumer-coverage
source-projects:
  - internal-project-docs
created: 2026-07-11
updated: 2026-07-11
last-verified: 2026-07-11
supersedes: []
---

# Legacy Refactor Blast-radius Safety

## Context

Legacy refactors often fail outside the path being optimized. The changed code
and its focused tests may be correct while another consumer of the same view,
helper, model contract, shared variable, or component breaks in production.

This is a blast-radius failure: the implementation was tested, but the complete
consumer set was never identified or exercised.

## Rule

Treat every shared-artifact change as a consumer-coverage problem. Before
shipping, enumerate its consumers and protect them with three independent gates:

1. Real entry-point smoke tests.
2. A consumer-coverage gate for shared artifacts.
3. Strict separation between equivalent refactors and behavior changes.

High-value rules must live in automatically executed carriers such as tests,
hooks, CI, and production error collection. Documentation explains why and how
to install the protection; it is not the protection itself.

## Why

Focused unit tests answer whether the changed unit behaves as intended. They do
not prove that every route, renderer, sibling model, or indirect consumer still
provides the contract the shared artifact expects.

An automated consumer gate converts each discovered coverage gap into permanent
coverage. A historical bug replay then proves that the gate can actually fail,
instead of merely looking plausible.

## When to use

- A production legacy application is undergoing sustained refactoring,
  performance work, framework migration, or modularization.
- A shared template, partial, component, helper, model method, serializer, or
  variable contract is changing.
- Static typing is absent or incomplete, and runtime rendering covers important
  contracts.
- One change can affect several routes, commands, workers, or clients.

## When not to use

- A small isolated module has one proven consumer and strong compile-time
  contracts.
- The operation is a write-path migration whose correctness depends on
  accounting invariants rather than HTTP rendering; use parity and invariant
  checks instead.
- The goal is to prove detailed business correctness. Smoke tests only prove
  that an entry point renders or responds without an obvious failure.

## Implementation

### Gate 1: real entry-point smoke tests

Exercise the real router, controller or handler, data access, and renderer. For
each entry point, assert:

- a successful status or completion result;
- at least one business marker proving the intended page or payload rendered;
- absence of known framework exception and error-page markers.

Use deliberately difficult fixtures: high-volume data, rare branches, optional
attachments, missing relationships, fallback values, and permission variants.
Randomly choosing an ordinary record is not sufficient for branch coverage.

Protect data by hard-checking that the test database is local, wrapping the run
in a transaction when possible, and rolling it back. Isolate session, template,
cache, and other request-scoped state between entry points.

### Gate 2: shared-consumer coverage

Maintain a structured manifest containing each protected entry point, its input,
expected markers, rejected markers, and shared artifacts it exercises.

When a shared artifact changes:

1. Reverse-resolve its direct and indirect consumers.
2. Map each consumer to an entry point.
3. Require every entry point to exist in the smoke manifest.
4. Reject the change and list uncovered consumers when a gap exists.

Dynamic imports, runtime-computed view names, reflection, and convention-based
resolution may be impossible to resolve statically. Report those blind spots as
warnings and rely on broader smoke coverage rather than pretending certainty.

### Gate 3: separate intent

An equivalent refactor has a zero-behavior-diff contract. Put intentional
behavior changes in separate changesets, quantify the affected production-like
data distribution first, and review the decision independently.

Do not hide a behavior change inside a performance refactor because it appears
minor or beneficial.

### Replay a known failure

Temporarily reproduce a historical regression or introduce a controlled
equivalent. Confirm that:

- the expected gate fails;
- the failure points to the correct entry point;
- unrelated entry points remain green;
- restoring the fix returns the suite to green.

A regression gate that has never caught its target failure is not yet verified.

## Trade-offs

- Benefit: prevents entire families of indirect-consumer regressions and grows
  coverage every time a new consumer is discovered.
- Cost: requires manifest maintenance, representative local data, and enough
  runtime infrastructure to render real entry points.
- Limitation: cannot prove business-number correctness, cover every dynamic
  consumer, or exercise write paths that smoke tests never invoke.

## Failure modes and anti-patterns

| Failure mode | Why it fails | How to identify it |
| --- | --- | --- |
| Only test the page being optimized | Other consumers retain an incompatible contract | Shared artifact has more consumers than the test manifest |
| Treat static search as complete | Dynamic resolution and sibling patterns remain invisible | Runtime references exist without literal import/include paths |
| Use ordinary fixtures | Rare conditional branches never execute | Fixtures lack high-volume, null, fallback, or permission cases |
| Mix behavior change into perf work | Tests prove the new intent, not that the intent is correct | Output differs without an explicit decision and quantified impact |
| Keep the rule only in docs | Humans and agents eventually forget it | No test, hook, CI, or monitoring carrier enforces the rule |
| Trust a new smoke suite without replay | The assertions may not detect the historical failure | No recorded red-green bug replay exists |

## Verification

- Every changed shared artifact has an enumerated consumer set.
- Every resolvable entry-point consumer appears in the smoke manifest.
- The smoke runner uses real dispatch and rendering, difficult fixtures, and
  isolated request state.
- A historical regression replay makes the expected test fail and recover.
- Equivalent refactors have zero diff under behavior-equivalence testing.
- Production server errors are collected independently as the final safety net.

## Evidence and provenance

| Project | Commit | Evidence | Verified at |
| --- | --- | --- | --- |
| internal-project-docs | `5cfaa2b2654cd453bd5dd49a94bdf3280c836554` | `playbooks/legacy-refactor-bug-prevention.md` | 2026-07-11 |

The source playbook was produced after three production regressions exposed the
same missing-consumer pattern. Project-specific routes, account identifiers,
framework calls, and implementation filenames were intentionally excluded here.

## Related practices

- [Legacy Behavior Equivalence Testing](legacy-behavior-equivalence-testing.md)
- [Incident Analysis Evidence Discipline](../incident-analysis-evidence-discipline.md)
