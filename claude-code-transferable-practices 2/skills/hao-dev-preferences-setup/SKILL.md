---
name: hao-dev-preferences-setup
description: 为任意项目安装或同步 个人开发偏好检索规则到项目根目录的 `AGENTS.md` 和/或 `CLAUDE.md`。当用户明确要求“在这个项目启用用户 preferences”“加入 preference index 规则”“配置 practices”或调用本 skill 时使用；以幂等 marker 管理规则块，保留项目原有内容，遇到未标记且冲突的旧规则时暂停确认，绝不静默覆盖。
---

# Dev Preferences Setup

## 目标

让项目里的 AI agent 在实现、设计、重构、审查或文档任务前，先通过
`~/.claude/practices/PREFERENCE_INDEX.md` 做轻量路由，只读取命中的
canonical preference，而不是遍历整个知识库。

这是一个显式安装流程。只有用户明确要求为某个项目安装、启用或同步规则时才修改文件；
普通开发任务不能触发项目指令文件写入。

## 定位项目与目标文件

按以下优先级确定项目根目录：

1. 用户明确给出的目录
2. 当前目录所属 Git 仓库的 `git rev-parse --show-toplevel`
3. 当前目录（仅当它不属于 Git 仓库）

只处理项目根目录，不递归修改子目录中的 agent 指令文件。

- 根目录存在 `AGENTS.md`：处理它。
- 根目录存在 `CLAUDE.md`：处理它。
- 两者都存在：两者都处理，保持 Codex 与 Claude 的入口一致。
- 两者都不存在：创建根目录 `AGENTS.md`。

用户明确限定目标文件时遵循其限定，不额外修改另一个文件。文件名按实际大小写精确匹配，
不要把嵌套目录里的同名文件当成根级入口。

## 托管规则块

使用下面两个稳定 marker 管理本 skill 写入的内容：

```text
<!-- hao-dev-preferences:start -->
<!-- hao-dev-preferences:end -->
```

marker 之间写入以下 canonical block：

```markdown
<!-- hao-dev-preferences:start -->
## 用户 Preference Retrieval Policy

开始实现、设计、重构、审查或文档任务前：

1. 读取 `~/.claude/practices/PREFERENCE_INDEX.md`。
2. 根据当前任务的 `Task signals` 和 `Must read when` 找出全部匹配项。
3. 只完整读取命中的 canonical preference；不要只读摘要或局部片段。
4. 没有匹配项时继续正常工作，不遍历整个知识库。
5. 不把 `inbox/`、`field-notes/`、`archive/` 或 templates 当作 active preference，除非用户明确要求检查。

优先级：当前用户明确指令 > 当前项目事实和项目级规则 > 命中的用户 preference > 通用默认做法。

如果 preference 与当前项目约束冲突，明确指出冲突并保留项目约束，等待用户决定；不要静默覆盖任何一方。

例外：明确调用 `hao-dev-preferences-capture` 时遵循该 skill 的最低读取边界，不读取 preference index，也不触发 triage。
<!-- hao-dev-preferences:end -->
```

如果新建空的 `AGENTS.md`，可以把标题改为一级标题 `# 用户 Preference Retrieval Policy`；
其余语义和 marker 保持不变。

## 安装与同步流程

### 1. 检查现场

- 确认项目根目录真实存在。
- 读取所有目标文件的完整内容。
- 若项目是 Git 仓库，执行 `git status --short`，记录开始前已有修改。
- 不要求干净工作树，不撤销或整理用户已有改动。

### 2. 判断当前状态

对每个目标文件独立判断：

- **无 marker、无 index path**：在文件末尾追加一个空行和托管规则块。
- **完整且唯一的一对 marker**：只替换 marker 之间的内容，使其与 canonical block 同步。
- **marker 不完整、交错或出现多对**：停止修改该项目并报告结构问题。
- **无 marker，但已经出现 index path**：不要追加重复规则。检查现有规则是否完整覆盖 canonical block 的检索边界、优先级和冲突处理。
  - 语义完整且不冲突：保留原文，报告 `already-configured-unmanaged`。
  - 缺失关键边界、语义含糊或与 canonical block 冲突：停止修改该项目，请用户决定保留旧规则、采用托管块，还是合并边界。

只要任一目标文件存在需要用户决定的冲突，先完成只读检查，但本轮不修改任何目标文件，
避免 `AGENTS.md` 已更新而 `CLAUDE.md` 尚未确认的半完成状态。

### 3. 最小写入

- 使用 `apply_patch` 创建或更新目标文件。
- 保留 marker 以外的全部原有内容、换行风格和文件职责。
- 不把规则复制到 README、docs 或嵌套 agent 文件。
- 不自动 commit。

### 4. 验证幂等性

写入后验证每个托管目标：

- `hao-dev-preferences:start` 和 `hao-dev-preferences:end` 各出现一次且顺序正确。
- preference index 的绝对路径在托管块内出现一次。
- 五个检索步骤、优先级、冲突规则与 capture 例外都存在。
- marker 外的原内容未被改变。
- 再次按本 skill 计算结果不会产生 diff。

若为 Git 仓库，再检查 `git diff -- AGENTS.md CLAUDE.md` 与 `git status --short`，确认没有修改
目标之外的文件。项目原有未提交修改属于用户，不能声称由本轮产生。

## 最终汇报

简洁列出：

- 项目根目录
- 每个目标文件的结果：`created`、`updated`、`already-configured` 或 `already-configured-unmanaged`
- 幂等与边界验证结果
- 任何未修改的冲突及需要用户决定的具体问题

不要自动执行 preference triage，也不要顺便修改 knowledge base。
