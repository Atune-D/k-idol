---
title: "Concurrent AI Sessions: Isolation and Explicit Targeting"
status: verified
kind: pattern
basis: evidence
scope: cross-stack
tags: [git, concurrency, worktree, isolation, safety]
source-projects: [internal-project]
created: 2026-08-30
updated: 2026-08-30
last-verified: 2026-08-30
---

# Concurrent Sessions: Isolation and Explicit Targeting

## Context

只要你同时开两个 AI 会话——现在几乎是必然——共享可变状态就是竞态。有两个坑是 AI 场景特有的：

1. **cwd 是隐式全局变量。** AI 通过 shell 工作，shell 的 cwd 会在调用之间残留。
2. **AI 倾向于用「全选」式命令**（`add -A`、`rm -rf`、`--force`），因为它们更简洁、更少出错——在单人单会话下确实如此，在并发下是灾难。

## Rule

1. **给每个并行任务一份可丢弃的私有工作副本**：git worktree / 独立分支 / 容器 / 独立数据库。命名把上下文写进去：`worktree-<任务号>-<仓库>`、`db_testing_<任务号>`。
2. **所有写操作显式指定目标，不依赖任何隐式上下文**（cwd、当前分支、默认库、默认账号）。git 一律 `git -C <绝对路径>`。
3. **禁止裸 `git add -A`。** 逐文件 add 或 add 指定目录。
4. **写完立即核对影响范围**：`git show --stat`，确认文件清单与意图一致。
5. **改共享文件前先读再改**，保留其他会话的改动。
6. 多语句 shell 中每条写命令**独立自查**，不依赖上一行的 `cd` 或 `&&`。

## Why

真实事故（两次，同一个错）：

- 第一次：cwd 残留在另一个仓库，把本应提交到文档仓库的改动 commit 过去，**扫走了 4 个未提交的 WIP 文件**，靠 `rebase --onto` 重写历史 + 手工恢复才修复。
- 第二次：shell 里 heredoc 之后换行再写 git 命令——**heredoc 与后续行是独立语句**，前面失败不会短路后面的 git；裸 `add -A` 又继承了残留 cwd，再次扫走 WIP。

并发测试库同样会互踩：两个会话共用一个测试库会互相清表，满屏「假红」，根本无法定责。

## When to use

- 任何时候你可能同时跑两个会话；或仓库里存在你自己的未提交 WIP。

## When not to use

- 单人单会话且工作区干净时，纪律仍建议保留（成本极低）。

## Trade-offs

- 收益：消除整类「改错仓库 / 扫走别人改动 / 假红」问题。
- 代价：worktree 占磁盘；命令更啰嗦。
- 已知限制：worktree 需要额外初始化（如测试环境配置文件），漏了会导致大批无关测试假红。

## Implementation

```bash
# 建隔离工作副本
git -C <repo> worktree add ../worktree-t42-<repo> -b feat/t-42

# 写操作显式指定目标
git -C /abs/path/to/repo add docs/tasks/active.md
git -C /abs/path/to/repo commit -m "..."
git -C /abs/path/to/repo show --stat
```

清理软链型资源前先列出所有软链及其指向，删完自检断链：

```bash
for f in *; do [ -L "$f" ] && [ ! -e "$f" ] && echo "断链: $f -> $(readlink "$f")"; done
```

## Failure modes and anti-patterns

| Failure mode | 为什么会失败 | 如何识别 |
| --- | --- | --- |
| 依赖残留 cwd | cwd 是隐式全局变量 | commit 出现在意料之外的仓库 |
| 裸 `add -A` | 卷入他人 WIP | `git show --stat` 出现你没改过的文件 |
| heredoc 后续行未短路 | 独立语句，前者失败不影响后者 | 脚本报错但 git 仍然提交了 |
| 共用测试库 | 互相清表 | 测试结果在两次运行间随机漂移 |
| 新工作副本缺环境配置 | 连不上测试库 / 表不存在 | 大批与改动无关的测试同时变红 |

## Verification

- 每次提交后 `git show --stat` 与意图核对。
- 并发跑两个会话的测试，结果稳定不漂移。
- 清理类操作后跑一次断链自检。

## Evidence and provenance

| Project | Evidence | Verified at |
| --- | --- | --- |
| internal-project | 2026-07-10 与 2026-07-11 两次污染提交事故；测试库互踩；软链清理断链 | 2026-08-30 |

## Related practices

- [Capability Is Not Authorization](ai-authorization-boundaries.md)
