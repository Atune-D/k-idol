# Claude Code 协作实践套件

一套可直接安装的「人 + AI 协作」基础设施：**铁律、工程实践知识库、任务管理系统、交付文档模板、11 个 skill、审计工具。**

内容全部来自一个真实项目（十几个仓库、四个月、上百次会话）沉淀下来、并且**判定为可跨项目通用**的部分——
项目专属的技术栈知识（某语言的坑、某云厂商的配置、某业务域的规则）已全部剔除。

---

## 给 AI：怎么安装

> 把这个目录交给 Claude Code，说一句「读 README 并安装」即可。

**AI 请从 [install/INSTALL.md](install/INSTALL.md) 开始，严格按其中的步骤执行。**
那份文件包含完整的安装流程、幂等规则、冲突处理和验证步骤。不要跳过验证。

---

## 给人：装完你会得到什么

### 一、全局层（`~/.claude/`，装一次）

| 内容 | 位置 | 作用 |
|---|---|---|
| 工程实践知识库 | `~/.claude/practices/` | 20 篇 canonical 实践 + 路由索引 + 文档模板 |
| 11 个 skill | `~/.claude/skills/hao-*` | 任务管理、机制讲解、部署核验、差分测试、知识库维护 |
| 全局铁律（可选） | `~/.claude/CLAUDE.md` | 跨项目的硬约束 |

### 二、项目层（每个项目装一次）

| 内容 | 位置 | 作用 |
|---|---|---|
| 项目铁律 | `<项目>/CLAUDE.md` | 只写「不许做什么」，每次会话无条件加载 |
| 任务板 | `<项目>/docs/tasks/` | 唯一优先级视图，AI 开工前先读 Now 区 |
| 交付文档模板 | `<项目>/docs/plans/_templates/` | plan / spec / pending-confirmations 三件套 |
| 项目记忆 | `~/.claude/projects/<编码>/memory/` | 被纠正的经验就地沉淀 |

### 三、装完之后的日常

```bash
/hao-task-list      # 看优先级视图（只读）
/hao-task-next      # 下一步做什么 + 理由（只读）
/hao-task-add       # 加一条任务（默认进 Icebox，不替你排期）
/hao-task-deployed  # 部署后同步状态、收编新计划、commit
/hao-explain-only   # 用 ASCII 流程图 + 数据表示例讲清一个机制（不写文件）
/hao-explain-to-doc # 同样的解释写入项目文档
/hao-deploy-verification-checklist  # 部署前风险评估 + 部署后核验清单（绝不碰生产）
/hao-refactor-diff-test             # 重构等价性差分测试
/hao-dev-preferences-capture        # 记一条经验进 inbox（廉价、不判断）
/hao-dev-preferences-triage         # 定期把 inbox 整理成 canonical 实践
/hao-dev-preferences-setup          # 给新项目安装知识库检索规则
```

---

## 目录结构

```text
claude-code-transferable-practices/
├── README.md                  # 你在读的这份
├── install/INSTALL.md         # ← AI 从这里开始
├── MANIFEST.md                # 装了什么、装到哪、怎么卸载
├── practices/                 # → 安装到 ~/.claude/practices/
│   ├── README.md AGENTS.md PREFERENCE_INDEX.md
│   ├── foundations/           # 与 AI 协作的结构性约束 + 通用工程原则
│   ├── workflow/              # 任务管理、交付文档、汇报、skill 工艺
│   ├── backend/ devops/       # 领域实践
│   ├── templates/             # practice / field-note / inbox-note / checklist / postmortem
│   └── inbox/ field-notes/ archive/
├── skills/                    # → 安装到 ~/.claude/skills/（11 个，名字保持 hao-*）
├── project-scaffold/          # → 复制到每个项目
│   ├── CLAUDE.md
│   ├── docs/{README,tasks/*,plans/_templates/*}
│   └── memory/                # → ~/.claude/projects/<编码>/memory/
├── tools/
│   ├── audit-skill-usage.py           # 审计 skill 使用率（只读，不删）
│   └── check-broken-skill-links.sh    # 断链自检
└── reference/
    └── claude-code-transferable-practices.md   # 这套东西的完整论证：哪些通用、为什么
```

---

## 先读哪几篇

如果只有十分钟：

1. `practices/foundations/persistent-context-layers.md` —— 为什么要有这四层文件
2. `practices/workflow/reporting-to-humans.md` —— 让 AI 怎么跟你说话
3. `project-scaffold/docs/tasks/README.md` —— 任务板为什么长这样
4. `reference/claude-code-transferable-practices.md` §五 —— 落地顺序（Day 1 三件事拿到六成收益）

**不要一次性全用上。** 这套东西是四个月长出来的，不是设计出来的。
Day 1 只做三件事：写 3–5 条铁律、建一个 `active.md`（Now ≤3）、约定「被纠正的就写进记忆」。
