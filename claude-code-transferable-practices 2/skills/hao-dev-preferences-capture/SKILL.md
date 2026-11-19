---
name: hao-dev-preferences-capture
description: 将 用户明确要求记录的开发偏好、经验或 best practice 快速写入 `~/.claude/practices/inbox/`。仅在用户明确调用本 skill，或明确说“记录到开发偏好 inbox / practices inbox”时使用；只做忠实捕捉，不扫描已沉淀内容，不去重，不 triage，不提出改进建议。
---

# Dev Preferences Capture

## 目标

把 用户当前表达的开发偏好或经验低摩擦地保存到 inbox，留待未来集中 triage。

这个流程刻意不判断内容是否正确、是否重复、属于哪个领域或是否值得晋升。Capture 的价值是忠实和快速，而不是聪明地整理。

## 固定位置

- Knowledge base：`~/.claude/practices`
- Inbox：`~/.claude/practices/inbox`
- Template：`~/.claude/practices/templates/inbox-note.md`

只有当用户明确提供测试目录时，才可以用该目录替代固定位置。不要自行搜索名字相似的仓库。

## 执行流程

### 1. 确认输入

从 skill 调用参数和当前用户消息中提取要记录的内容。

如果没有实际内容，询问用户要记录什么，然后停止。不要替用户发明一条偏好。

### 2. 读取最低限度规则

只读取：

- 根目录 `AGENTS.md`
- `inbox/README.md`
- `templates/inbox-note.md`

不要扫描 `foundations/`、`frontend/`、`backend/`、`apple/`、`devops/`、`field-notes/`、`archive/` 或其他已沉淀内容。避免 capture 意外演变成 triage。

### 3. 保护敏感信息

写入前检查用户文本是否包含 password、token、cookie、API key、私钥、证书、真实 credential 或其他明显 secret。

- 能安全脱敏时，用 `[REDACTED:<type>]` 替换真实值，并保留其工程语义。
- 脱敏会让记录失去核心含义时，不写入原值；告诉用户需要提供脱敏版本。
- 普通技术名称、公开版本号和非敏感路径不需要过度脱敏。

### 4. 创建独立 inbox note

每次调用只新增一个文件，不修改或合并已有 note。

文件名：

```text
YYYY-MM-DD-HHMMSS-short-kebab-case-slug.md
```

使用 `America/Vancouver` 当前时间。发生同秒重名时追加 `-02`、`-03`。

按模板写入：

- `title`：对原始内容的中性短标题
- `status: untriaged`
- `kind: inbox-note`
- `captured-at`：带时区的 ISO 8601 时间
- `source: user`
- `sensitive-data: none|redacted`
- `Raw note`：尽可能忠实保留用户的表达
- `Supplied context`：只保留用户明确给出的背景；没有则写“未提供”

允许修正明显的语音转写符号或断句，但不要改变观点强度，不要添加理由，不要把“我偏好”改写成“业界必须”。

### 5. 验证写入边界

执行 `git status --short` 和必要的 diff 检查，确认：

- 本次只新增一个 `inbox/*.md`
- 没有修改任何 canonical 文档
- frontmatter 字段完整
- 文件中没有疑似 secret

仓库原有未提交修改属于用户，不要修改、撤销或声称由本次产生。

### 6. 汇报

只需告诉用户：

- 已记录
- 新文件路径
- 是否做了脱敏

不要在汇报中顺便 triage、评价、扩展或建议沉淀位置。

## 严格禁止

- 不调用或模拟 `hao-dev-preferences-triage`
- 不搜索已有实践来判断重复或冲突
- 不把内容直接写入 canonical 目录
- 不修改、覆盖、合并或删除已有 inbox note
- 不因为内容看起来简单就拒绝记录
- 不自动 commit
