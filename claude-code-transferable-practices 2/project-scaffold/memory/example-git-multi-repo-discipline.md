---
name: example-git-multi-repo-discipline
description: 示例条目 — 多仓库并行操作的 git 纪律；提交必须显式 -C，禁止裸 git add -A
metadata:
  node_type: memory
  type: feedback
---

（这是一条**示例记忆**，用来演示格式。装好后按自己项目的真实情况替换或删除。）

多仓库工作区执行 git 操作的硬性纪律：

1. 凡 commit/add **必须显式 `git -C <绝对路径>`**，绝不依赖 shell 残留的 cwd。
2. **禁止裸 `git add -A`**：目标仓库可能有未提交的 WIP。
3. 提交后立即核对 `git show --stat` 的文件清单是否与意图一致。

**Why:** 曾因 cwd 残留在另一个仓库，把本应提交到文档仓库的改动 commit 过去，扫走了 4 个未提交的
WIP 文件，靠 `rebase --onto` 重写历史 + 手工恢复才修复。**记忆的价值在这一段——记事故，不记抽象规则。**

**How to apply:** 每次 Bash 里跑 git 写操作前自查目标仓库路径。相关实践：
`~/.claude/practices/foundations/concurrent-sessions-and-isolation.md`
