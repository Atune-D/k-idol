---
title: "Frozen Surface vs Free Surface in Migrations and Rewrites"
status: verified
kind: pattern
basis: evidence
scope: cross-stack
tags: [migration, refactor, rewrite, differential-testing, architecture]
source-projects: [internal-project]
created: 2026-08-30
updated: 2026-08-30
last-verified: 2026-08-30
---

# Frozen Surface vs Free Surface / 冻结面与自由面

## Context

任何「基于既有东西做改造」的任务——迁移、换框架、换语言、拆服务、重做 UI——都存在一个力学问题：

**AI 的最优策略天然是最小化与现状的差异。** 那样最安全、最容易通过任何检查、最不容易被指出错误。而人要的往往是「这次顺便把它做对」。两个目标方向相反。

**不显式划线，AI 一定选照抄。** 这不是它偷懒，是它在优化你给它的可见指标。

## Rule

开工前先画**两张清单**：

| 清单 | 内容示例 | 处理方式 |
| --- | --- | --- |
| **冻结面** | 金额与计费口径、幂等语义、对外 API 契约、共享表行形状、对外触达效果 | 逐字节/逐字段等价，差分闸门**只**管这一面 |
| **自由面** | 模块拆分、命名、错误分型、告警与遥测、测试体系、内部数据结构 | 彻底放开重新设计 |

并预先约定**差异出现时的裁决程序**（三分法）：

1. **回归** —— 把该保住的行为改坏了 → 修新代码
2. **有意改良** —— 调整测试标准/基线/排除清单，**并把裁决记录在案**
3. **旧系统怪癖** —— 显式决策存废，不默认迁就，也不顺手修

比对基线要**分层**：资金/状态面字节级锁死；行为面（通知内容、审计行）语义字段级；时序/id 顺序/附加物默认可接受。

## Why

> 「差分测试只是手段，不是目的。目的永远是更专业的架构、更好的健壮性和稳定性。如果差分遇到差异，那就调整测试方式、甚至调整测试标准。」

> 「不要把旧代码当成必须照抄的真理。旧代码只是帮助理解业务规则、用户行为、数据结构和历史约束的**参考材料**。死板复制 = 迁移失败。」

把差分当法庭会扭曲新架构去迁就旧系统的缺陷——为了 diff 变绿而在新代码里复刻坏结构和坏时序，本末倒置。差分的真正价值是**把每一处差异逼到明面上，逼人做显式裁决**。

## When to use

- legacy 迁移、换框架/换语言、拆微服务、重做 UI、用 AI 重写自己旧代码。

## When not to use

- 纯新建、没有既有行为需要保住的场景。
- 明确的产品行为变更（此时冻结面本身就在改，应先更新契约）。

## Trade-offs

- 收益：既拿到重构自由，又有安全网；差异变成决策点而非噪音。
- 代价：前期要花时间画两张清单；每次调标准都要留记录。
- 已知限制：冻结面划错（划太宽=没自由，划太窄=出事）需要经验校准。

## Implementation

```text
1. 列冻结面：这些字节/字段变了就是事故
2. 列自由面：这些鼓励推翻重做
3. 建差分闸门，只比冻结面
4. 差异出现 → 三分法裁决 → 记录裁决理由和调整后的标准
```

**绝不为让差分变绿而在新代码里复刻旧结构。** 每次调标准都留记录——将来要能回答「绿是在什么标准下的绿」。

## Failure modes and anti-patterns

| Failure mode | 为什么会失败 | 如何识别 |
| --- | --- | --- |
| 全面追求逐字节等价 | 只保住下限，新系统继承全部旧缺陷 | 新代码里出现「为了对齐 diff」的注释 |
| 为让 diff 变绿改新代码结构 | 用测试反向绑架架构 | 提交里出现复刻旧耦合的改动 |
| 差异出现就默认迁就旧系统 | 把旧怪癖固化成新契约 | 没有裁决记录，只有「已对齐」 |
| 标准调了但没记录 | 将来无法回答「绿代表什么」 | 排除清单里的条目没有理由 |

## Verification

- 冻结面清单存在、可枚举，且差分工具的比对范围与它一致。
- 每一条排除项都有裁决理由和日期。
- 新架构里能指出至少一处「旧系统的缺陷被系统性解决」的地方。

## Evidence and provenance

| Project | Evidence | Verified at |
| --- | --- | --- |
| internal-project | 2026-07-27 定调；2026-08-03 明确「差分是手段不是目的」；多个迁移任务按此执行 | 2026-08-30 |

## Related practices

- [Legacy Behavior Equivalence Testing](testing/legacy-behavior-equivalence-testing.md)
- [Refactor HTML Differential Testing](testing/refactor-html-differential-testing.md)
- [Legacy Migration Decommission Strategy](legacy-migration-decommission-strategy.md)
