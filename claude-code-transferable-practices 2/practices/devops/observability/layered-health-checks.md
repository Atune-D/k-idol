---
title: "Layered Health Checks"
status: verified
kind: pattern
basis: evidence
scope: production-observability
stacks: []
versions: []
tags:
  - observability
  - health-checks
  - alerting
  - incident-response
source-projects:
  - internal-project-docs
created: 2026-07-11
updated: 2026-07-11
last-verified: 2026-07-11
supersedes: []
---

# Layered Health Checks

## Context

One health endpoint cannot distinguish every failure mode. An HTTP probe may
confirm that a web server responds while a database is unavailable. A dependency
probe may pass while business processing has stalled. Platform metrics may look
healthy while the application cannot authenticate or route to the dependency.

## Rule

Monitor production health from several independent perspectives, and document
the exact question each signal can and cannot answer.

At minimum, separate:

1. External reachability.
2. Application-to-dependency connectivity.
3. Business activity or freshness.
4. Platform and infrastructure state.
5. Monitor-pipeline freshness itself.

Return stable, machine-readable failure reasons and connect every alert class to
an initial response action. Test the real failure path, not only the success
path.

## Why

Independent signals reduce ambiguous alerts and reveal partial failures. They
also prevent a failed monitoring pipeline from silently turning into a false
healthy state.

Stable reason codes let alert routing and runbooks evolve without parsing human
messages or exposing sensitive exception details.

## When to use

- A production service depends on a database, queue, storage provider, or other
  critical remote system.
- Infrastructure is managed by a cloud vendor and application visibility differs
  from platform visibility.
- Background processing can stop while HTTP remains available.
- Fast classification materially reduces incident response time.

## When not to use

- A local development tool has no production availability requirement.
- A dependency probe would create unsafe side effects or unacceptable load; use
  a cheaper read-only signal or platform metric instead.

## Implementation

### Define the signal matrix

| Layer | Question answered | Typical blind spot |
| --- | --- | --- |
| External reachability | Can a user or monitor reach the service? | Cannot isolate application, dependency, or network cause |
| Dependency probe | Can the running application authenticate and perform a minimal read? | May miss slow queries, saturation, or business failure |
| Business freshness | Are expected events, jobs, or records still progressing? | May lag and may depend on the same broken pipeline |
| Platform metrics | Are instances, replicas, CPU, memory, disk, and lag healthy? | Does not prove the application can connect or use them |
| Monitor freshness | Is the collector or push pipeline still reporting? | Does not prove the monitored service itself is healthy |

Keep the layers independent enough that one failure does not erase all evidence.

### Use a stable machine contract

A dependency probe should return bounded, non-sensitive fields such as:

```json
{
  "status": "dependency_error",
  "reason": "authentication_failed",
  "latency_ms": 125,
  "checked_at": "2026-01-01T00:00:00Z"
}
```

Use an HTTP failure status for monitoring and a stable `reason` for diagnosis.
Reason values are an external contract: add new categories when needed, but do
not silently rename or change the meaning of existing values.

Do not include credentials, cookies, authorization headers, full request bodies,
query strings, internal hostnames, or unsanitized exception messages.

### Make alerts actionable

For each reason, define:

- first check;
- responsible system or owner;
- evidence to record;
- escalation condition;
- actions that are unsafe without more evidence.

Alert text should identify the layer and reason, then link to the runbook. It
should not attempt to embed the entire diagnosis.

### Exercise negative paths

In a local or disposable environment, intentionally create representative
failures such as invalid credentials, refused connections, timeouts, stopped
workers, and stale push data. Verify the complete chain:

```text
failure -> probe -> reason -> monitor -> notification -> runbook
```

Never modify production credentials merely to test an alert.

### Monitor the monitor

Push and scheduled checks must have a freshness deadline. Missing reports are a
distinct failure state, not an absence of problems. Record last successful check
time and alert when the expected schedule becomes stale.

## Trade-offs

- Benefit: faster fault isolation, clearer ownership, and fewer false causal
  conclusions.
- Cost: more probes, contracts, alert rules, and runbooks to maintain.
- Limitation: even layered monitoring cannot prove all business correctness or
  identify a root cause without investigation.

## Failure modes and anti-patterns

| Failure mode | Why it fails | How to identify it |
| --- | --- | --- |
| One `/health` endpoint represents everything | Partial failures collapse into one ambiguous signal | Alert cannot distinguish web, dependency, business, or platform |
| `SELECT 1` is treated as business health | Connectivity passes while workloads are stalled or slow | Business freshness has no independent signal |
| Platform dashboard is treated as user availability | Provider state does not include application credentials or routing | App probe fails while platform is green |
| Only happy path is tested | Alerting and runbook decay unnoticed | No intentional failure exercise exists |
| Missing push means healthy | Broken collector suppresses all alarms | No freshness deadline or stale state exists |
| Return raw exception details | Monitoring leaks secrets and infrastructure data | Response contains credentials, hosts, queries, or stack traces |
| Change reason strings freely | Alert routing and runbooks silently break | Consumers parse human text or undocumented values |

## Verification

- Each signal documents the exact question and blind spots.
- External, dependency, business, platform, and freshness signals exist where
  relevant.
- Failure reasons are stable, bounded, machine-readable, and sanitized.
- Each reason maps to a first action and escalation path.
- Negative-path E2E exercises prove notification delivery.
- Stale monitoring data triggers its own alert.
- Probe cost, timeout, and permissions are constrained.

## Evidence and provenance

| Project | Commit | Evidence | Verified at |
| --- | --- | --- | --- |
| internal-project-docs | `35faf6400b4d14f12d3a8747dc214f9fb2c105e9` | `runbook/database-healthcheck-operations-2026-06-26.md` | 2026-07-11 |

The source practice combined an application dependency probe, business heartbeat,
cloud-platform metrics, and stale-push detection after a production database
incident. Domains, tokens, database identifiers, and vendor-specific commands
remain in the source project.

## Related practices

- [Incident Analysis Evidence Discipline](../../foundations/incident-analysis-evidence-discipline.md)
