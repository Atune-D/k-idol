---
title: "Legacy Migration Decommission Strategy (删干净 = 全部注释)"
status: verified
kind: preference
basis: mixed
scope: cross-stack-legacy-migrations
stacks: []
versions: []
tags:
  - legacy
  - migration
  - decommission
  - sunset
  - non-destructive
  - rollback
source-projects:
  - internal-project
created: 2026-07-19
updated: 2026-07-19
last-verified: 2026-07-18
supersedes: []
replaced-by: null
---

# Legacy Migration Decommission Strategy (删干净 = 全部注释)

> `basis: mixed` —— 既是明确要求的迁移方法，也有 原项目 旧后端 → 新后端大版本迁移的落地证据。

## Context

把一个功能从旧仓库（legacy）迁到新仓库时，"迁移什么时候算成功"经常没有清晰判据，于是旧代码
长期半死不活地留着：新旧两套并行跑、谁也不敢关、也说不清还有没有人在用旧的。

## Rule

**迁移的本质，就是逐步把旧仓库的代码"删干净"的过程；只有旧代码删净了、系统还没崩，才能证明迁移成功。**

关键约定：

- **"删干净" = "全部注释"，不是物理 `rm` / 删行**。已迁走的旧代码要**整段注释停用、保留备查**
  （非破坏性、可审计、可回滚），不要物理删除文件或方法体。
- **一致地全注释**：某端点 / 任务迁走后，旧仓库那条链路要**一致地全部注释**——路由
  （如 `routes/api.php`）+ 对应 controller 方法 / 整个类都注释掉，不留"路由注释了但方法还活着"
  这种半死不活的残留死代码。
- 迁移成败的根本度量 = **旧代码注释净空后系统仍稳定运行**。旧码还大段活着 = 迁移尚未真正完成。

## Why

- **可审计**：注释保留了旧实现的原文，日后核对新旧行为、追溯"当年这里是怎么算的"时随时可查，
  物理删除会把这份历史从工作树里抹掉。
- **可回滚**：出问题时，把注释还原就能快速恢复旧路径，比从 VCS 历史里翻找、reapply 更快更稳。
- **判据清晰**：以"旧码是否已全注释且系统不崩"作为硬指标，能明确回答"迁移完成了没有"，
  避免新旧长期并存、无人敢关的僵局。
- **杜绝残留死代码**：路由与实现一致地整条注释，避免"路由注释了但方法还在、或反之"的半死状态
  ——那种状态最容易让人误判某段旧码还在服务、不敢动。

## When to use

- 把 legacy 仓库 / 旧框架的端点、定时任务、服务逐步迁移到新仓库 / 新框架。
- 任何"旧系统 sunset、由新系统接管"的渐进式退役工程。

## When not to use

- 全新功能开发，不涉及旧实现退役。
- 已确认彻底无引用、且团队达成一致要做仓库级清理的最终清扫阶段——此时可在一次专门的、
  有评审的清理中物理删除（但过渡期一律先注释）。

## Trade-offs

- 收益：非破坏性、可审计、可回滚，迁移完成度有硬判据。
- 代价：注释块会在旧仓库里留存一段时间，代码体积暂时变大、观感变"脏"——用可回溯性换安全性，
  最终清扫阶段再统一物理清理。

## Failure modes and anti-patterns

| Failure mode | 为什么会失败 | 如何识别 |
| --- | --- | --- |
| 物理 `rm` 旧代码 | 丢失可审计原文与快速回滚能力 | 迁移 diff 里是删行而非注释 |
| 只注释路由、留着方法体 | 半死不活的残留死代码，易误判仍在服务 | 路由已注释但 controller 方法仍可达 |
| 新旧长期并行、谁也不关 | 没有"删净"判据，迁移永远"差不多完成" | 旧码大段仍活着，却声称已迁移 |

## Verification

- 迁移完成的检查：旧仓库对应链路（路由 + controller/类/任务）**全部处于注释状态**，
  且新系统接管后**生产稳定、旧路径零流量**。
- 抽查：搜索旧仓库是否还有该功能未注释的活代码；有则迁移尚未收口。

## Evidence and provenance

| Project | Commit | Evidence | Verified at |
| --- | --- | --- | --- |
| internal-project (旧后端退役 → 新后端) | develop `de274d0` | SB-9（第一阶段）：旧后端 `orders/delete`、`photos/*/delete`、`photos/*/truncate` 路由 + `OrdersController` 整类 + `PhotosController` delete/truncate 方法全部注释停用，未物理删 | 2026-07-18 |

背景：原项目的多个大型迁移任务，均以"把
`legacy-backend-sunsetting` 等旧仓库逐步注释删净、系统不崩"作为迁移成功的判据。

## Related practices

- [Legacy Refactor Blast-radius Safety](testing/legacy-refactor-blast-radius-safety.md)
- [Legacy Behavior Equivalence Testing](testing/legacy-behavior-equivalence-testing.md)
- [Coding Principles / 编程原则](coding-principles.md)
