---
title: "Writing Skills for Agents"
status: adopted
kind: pattern
basis: mixed
scope: cross-stack
tags: [skills, agent-instructions, tooling, maintenance]
source-projects: [internal-project]
created: 2026-08-30
updated: 2026-08-30
last-verified: 2026-08-30
---

# Writing Skills for Agents / 写给 Agent 的可复用指令

## Context

Skill 是「给 AI 反复执行的一段指令」。写法有独立于内容的工艺；工艺不对，skill 会漂移、误触发、或悄悄执行错的版本。

## Rule

### 五条工艺

1. **规范与执行分离。** Skill 只写「怎么做」，规范正文放知识库，skill 去读它。在 skill 里显式声明：「该文件是本 skill 的**唯一规范真相源**，本 skill 不复制其内容，以防两处维护脱节。」
2. **只读的明确声明只读。** 在正文写死「绝不改文件、绝不 commit、绝不执行任务」。
3. **默认落在最保守的位置。** 例：新任务默认进 Icebox，不替用户排期。
4. **不确定就问，不猜。** 「多个候选 → 列出候选问用户，不猜」。
5. **解析要宽容。** 中英文混用、空格多少、全角/半角冒号、`vs`/`VS`/`对比` 都要能认——人不会按格式敲命令。

### 命名

自建 skill 统一加**个人前缀**（本套件用 `hao-`），无例外。第三方 skill 也会用 `task-*`、`review-*` 这类通用名，不加前缀会混淆。

### 数量控制

**删掉不用的 skill，理由不是磁盘，是「描述污染」。**

每个 skill 的 `description` 都会进入模型选择 skill 时的候选判断。无用 skill 越多，误触发和漏触发都越多——语义相近的一堆第三方 skill 会稀释掉你自己那个精准 skill 的命中率。**「留着不用反正不占地方」是错的：它占的是每次会话的判断预算。**

## Why

- 复制规范正文比链接容易，但会立刻产生第二份真相源。**AI 遇到两份不一致的规范不会报错，它会挑一份执行，而你不知道它挑了哪份。**
- 只读声明让「我就想问问下一步该干嘛」变成廉价动作，不必担心 AI 顺手改了东西。
- 实测某环境 207 个 skill 中 180 天内真正用过的只有 69 个（33%）。

## When to use

- 一件事你每天做两遍以上、步骤固定、每次都要重新解释一遍时。

## When not to use

- 只做过一次的事。先做，第二次再考虑固化。

## Trade-offs

- 收益：流程可重复、判断标准稳定。
- 代价：skill 会随项目演进失效，维护它不漂移是真实成本。
- 已知限制：skill 越多，选择准确率越低。

## Implementation

审计 skill 使用率必须取**三层证据**，缺一层就会误删：

| 层 | 数据源 | 抓得到 | 抓不到 |
| --- | --- | --- | --- |
| 1 | 输入历史里的 slash 命令 | 手敲调用 | 模型自动触发的 |
| 2 | 会话记录里的 skill 工具调用 | 模型自动触发 | 超出保留期的历史 |
| 3 | skill 之间的互相引用 | 被别的 skill 调用的「零件」 | — |

三个坑：

- **只看第 1 层会误删自动触发的 skill。** 实测有 3 个 skill 手敲次数为 0、自动触发 10 次以上。
- **引用检测要收紧**：只认显式调用语法（`/name`、`skills/name`、`` `name` ``、`[[name]]`），否则 `setup`、`review`、`spec` 这类英文常用词会假阳性泛滥。
- **必须做传递闭包**：`A(在用) → B → C`，只查一层会删掉 C。**还要检查软链**，被在用软链指向的目标不能删。

删除前：全量 tar 备份；自己写的和第三方装的分开报告。

本套件附带脚本：`tools/audit-skill-usage.py`。

## Failure modes and anti-patterns

| Failure mode | 为什么会失败 | 如何识别 |
| --- | --- | --- |
| skill 里复制规范正文 | 两处维护必然漂移 | 同一规则在 skill 和知识库各有全文 |
| 只读 skill 未声明只读 | AI 顺手改文件 | 只是问一句，回来发现文件变了 |
| 不加个人前缀 | 与第三方同名混淆 | 触发了不是你写的那个 |
| 按频率删 skill 未做闭包 | 断掉被间接依赖的零件 | 某个在用 skill 中途报找不到子步骤 |
| 删掉软链目标 | 在用软链变断链 | `readlink` 指向不存在的路径 |

## Verification

- 每个 skill 的规范正文只有一处；其余是链接。
- 只读类 skill 跑一遍，`git status` 无变化。
- 清理后跑断链自检，无输出。

## Evidence and provenance

| Project | Evidence | Verified at |
| --- | --- | --- |
| internal-project | 2026-08-30 实测审计：207 → 159，其中软链误删一次并从备份恢复 | 2026-08-30 |

## Related practices

- [Persistent Context Layers](../foundations/persistent-context-layers.md)
