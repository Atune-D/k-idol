# 清单：装了什么、装到哪、怎么卸载

## 安装映射

| 来源 | 目标 | 时机 | 覆盖策略 |
|---|---|---|---|
| `practices/` | `~/.claude/practices/` | 全局，一次 | 已存在则逐文件比较，只补缺失 |
| `skills/hao-*` | `~/.claude/skills/hao-*` | 全局，一次 | 同名跳过，报给用户 |
| `project-scaffold/CLAUDE.md` | `<项目>/CLAUDE.md` | 每项目 | 已存在则**只提示不覆盖** |
| `project-scaffold/docs/tasks/*` | `<项目>/docs/tasks/` | 每项目 | 逐文件 `-n` |
| `project-scaffold/docs/README.md` | `<项目>/docs/README.md` | 每项目 | 逐文件 `-n` |
| `project-scaffold/docs/plans/_templates/*` | `<项目>/docs/plans/_templates/` | 每项目 | 逐文件 `-n` |
| `project-scaffold/memory/*` | `~/.claude/projects/<路径编码>/memory/` | 每项目 | 逐文件 `-n` |
| `tools/*` | 不安装，原地运行 | — | — |

## Skills 清单（11 个，名字不变）

| Skill | 作用 | 写文件？ |
|---|---|---|
| `hao-task-add` | 分析后把一条任务并入任务板，默认进 Icebox | 写 |
| `hao-task-list` | 展示 Now/Next/Later/Icebox 优先级视图 | **只读** |
| `hao-task-next` | 给出一个最优先动作 + 理由 | **只读** |
| `hao-task-deployed` | 部署后同步状态、收编新 plan、commit | 写 |
| `hao-explain-only` | ASCII 流程图 + 数据表示例讲清一个机制 | **只读** |
| `hao-explain-to-doc` | 同样的解释写入项目文档，对话只回 path | 写 |
| `hao-deploy-verification-checklist` | 部署前风险评估 + 部署后手工核验清单 | **只读**（绝不碰生产） |
| `hao-refactor-diff-test` | 重构等价性差分测试（HTML / backend 两种模式） | 跑测试，写报告 |
| `hao-dev-preferences-capture` | 记一条经验进知识库 inbox | 写 inbox |
| `hao-dev-preferences-triage` | 把 inbox 整理成 canonical 实践 | 写知识库 |
| `hao-dev-preferences-setup` | 给项目安装知识库检索规则（幂等 marker） | 写项目指令文件 |

## Canonical 实践清单（20 篇）

见 `practices/README.md` 的「当前 Canonical Practices」与 `practices/PREFERENCE_INDEX.md` 的路由表。

分布：`foundations/` 9 篇（含与 AI 协作的 5 条结构性约束）、`foundations/testing/` 4 篇、
`workflow/` 4 篇、`backend/` 1 篇、`devops/` 2 篇。

## 卸载

```bash
# 全局
rm -rf ~/.claude/practices
for s in hao-task-add hao-task-list hao-task-next hao-task-deployed \
         hao-explain-only hao-explain-to-doc hao-deploy-verification-checklist \
         hao-refactor-diff-test hao-dev-preferences-capture \
         hao-dev-preferences-triage hao-dev-preferences-setup; do
  rm -rf ~/.claude/skills/"$s"
done

# 项目层：这些是你自己的内容，请自行判断后手动删
#   <项目>/CLAUDE.md
#   <项目>/docs/tasks/  <项目>/docs/plans/_templates/  <项目>/docs/README.md
#   ~/.claude/projects/<路径编码>/memory/
```

卸载后跑一次断链自检：`tools/check-broken-skill-links.sh`。

## 不包含什么（刻意剔除）

以下内容是**项目专属**的，判定为不可跨项目通用，已从本套件剔除：

- 特定语言/框架的坑（如某版本的浮点舍入行为、某 ORM 的陷阱）
- 特定云厂商、支付/消息供应商的配置与流程
- 原项目的任务编号、域名、设计系统、数据库名
- 生活任务管理、图片处理流水线等与工程无关的 skill
- 原项目的 `docs/infra`、`runbook`、事故记录等运维实体内容

判定依据与完整论证见 `reference/claude-code-transferable-practices.md`。
