---
title: "Plan / Spec / Pending-Confirmations: Delivery Document Shape"
status: adopted
kind: pattern
basis: mixed
scope: cross-stack
tags: [documentation, delivery, scope-control, decision-record]
source-projects: [internal-project]
created: 2026-08-30
updated: 2026-08-30
last-verified: 2026-08-30
---

# Plan / Spec / Pending-Confirmations

## Context

AI 在承接一项跨多天的工作时，最容易犯两个错：**越界改了不该改的**，和**两份文档打架时自己挑一份信**。这两个错都可以用文档形状直接封掉。

## Rule

一个 initiative 拆成三份文档：

| 文档 | 管什么 |
| --- | --- |
| `<名字>-plan.md` | **why**：拍板依据、runbook、回滚预案 |
| `<名字>-development-spec.md` | **how**：工程契约。🔴 **冲突时以本文为准** |
| `<名字>-pending-confirmations.md` | 开发收官后的待确认清单（A/B/C/D 四段） |

每份文档开头固定写清：

```markdown
- 版本：v1.3（YYYY-MM-DD）—— 本版改了什么、收编了谁的反馈
- 读者：实现本任务的工程会话；§0.0 写给非工程读者
- 分工：plan 管 why，spec 管 how；🔴 冲突时以 spec 为准
- 涉及仓库/模块：A（主体）、B（少量改动）
- ⛔ 明确不动：C、D、E
- 范围排除：X 另立文档；Y 后置
```

再加一节 `§0.0 十分钟看懂本方案（通俗导读；工程契约从 §1 开始）`——**把给人看的导读和给机器执行的契约物理分开**，两边都不用妥协。

符号约定：🔴 硬约束 / ⛔ 明确禁止 / ✅ 已完成 / 🟡 观察期中 / ⚠️ 有副作用需单独确认。

## Why

- 「⛔ 明确不动」和「冲突时以谁为准」两行的写作成本是十秒，收益是消除整类事故。
- AI 遇到两份同主题文档不会报错，它会挑一份——你不会知道它挑了哪份。
- 导读与契约分开，避免为了照顾非工程读者而稀释契约的精确度。

## When to use

- 跨多天、涉及多个模块或仓库、需要他人执行部分步骤的工作。

## When not to use

- 单次小改动。三件套对一小时的活是过度设计。

## Trade-offs

- 收益：范围可控、冲突有裁决、交付即决策记录。
- 代价：三份文档要维护版本行。
- 已知限制：spec 与 plan 分工需要纪律，否则会退化成两份都写 how。

## Implementation

`pending-confirmations` 的四段结构：

```markdown
## A. 我自行拍板的 N 个取舍
### A1 · <一句话标题>
**做了什么** / **为什么** / **状态**

## B. 必须由你亲手执行的 M 件事
## C. 验收的几道门各自走到哪了
## D. 测试跑了什么、结果如何、没跑什么
```

人逐条回复后，**在同一份文档里回填处置状态**：

```markdown
🕰️ MM-DD 回复后的处置状态：A1–A8 全部按建议通过（A2 补了 X 的核实澄清）；
B1 ✅ 已确认；B3 经核实确属未做，保留为部署步骤；门 A ✅ 豁免（留补跑口子）。
```

模板见 `project-scaffold/docs/plans/_templates/`。

## Failure modes and anti-patterns

| Failure mode | 为什么会失败 | 如何识别 |
| --- | --- | --- |
| 没写 ⛔ 排除清单 | AI 顺手改了相邻模块 | diff 里出现计划外的仓库 |
| 没写冲突优先级 | 两份文档打架时静默选一 | 实现与其中一份不符但没人报告 |
| 导读混进契约 | 精确度被稀释 | 契约章节里出现比喻和类比 |
| 确认清单只列做了什么 | 缺口不可见 | 没有 D 段 |
| 回复后不回填 | 决策记录丢失 | 文档停在提问状态 |

## Verification

- 每份 spec 开头能找到「⛔ 不动」和「冲突时以谁为准」。
- 每份 pending-confirmations 都有 D 段且包含「没跑什么」。
- 收官后文档里有回填的处置状态。

## Evidence and provenance

| Project | Evidence | Verified at |
| --- | --- | --- |
| internal-project | 59 个 plan 目录按此结构组织；多个任务的确认清单含回填状态 | 2026-08-30 |

## Related practices

- [How an Agent Should Report to a Human](reporting-to-humans.md)
- [File-based Task Management](linear-task-management.md)
