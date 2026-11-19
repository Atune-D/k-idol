---
title: "Incident Analysis Evidence Discipline"
status: verified
kind: pattern
basis: evidence
scope: incident-analysis
stacks: []
versions: []
tags:
  - incidents
  - root-cause-analysis
  - evidence
  - uncertainty
source-projects:
  - internal-project-docs
created: 2026-07-11
updated: 2026-07-12
last-verified: 2026-07-11
supersedes: []
---

# Incident Analysis Evidence Discipline

## Context

Incident reports 往往会综合 logs、monitoring、code inspection、vendor statements、
当事人的回忆、通用机制知识和合理推断。如果书写时对这些来源表现出同等程度的确定性，
早期提出的理论就可能变成错误的 root cause，甚至在相反证据出现很久之后仍被沿用。

## Rule

为每一项重要结论标注 evidence class，并在报告结尾明确说明 certainty boundary。
除非有证据证明相互冲突的 timelines 或 system views 之间存在怎样的关联，否则绝不能
把它们合并成同一套叙述。

始终一致地使用以下 classes：

| Class | 含义 | 建议表述 |
| --- | --- | --- |
| Observed | 直接取得的 logs、metrics、traces、commands 或 reproducible output | “Log 显示……” |
| Documented | 当前 code、configuration、local records 或权威 external documentation | “文档记录的机制是……” |
| Reported | 尚未独立验证的当事人、customer、operator 或 vendor 陈述 | “Operator 报告称……” |
| Inferred | 根据 observed facts 和已知机制推导出的解释 | “一种合理的解释是……” |
| Unknown | 得出结论所必需、但目前无法获得的信息 | “这一点仍未得到确认……” |

对 root cause 的确定程度，不得高于其必要证据链中最薄弱的一环。

## Why

Incident 通常发生在时间紧迫且 visibility 不完整的情况下。不同 nodes、services、
time zones 和观察者所产生的记录，各自内部可能都成立，却无法彼此兼容。保持这些记录
相互独立，才能让后续证据修正分析，而不必改写历史，也能避免错误归责于其他 system。

## When to use

- Production incident reports、handoffs、postmortems 和 root-cause analyses。
- 尚未证明 causation 的 performance investigations。
- OS 或 node visibility 有限的 vendor-managed infrastructure incidents。
- 任何需要综合多份 logs、多位人员、多个 dashboards 或 documentation 的分析。

## When not to use

- 简单且完全 reproducible 的 local defect，并且 failing input、mechanism 和 fix 都已得到
  直接验证。
- 不包含任何 causal claims 的日常 operational status updates。

## Implementation

### Build an evidence inventory

在撰写事件叙述之前，为每个 source 记录 owner、collection time、time zone、system 或
node perspective、retention limits，以及可能存在的 integrity concerns。不能仅仅因为
filenames 或 event types 看起来相似，就把两份 logs 当成同一个 stream。

### Write claims with local provenance

把 evidence class 和 source 写在其所支持的结论旁边。明确区分：

- 实际发生了什么；
- 哪种 mechanism 能够解释 observation；
- 某人报告了什么；
- 哪些内容仍然只是 hypothesis；
- 哪些证据可以确认或否定该 hypothesis。

Official documentation 可以证明某种通用机制存在，但不能证明该机制导致了这次具体的
incident。

### Preserve conflicting views

当不同 sources 相互矛盾时，使用 comparison table 展示 timestamp、node 或 service
perspective、event 和 confidence。在 topology map、correlation ID 或其他证据证明它们
之间的关系之前，始终保留各自独立的 parallel timelines。

不能仅仅因为某种说法更容易解释，就选择看起来更整洁的故事。

### Maintain a correction trail

当新证据改变了先前的结论时：

1. 保留先前的结论及其原始 evidence class。
2. 说明新增了什么证据。
3. 说明哪些 inference 被降低可信度、替换或否定。
4. 更新依赖旧结论的 actions。

### End with a certainty boundary

分别列出：

- 有 direct evidence 支持的结论；
- 有 documentation 和 observation 共同支持的结论；
- unverified reports；
- active hypotheses；
- unknown facts，以及下一步 collection action。

## Trade-offs

- Benefit：防止 speculation 变成组织内部认定的事实，并使 handoff 更安全。
- Cost：事件叙述会显得不够整齐，而且需要严格追踪 sources。
- Limitation：classification 无法取代缺失的 telemetry；某些 root causes 仍会保持
  unknown。

## Failure modes and anti-patterns

| Failure mode | 失败原因 | 识别方式 |
| --- | --- | --- |
| 把 vendor statement 当成事实 | 绕过了 independent verification | 结论没有 logs、metrics 或 written report 支持 |
| 用通用 mechanism 证明具体 incident | 把可能性误当成 causation | 没有 event evidence，却从“可能导致”变成“确实导致” |
| 强行把不兼容的 logs 合并到同一 timeline | 混淆了不同 nodes 或 time slices | IDs、timestamps 或 perspectives 不一致 |
| 隐藏已修正的结论 | 后续读者会重复已经过时的 diagnosis | 报告中没有 correction trail |
| 因为缺少证据就断言某事不成立 | 把 telemetry 缺失误当成反证 | 没有列出 collection gaps |
| 混淆 remediation status 与 root-cause proof | 合理的 fix 看起来像是验证了某个理论 | Action 成功，但 causal link 仍未经过验证 |

## Verification

- 每项重要的 causal claim 都标有 evidence class 和 source。
- 所有 timestamps 都包含 time zone 和 system perspective。
- 在 correlation 得到证明之前，相互冲突的 sources 始终保持独立。
- 每项 Inference 都说明什么证据可以确认或 falsify 它。
- 修正后的结论保留 correction trail。
- 报告结尾明确分为 known、reported、inferred 和 unknown sections。
- Sensitive identifiers 和 raw logs 保留在 source project 中，不写入 cross-project
  practice。

## Evidence and provenance

| Project | Commit | Evidence | Verified at |
| --- | --- | --- | --- |
| internal-project-docs | `35faf6400b4d14f12d3a8747dc214f9fb2c105e9` | `runbook/incidents/incident-2026-06-25-db-oom-replication.md` | 2026-07-11 |

source incident 包含相互冲突的 log streams，以及一项在取得更多证据后被降低可信度的
早期 causal theory。IPs、node identifiers、vendor-specific actions 和 incident
timeline 均保留在 source project 中。

## Related practices

- [Legacy Refactor Blast-radius Safety](testing/legacy-refactor-blast-radius-safety.md)
- [Layered Health Checks](../devops/observability/layered-health-checks.md)
