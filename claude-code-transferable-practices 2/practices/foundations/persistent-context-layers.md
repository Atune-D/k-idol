---
title: "Persistent Context Layers for AI Collaboration"
status: adopted
kind: principle
basis: mixed
scope: cross-stack
tags: [ai-collaboration, context, knowledge-architecture]
source-projects: [internal-project]
created: 2026-08-30
updated: 2026-08-30
last-verified: 2026-08-30
---

# Persistent Context Layers for AI Collaboration

## Context

AI 会话没有跨会话记忆。人靠脑子累积经验，AI 只能靠读文件。不建外部持久层，你会每周把同一件事解释一遍——而且是无声的损耗，你甚至不会意识到自己在重复。

## Rule

把判断力外化成**四层文件**，分层依据是「变化频率 × 作用域 × 内容性质」：

| 层 | 变化频率 | 作用域 | 内容性质 | 落地位置 |
| --- | --- | --- | --- | --- |
| 铁律 | 几乎不变 | 全局 | **约束**（不许做什么） | `~/.claude/CLAUDE.md`、项目根 `CLAUDE.md` |
| 记忆 | 被纠正的当场 | 单项目 | **事故与偏好** | `~/.claude/projects/<项目>/memory/` |
| 知识库 | 定期 triage | 跨项目 | **经验实践**（有边界、有验证状态） | `~/.claude/practices/` |
| 任务板 | 每天 | 单项目 | **状态** | `<项目>/docs/tasks/` |

并且区分**四种知识载体**的职责，不得在多者之间维护全文副本：

| 载体 | 权威内容 |
| --- | --- |
| 项目仓库 | 当前实现、准确命令、项目专属架构和 runbook |
| 知识库 | 跨项目可复用的**原因、规则、边界和验证方法** |
| Skill | Agent 可执行的**工作流、判断逻辑和停止条件** |
| Slash prompt | Skill 的入口与参数转发 |

需要共享时用链接，并明确哪一份是 SSOT。

## Why

- **分层依据不是主题，是变化频率和作用域。** 不分层就会出现一个巨大的 `CLAUDE.md` 什么都往里塞：既是项目介绍、又是编码规范、又是操作手册，最后大到没人敢删任何一行，而 AI 每次会话都要整个读一遍。
- **上下文是竞争性资源。** 被文档吃掉的额度不能用来读代码和思考；无关内容还会稀释真正重要的约束。
- **四载体划分的依据是「谁在什么时候需要它」**：项目实现是写代码时按需读的，跨项目规则是决策时路由到的，skill 是被显式调用时加载的，slash 只是个入口。混在一起 = 全部变成常驻成本。

## When to use

- 任何会持续两周以上、且你会反复和 AI 协作的项目。
- 出现「我上次好像也说过这个」的感觉时，说明该建这一层了。

## When not to use

- 一次性脚本、探索性问答。
- 四层不必一次建齐：先铁律 + 任务板，知识库等到同一条经验在**第二个项目**里又需要时再建。

## Trade-offs

- 收益：指令可以极短（实测某项目 prompt 长度中位数 60 字符），复杂度由常驻文件承载。
- 代价：每一层都有维护成本；任务板和记忆会变大，需要定期归档。
- 已知限制：知识库的 triage 是高判断成本操作，会被拖延。

## Implementation

任何常驻上下文的文件都要拆成「索引层 + 内容层」，AI 先读索引再按需读内容：

- 记忆：`MEMORY.md` 一条一行 → 指向单文件
- 知识库：`PREFERENCE_INDEX.md` 路由表 → 指向 canonical 文档
- 任务板：`active.md` 一个战役一行 → 外链到 plan 文档

## Failure modes and anti-patterns

| Failure mode | 为什么会失败 | 如何识别 |
| --- | --- | --- |
| `CLAUDE.md` 写成项目介绍 | 它是每次会话无条件加载的，只配放密度极高的约束 | 文件超过 100 行、包含技术栈说明 |
| 记忆写成抽象规则 | 不带代价的规则会被 AI 合理化绕过 | 记忆里没有 `Why:` 段、没有具体日期和事故 |
| 索引里复制规则正文 | 索引一旦变成第二份真相源就会漂移 | 索引条目超过两行 |
| 四载体互相复制全文 | AI 遇到两份不一致不会报错，会挑一份 | 同一规则在 skill 和知识库各有一份完整正文 |

## Verification

- 随机挑一条规则，确认它在四层里**只有一处全文**，其余是链接。
- 新会话开始时，AI 是否能只读索引就知道该读哪几篇。
- `CLAUDE.md` 是否只包含「不许做什么」。

## Evidence and provenance

| Project | Evidence | Verified at |
| --- | --- | --- |
| internal-project | 4 层持久层运行约 4 个月；85 条项目记忆 + 18 篇 canonical 实践 | 2026-08-30 |

## Related practices

- [Writing Skills for Agents](../workflow/writing-skills-for-agents.md)
- [File-based Task Management](../workflow/linear-task-management.md)
