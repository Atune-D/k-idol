---
title: "Legacy Browser Data Parity Testing"
status: verified
kind: playbook
basis: evidence
scope: cross-stack-legacy-migrations
stacks:
  - browser
  - backend
  - frontend
versions: []
tags:
  - legacy
  - browser-parity
  - data-parity
  - migration
  - e2e-testing
  - regression-safety
source-projects:
  - internal-project
created: 2026-07-18
updated: 2026-07-18
last-verified: 2026-07-18
supersedes: []
replaced-by: null
---

# Legacy Browser Data Parity Testing

## Context

Legacy migrations often replace the UI, routing, backend API, authentication
model, and data serialization while promising that operators see the same
business data. Unit tests and API tests are not enough because the legacy
contract may live in Blade templates, helper methods, default filters,
pagination, sort order, incidental reads, and real browser-visible formatting.

The reliable migration question is not "does the new UI look like the old UI?"
It is "for the same safe development dataset, do the old and new applications
show the same business facts, or is every difference explicitly approved?"

## Rule

For a legacy UI migration, run the old and new real applications side by side
against the same safe development database snapshot, open comparable pages in a
real browser session, and compare browser-visible data field by field.

Use the legacy console as the temporary data baseline. Treat UI layout,
component structure, visual style, and information architecture differences as
expected unless they change the meaning of data. Record every page result in a
durable report with URLs, filters, visible values, sample rows, mismatch fields,
and evidence. Then fix the new application page by page until all required data
matches the legacy baseline or is classified as an approved difference.

## Why

Browser parity catches contracts that are invisible in lower-level tests:

- legacy default filters and hidden exclusion lists;
- table ordering and pagination semantics;
- formatting that changes numeric meaning versus harmless currency/decimal
  presentation differences;
- "empty page equals empty page" false positives;
- legacy pages that fail because the local snapshot is missing a table;
- pages that perform incidental writes while rendering;
- capabilities the new portal forgot to expose;
- security improvements such as not showing secrets, which must be separated
  from data mismatches.

The old UI is not a design target. It is a live oracle for data behavior until a
new product contract replaces it.

## When to use

- Migrating an admin console, portal, dashboard, or internal tool from a legacy
  stack to a new frontend/backend.
- Verifying page-level data parity after backend API rewrites, BFF additions, or
  model serialization changes.
- Auditing a migration where the new UI intentionally differs but business data
  should remain equivalent.
- Prioritizing fixes after a broad migration: mismatch pages become the repair
  backlog.

## When not to use

- Pure code refactors where both old and new implementations can be compared
  directly in tests without a browser. Use
  [Legacy Behavior Equivalence Testing](legacy-behavior-equivalence-testing.md)
  instead.
- Intentional product redesigns where the old data contract has been replaced
  by a documented new contract.
- Unsafe environments where the old page can perform production writes,
  send notifications, charge money, delete records, or expose secrets and those
  side effects cannot be isolated.
- Pages whose only expected parity is visual layout. This playbook is for data
  parity, not pixel parity.

## Implementation

### 1. Define the comparison matrix before opening pages

Create a test plan with stable test IDs. For each row define:

- legacy URL;
- new URL;
- required login identity;
- filters/date ranges/search terms;
- visible data fields to compare;
- expected status options;
- known approved differences;
- privacy rules for evidence.

Use explicit result states:

| State | Meaning |
| --- | --- |
| `MATCH` | Visible data, collection membership, sorting, and formatting satisfy the same contract |
| `MISMATCH` | An unexplained data difference needs repair or product decision |
| `APPROVED_DIFFERENCE` | A product/security decision allows the difference |
| `PORTAL_MISSING` | Legacy has a required capability and the new app has no equivalent |
| `LEGACY_BROKEN` | Legacy page itself is broken, so it cannot be used as a live oracle |
| `NOT_COMPARABLE` | The new page has a different approved contract |
| `BLOCKED` | Environment, auth, permissions, or data prevents execution |

### 2. Gate the environment before login

Record commit or dirty state for every involved repo. Confirm the old and new
applications point to the same safe database host and database name. If they do
not, stop. If the database might be production or cannot be restored, stop.

Record ports, health checks, and startup commands. Do not run migrations, seeds,
or destructive sync commands as part of parity setup.

Legacy reads may have incidental writes such as session updates, cache writes,
audit logs, or balance refreshes. List allowed incidental writes before
testing; treat any additional write requirement as a blocker.

### 3. Make login repeatable and auditable

Use fixed local/development test identities. When permitted, reset test account
passwords through the application runtime instead of asking the user to log in
manually each time.

Password reset rules:

- target only the approved test account IDs;
- use a temporary password from an environment variable or interactive secret;
- never commit or report plaintext passwords or password hashes;
- record that a reset happened and which account IDs were affected;
- record allowed side effects such as browser sessions, last-login timestamps,
  and audit logs.

### 4. Use a real browser session when page behavior depends on it

If the task depends on real cookies, saved login state, browser security UI, or
human-observed rendering, use the user's normal browser profile or another
explicitly approved persistent test profile. Do not silently replace it with a
headless browser or empty automation profile.

Browser automation is a data collection tool here. It must not click destructive
buttons, submit edit forms, trigger payments, send messages, or call write APIs
unless the test plan explicitly authorizes that action.

### 5. Compare data, not UI taste

Normalize only harmless presentation differences:

- currency symbol variants when the numeric value and currency are known to be
  the same;
- thousands separators;
- `10`, `10.0`, and `10.00` when the business value is the same;
- confirmed timezone display differences;
- pagination size differences when full collection membership and sort order are
  otherwise proven.

Do not normalize away meaningful differences in totals, counts, IDs, status
mapping, filtering, sort order, null handling, date range, or collection
membership.

When the new UI groups data differently, compare the underlying visible facts:
summary cards, table rows, sample IDs, detail drawers, badges, and filters.

### 6. Record every page in a durable report

Each page result must include:

- test ID and result state;
- legacy URL and new URL;
- active filters/search/date range;
- visible summary values;
- first-page collection membership and sort order;
- representative sample rows with stable IDs;
- field-level comparison table;
- evidence source, such as browser accessibility tree, screenshot path, API
  response, log entry, or SQL read-only check;
- sensitive-data handling.

Mask phone numbers, emails, SMS bodies, tokens, cookies, and secrets. For SMS or
email bodies, record IDs, length, status, and short sanitized excerpts rather
than full content.

### 7. Convert mismatches into a repair loop

After the first full matrix pass:

1. group `MISMATCH` and `PORTAL_MISSING` pages by backend/service/function;
2. use legacy data as the baseline unless the difference is approved;
3. fix one page or data function at a time;
4. run focused backend/frontend tests;
5. retest the affected browser page;
6. append the fix and retest result to the report;
7. keep UI differences out of the mismatch backlog.

If a legacy page is broken because local data is incomplete, repair the local
snapshot or classify it as `LEGACY_BROKEN`; do not claim the new page is
equivalent from an empty or failed legacy page.

## Failure modes and anti-patterns

| Failure mode | Why it fails | How to identify it |
| --- | --- | --- |
| Comparing screenshots by appearance | UI redesign noise hides data regressions | Report talks about layout but lacks field values |
| Using different databases | Differences may be environment drift, not migration bugs | Environment section lacks old/new host and database confirmation |
| Treating UI differences as bugs | New portal becomes constrained by legacy design instead of data contract | Mismatch list includes visual layout or component choices |
| Treating missing legacy data as a pass | Empty/500 legacy pages provide no oracle | Legacy page status is 500, empty, or missing required local table |
| Over-normalizing values | Real business differences disappear | Broad rules ignore IDs, status, sorting, counts, or date windows |
| Not recording every page | Later fixes cannot prove the whole matrix was covered | Report has summary counts without per-page URLs and values |
| Manual login dependency | Test cannot be repeated by another agent | Plan requires user login even though local test credential reset is available |
| Ignoring incidental writes | Read-only audit mutates state unexpectedly | Legacy page render updates tables not listed in setup assumptions |
| Hiding approved differences in mismatches | Repair backlog mixes bugs with decisions | Security differences such as secret masking appear as unexplained failures |

## Verification

A browser parity run is complete only when:

- every planned test ID has one explicit result state;
- every compared page records both old and new URLs;
- old and new apps are proven to use the same safe database snapshot;
- required test accounts are repeatably loginable without recording secrets;
- every `MISMATCH` lists field, old value, new value, sample ID, and evidence;
- every `PORTAL_MISSING` links to a required legacy capability or an approved
  decision not to migrate;
- every `APPROVED_DIFFERENCE` states the product/security reason;
- focused retests are appended after fixes;
- final summary separates `MATCH`, `MISMATCH`, `APPROVED_DIFFERENCE`,
  `PORTAL_MISSING`, `LEGACY_BROKEN`, `NOT_COMPARABLE`, and `BLOCKED`.

## Evidence and provenance

| Project | Commit | Evidence | Verified at |
| --- | --- | --- | --- |
| internal-project-docs | local workspace report, not yet a committed canonical source | `docs/audits/admin-portal-legacy-browser-parity-audit-20260717.md`; `docs/reports/admin-portal-legacy-browser-parity-report-20260717.md`; `docs/reports/admin-portal-legacy-browser-parity-fix-report-20260718.md` | 2026-07-18 |
| internal-project-admin-portal | `840d232d1125a8f7e2dbba0bc1ec2e784f8faa8c` | `docs/plans/admin-portal-legacy-browser-parity-e2e-test-plan.md` and Agent Portal `/notifications`, `/emails`, `/media` parity pages | 2026-07-18 |
| internal-project-backend | `96d6859567e47a93eb9494213c20383c50cb2886`; `65ef03095c5e9aa535db9df2273693267a8e5548` | Agent emails/notifications/media APIs and legacy parity data口径 fixes | 2026-07-18 |

The reference run found multiple real mismatches in finance, reports, account
directory/detail, billing, media, and staff data. The repair loop fixed backend
aggregation口径, exact media counts, legacy exclusion lists, missing pages, and
field exposure while keeping Portal UI decisions independent from legacy UI
layout.

## Related practices

- [Legacy Behavior Equivalence Testing](legacy-behavior-equivalence-testing.md)
- [Legacy Refactor Blast-radius Safety](legacy-refactor-blast-radius-safety.md)
