# Engineering Practices Knowledge Base

这是个人开发偏好与跨项目工程经验知识库，用于保存明确的个人选择，以及经过真实项目验证、能够在未来项目中复用的工程原则、实践模式、playbook 和 checklist。

本仓库追求的不是收集最多的文档，而是维护少量、可信、来源清晰、具有明确适用边界的 canonical knowledge。个人偏好不伪装成普适事实；经验性最佳实践也不伪装成个人审美。

## AI 检索入口

AI 在开始实现、设计、重构、review、debug、架构、文档、事故或运维任务前，先读取：

- [Practice Routing Index](PREFERENCE_INDEX.md)

索引只负责根据任务 signals 路由到相关 canonical preference，不复制规则正文。没有匹配项时无需遍历整个知识库；命中多项时需要完整读取所有匹配文档。

## 内容边界

本仓库存放：

- 能跨项目复用的工程原则与实践
- 用户明确表达、希望未来项目默认遵守的开发偏好
- 从真实事故、实现和迁移中提炼出的模式
- 可重复执行的 playbook 和 checklist
- 已脱敏、可验证的最小示例
- 实践的适用条件、trade-off、failure modes 和验证方法

本仓库不存放：

- 项目当前实现、项目专属命令或生产 runbook
- 完整的 AI skill 或 slash prompt 副本
- 未脱敏的配置、机器信息、账号、token、证书或私钥
- 未经判断而批量搬运的 session、plan、聊天记录或代码片段
- 只有结论、没有背景和证据的“最佳实践”

## 初始目录

```text
practices/
├── README.md
├── AGENTS.md
├── PREFERENCE_INDEX.md  # AI 检索路由入口
├── inbox/          # 快速捕捉尚未整理的想法
├── foundations/    # 跨技术栈的基础工程原则
├── field-notes/    # 带真实背景和证据的项目经验
└── templates/      # 标准文档模板
```

技术领域目录按真实内容逐步创建，例如：

```text
frontend/
backend/
apple/
devops/
ai-assisted-development/
examples/
archive/
```

不要为了结构完整而预建空目录。当同一领域已经有内容需要独立归类时，再创建对应目录。

## 当前 Canonical Practices

### Cross-stack foundations（与 AI 协作的结构性约束）

- [Persistent Context Layers](foundations/persistent-context-layers.md) — 四层持久层 + 四种知识载体的职责划分
- [Capability Is Not Authorization](foundations/ai-authorization-boundaries.md) — 能力 ≠ 授权；「告诉我怎么查」≠「替我去查」
- [Evidence and Verification Discipline](foundations/evidence-and-verification-discipline.md) — 专有名词必须有出处；验证性产物必须先验红
- [Frozen Surface vs Free Surface](foundations/frozen-vs-free-surface.md) — 迁移/重写的两张清单 + 差异三分法裁决
- [Concurrent Sessions: Isolation and Explicit Targeting](foundations/concurrent-sessions-and-isolation.md) — 一任务一工作副本；写操作显式指定目标
- [Coding Principles](foundations/coding-principles.md)
- [Code and File Naming Rules](foundations/code-file-naming-rules.md)
- [Legacy Migration Decommission Strategy](foundations/legacy-migration-decommission-strategy.md)
- [Incident Analysis Evidence Discipline](foundations/incident-analysis-evidence-discipline.md)

### Testing

- [Legacy Behavior Equivalence Testing](foundations/testing/legacy-behavior-equivalence-testing.md)
- [Legacy Browser Data Parity Testing](foundations/testing/legacy-browser-data-parity-testing.md)
- [Legacy Refactor Blast-radius Safety](foundations/testing/legacy-refactor-blast-radius-safety.md)
- [Refactor HTML Differential Testing](foundations/testing/refactor-html-differential-testing.md)

### Workflow

- [File-based Task Management](workflow/linear-task-management.md)
- [Plan / Spec / Pending-Confirmations](workflow/plan-spec-confirmations.md)
- [How an Agent Should Report to a Human](workflow/reporting-to-humans.md)
- [Writing Skills for Agents](workflow/writing-skills-for-agents.md)

### Backend / Data

- [Evidence-driven Query Optimization](backend/data/evidence-driven-query-optimization.md)

### DevOps

- [Layered Health Checks](devops/observability/layered-health-checks.md)
- [Production SSH Access Requires Per-action Approval](devops/production-ssh-access-boundary.md)


## 知识生命周期

```text
[ inbox ]
    |
    | 补充背景、证据、适用边界
    v
[ field-notes ]
    |
    | 在真实项目中验证并完成抽象
    v
[ canonical practice ]
    |
    | 过时或被更好的实践替代
    v
[ archive ]
```

### 状态定义

| Status | 含义 |
| --- | --- |
| `draft` | 判断合理，但证据或验证尚不充分 |
| `verified` | 已在至少一个真实项目中验证 |
| `adopted` | 已成为多个项目或工作流的默认做法 |
| `deprecated` | 不再推荐，正文必须指向替代实践 |

### 文档类型

| Kind | 用途 |
| --- | --- |
| `principle` | 跨场景、长期稳定的工程原则 |
| `pattern` | 可复用的设计或实现方式 |
| `playbook` | 面向具体目标或故障的操作流程 |
| `checklist` | 执行前后用于降低遗漏风险的核对项 |
| `field-note` | 来自具体项目、尚未完全泛化的经验记录 |
| `postmortem` | 事故事实、影响、恢复、根因和后续行动 |
| `preference` | 用户明确选择的默认做法，不声称适用于所有团队 |
| `inbox-note` | 尚未 triage 的原始偏好或实践记录 |

## 各知识载体的职责

| 载体 | 权威内容 |
| --- | --- |
| 项目仓库 | 当前实现、准确命令、项目专属架构和 runbook |
| 本仓库 | 跨项目可复用的原因、规则、边界和验证方法 |
| Skill | Agent 可以执行的工作流、判断逻辑和停止条件 |
| Slash prompt | Skill 的入口与参数转发 |

同一内容不得在多个载体中维护全文副本。项目和 skill 应链接到本仓库的 canonical practice；本仓库通过 provenance 指回产生证据的项目版本。

## 快速记录

有新偏好或经验但暂时没有时间整理时：

1. 在 `inbox/` 新建一个 kebab-case Markdown 文件。
2. 记录发生了什么、当前判断、证据在哪里、还有什么不确定。
3. 不要为了显得完整而补写未经验证的原因。
4. 后续将其整理为 `field-notes/`，或合并进已有 canonical practice。

## Canonical practice 的最低要求

一篇经验性实践在晋升为 canonical 文档前，至少需要说明：

- Context：它解决什么问题
- Rule：推荐做法是什么
- Why：为什么这样做
- When to use / not to use：适用和不适用边界
- Trade-offs：代价与限制
- Failure modes：常见失败方式
- Verification：如何证明它有效
- Provenance：来自哪个项目、commit 或事故证据

优先使用 `templates/practice.md` 创建文档。

个人偏好可以由用户的明确表达直接成立，不要求伪造项目验证。此类文档使用 `kind: preference`，并说明它是个人默认选择、适用范围以及允许例外的条件。

## 命名与版本规则

- 文件名和目录名使用 kebab-case。
- 每个文件只维护一个主题。
- 每个主题只能有一个 canonical 文档。
- 不创建 `-v2`、`-final`、`-new` 一类并行版本。
- 新 active 文档用 `supersedes` 指向它替代的旧文档。
- 被替代的旧文档标记为 `deprecated`，用 `replaced-by` 指向 active replacement，再移入 `archive/`。
- 代码或平台相关实践必须记录适用版本和最后验证日期。

## 安全规则

- 示例必须脱敏，不使用真实 IP、域名、账号、token、证书和生产配置。
- 禁止提交 `.env`、私钥、证书、provisioning profile 和 credential 文件。
- 引用生产事故时，用稳定的项目文档路径或 commit SHA 保存证据，不复制敏感原文。
- 从项目提炼内容前必须先检查 diff，避免把本地未提交状态误写成已验证事实。
