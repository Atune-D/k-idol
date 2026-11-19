---
title: "Evidence-driven Query Optimization"
status: verified
kind: pattern
basis: evidence
scope: backend-data-access
stacks:
  - relational-databases
  - orm
versions: []
tags:
  - performance
  - n-plus-one
  - query-budget
  - indexing
source-projects:
  - internal-project-docs
created: 2026-07-11
updated: 2026-07-11
last-verified: 2026-07-11
supersedes: []
---

# Evidence-driven Query Optimization

## Context

Query optimization goes wrong when it begins with an index idea or a suspected
ORM problem instead of the actual request, SQL shape, frequency, execution plan,
and business output. A locally fast query can still be the wrong target, and a
lower query count can still change ordering, fallback, permissions, or results.

## Rule

Optimize from measured evidence:

1. Capture a reproducible request and query baseline.
2. Group queries by family and map them to the application call chain.
3. Fix work that grows linearly with entity count before micro-optimizing
   constant queries.
4. Preserve the complete observable behavior.
5. Add a query budget and output-equivalence regression test.
6. Add or change indexes only after confirming the real query shape, frequency,
   selectivity, and execution plan.

Clearly distinguish estimates from measurements. Stop when the agreed budget
and behavior contract are satisfied.

## Why

N+1 queries multiply with data volume and turn normal heavy users into capacity
incidents. Batching or eager loading changes that growth from per-entity work to
a small number of set-based operations.

Indexes are not free: they consume space, add write cost, and can create rollout
risk on hot tables. Evidence identifies whether the correct fix is batching,
removing an unnecessary exact count, adding an index, caching, or building a
summary table.

## When to use

- A page, API, command, or job has high query count or database latency.
- Query count rises with the number of rows, entities, stores, users, or nested
  relationships.
- Pagination, reporting, dashboards, or repeated aggregate counts are slow.
- A production slow-query sample needs diagnosis and a safe rollout plan.

## When not to use

- The bottleneck has not been isolated to database work.
- Only synthetic data is available and its cardinality differs materially from
  real usage; gather a representative baseline first.
- A proposed index is based on one log sample whose caller and frequency are
  still unknown.

## Implementation

### 1. Establish the baseline

Record:

- exact business entry point and representative input;
- total query count and wall-clock database time;
- query families with count and percentage of total work;
- rows examined, rows returned, execution plan, and frequency for slow queries;
- current output snapshot or equivalence contract.

Do not label normal high-volume usage as abuse until it has been compared with a
normal baseline and the request's amplification factor is understood.

### 2. Find growth behavior

Look for queries inside loops, ORM relation methods that always issue a fresh
query, per-entity lookups, duplicated permission checks, and views that perform
data access. Estimate the relationship between entity count and query count,
then verify it with at least two representative sizes when practical.

Prefer fixes that turn `O(n)` query families into set-based loading:

- explicit eager loading at the request or loader boundary;
- batch loaders keyed by IDs;
- request-scoped warming for reused reference data;
- reuse of already loaded relationships rather than new query builders;
- bulk permission and metadata lookup.

Keep data access out of rendering code. A view may consume prepared data; it
should not silently expand the query plan.

### 3. Preserve semantics

Before replacing database operations with in-memory work, inventory:

- ordering and tie-breaking;
- uniqueness and deduplication;
- null and missing-record behavior;
- fallback values;
- tenant and permission filtering;
- pagination and count semantics;
- incidental writes or cache updates on read paths.

Read-only HTTP paths should not perform hidden writes. Move cache refresh or
state mutation to an explicit write, event, or background path.

### 4. Choose the right data strategy

- Repeated relationship lookup: eager load or batch.
- Exact page count not required: use cursor/simple pagination or defer the count.
- Occasional selective range query: evaluate an index.
- Frequent historical aggregate over mostly immutable data: evaluate a rollup,
  summary table, or counter instead of repeatedly scanning detail rows.

For composite indexes, start from actual predicates. Equality columns usually
precede the selective range column; columns after a range are generally useful
for filtering or covering rather than further seeking. Validate this with the
real optimizer instead of treating the heuristic as proof.

### 5. Verify and roll out

Compare before and after using the same input and dataset:

- total and per-family query counts;
- rows examined and returned;
- execution time;
- output equivalence;
- database writes triggered by a read request.

Add a regression budget appropriate to the entry point, with enough tolerance
for stable framework queries but low enough to catch a reintroduced N+1.

Run expensive plan analysis on a safe replica or production-shaped copy. For a
hot-table index rollout, inspect long transactions, metadata-lock risk, I/O,
replication lag, disk headroom, abort procedure, and rollback path. “Online DDL”
does not mean operationally risk-free.

## Trade-offs

- Benefit: targets dominant work, produces measurable results, and leaves a
  regression guard.
- Cost: requires representative data, query instrumentation, and semantic
  equivalence checks.
- Limitation: a query budget is route- and dataset-sensitive; it must not become
  a universal number copied between projects.

## Failure modes and anti-patterns

| Failure mode | Why it fails | How to identify it |
| --- | --- | --- |
| Add an index before finding the caller | Optimizes a symptom and adds write cost | Entry point or frequency remains unknown |
| Report only total query count | Dominant query families and growth remain hidden | No grouped count or call chain exists |
| Batch without preserving semantics | Output order, fallback, or permissions drift | No behavior-equivalence assertion exists |
| Optimize estimates as facts | Rollout expectations become misleading | Projected and measured values are not labeled separately |
| Keep DB calls in the view | Query plan changes with rendering branches | Templates/components invoke ORM or repositories |
| Use exact pagination count by default | Large aggregate runs even when UI does not need it | Request issues count plus page query unnecessarily |
| Treat online index creation as harmless | MDL, I/O, log, and replication pressure remain | No operational rollout and abort plan exists |

## Verification

- Baseline and after-state use the same entry point, input, and data snapshot.
- Query families, counts, and call chains are recorded.
- Query count no longer grows linearly for the optimized relationship set.
- Ordering, deduplication, fallback, permission, and output contracts remain
  equivalent.
- Read paths perform no unintended writes.
- The entry point stays within its regression query budget.
- Index changes have plan evidence and an operational rollout/rollback plan.

## Evidence and provenance

| Project | Commit | Evidence | Verified at |
| --- | --- | --- | --- |
| internal-project-docs | `35faf6400b4d14f12d3a8747dc214f9fb2c105e9` | `playbooks/calendar-list-n1-optimization-2026-06-25.md` | 2026-07-11 |
| internal-project-docs | `35faf6400b4d14f12d3a8747dc214f9fb2c105e9` | `runbook/slow-query-triage-log.md` | 2026-07-11 |

The source evidence includes a production-shaped route whose query count was
reduced from hundreds to a small constant-sized batch while preserving output.
Exact route names, tenant identifiers, SQL literals, and index names remain in
the source project.

## Related practices

- [Legacy Behavior Equivalence Testing](../../foundations/testing/legacy-behavior-equivalence-testing.md)
- [Legacy Refactor Blast-radius Safety](../../foundations/testing/legacy-refactor-blast-radius-safety.md)
