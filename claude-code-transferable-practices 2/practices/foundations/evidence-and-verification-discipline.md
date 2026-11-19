---
title: "Evidence and Verification Discipline for AI Output"
status: verified
kind: principle
basis: evidence
scope: cross-stack
tags: [hallucination, verification, testing, evidence]
source-projects: [internal-project]
created: 2026-08-30
updated: 2026-08-30
last-verified: 2026-08-30
---

# Evidence and Verification Discipline / 证据与验证纪律

## Context

幻觉是模型的固有属性，不因语言或框架而变。而**最危险的幻觉恰恰是标识符**——`user_settings` vs `users_settings`、`--force` vs `--yes`。它们看起来完全合理，只有真跑起来才错。散文级的错误人一眼能看出来，标识符级的错误人看不出来。

## Rule

1. **凡是专有名词，都要有可追溯的出处。** 表名、命令名、配置键、API 路径、函数名、字段名——写出来之前先 grep / LSP / schema 核实，不允许凭记忆猜测。
2. **凡是验证性产物，都要先证伪一次。** 测试、检查清单、监控判据——**没见过它变红的测试，等于没有测试**。
3. **守门测试要断言效果，不是断言存在。** 断言「代码里写了这行」＝虚假安心；用扫描不用清单、剥掉注释再匹配。
4. **存在性判断禁用 `SUM == 0`。** 只比净额会漏掉正负相抵的错误。
5. **测试汇报必须精确**：写明 ① 类型（单元 / 集成 / 浏览器 e2e / 差分）② 具体套件或目录 ③ 数量与结果，**并说明没跑什么**。禁用「全量回归」「跑了测试」这类模糊表述。
6. **提炼经验前先查 diff**，区分「已提交证据」和「本地观察」；多来源归纳分别列来源，不用一个来源替另一个背书。

## Why

- 一份「命令全是猜的」核验清单，比没有清单更糟——它在你最紧张的时刻给出虚假的安全感。
- 「全量回归」读不出验证了什么：单元？集成？e2e？差分？验证强度完全不同，模糊表述会让人误判风险覆盖面。
- AI 在「总结经验」上有一个稳定失败模式：**把刚才在本地看到的临时状态，写成「已验证的普遍事实」**。

## When to use

- 生成任何操作清单、测试、监控判据、经验总结时。

## When not to use

- 头脑风暴、方案草图阶段（但要显式标注「未核实」）。

## Trade-offs

- 收益：消除整类「看起来对、跑起来错」的问题。
- 代价：每个标识符多一次查证；测试要多跑一次「验红」。
- 已知限制：核实手段依赖工具可用性（grep / LSP / schema）。

## Implementation

汇报测试的正确形态：

```text
跑了：单元 312 个（tests/Unit）、集成 45 个（tests/Feature，真实 DB + HTTP fake），全绿。
没跑：浏览器 e2e —— 本仓库不存在此类测试；差分测试 —— 本次改动不涉及冻结面。
```

注意多套件参数陷阱：某些测试框架 `--testsuite` 传两个只会跑最后一个，「全部」的数字会悄悄少一半。报「全部」前先确认注册了几个套件。

## Failure modes and anti-patterns

| Failure mode | 为什么会失败 | 如何识别 |
| --- | --- | --- |
| 标识符幻觉 | 看起来合理，只有运行才暴露 | unknown column / command not found |
| 从没红过的测试 | 断言写错了也永远绿 | 故意改坏代码，测试仍绿 |
| 断言「存在」而非「效果」 | 注释掉的代码也能匹配到 | 把目标行注释掉，测试仍绿 |
| `SUM == 0` 判存在 | 正负相抵 | 明细有行但聚合为零 |
| 「全量回归通过」 | 覆盖面不可知 | 汇报里没有目录名和数量 |
| 把本地未提交状态写成已验证事实 | 证据不可复现 | provenance 没有 commit SHA |

## Verification

- 随机抽一条清单命令，能否在代码里定位到出处。
- 随机挑一个守门测试，手工把被守护的行为改坏，它是否变红。
- 抽查一篇经验文档的 provenance 是否有 commit SHA 或稳定路径。

## Evidence and provenance

| Project | Evidence | Verified at |
| --- | --- | --- |
| internal-project | 死码清扫误杀导致 500（大小写不敏感）；`--testsuite` 陷阱；守门测试「断言存在」失效 | 2026-08-30 |

## Related practices

- [Incident Analysis Evidence Discipline](incident-analysis-evidence-discipline.md)
- [Capability Is Not Authorization](ai-authorization-boundaries.md)
