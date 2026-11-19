# Practice Routing Index

这是本知识库面向 AI 的检索入口。

**它是 router，不是第二份真相源。** 链接指向的 canonical 文档才包含完整规则、证据、边界和例外。

## AI Retrieval Contract / AI 检索契约

在开始实现、设计、重构、review、debug、架构、文档、事故或运维工作之前：

1. 读本文件。
2. 用当前任务匹配 `Task signals` 与 `Must read when`。
3. **完整读取**每一篇命中的 canonical 文档，再动手。
4. `adopted` 与 `verified` 条目作为默认做法执行。
5. `draft` 条目只是上下文，仍需验证。
6. **没有命中时，不要遍历知识库**——直接继续工作。
7. `inbox/`、`field-notes/`、`archive/`、`templates/` **一律不算生效规范**，除非用户明确要求查看。

### 优先级链

```text
当前用户明确指令
  > 当前项目事实与项目级 CLAUDE.md / AGENTS.md 规则
  > 命中的 canonical practice
  > 框架默认与通用惯例
```

命中的实践与项目约束冲突时：**暴露冲突，保留项目约束，等用户决定。不许静默覆盖任何一方。**

## Routing Table

| ID | Task signals | Must read when | Skip when | Status | Canonical |
| --- | --- | --- | --- | --- | --- |
| `context-layers` | AI 协作、记忆、CLAUDE.md、知识库、上下文、索引、skill 该放哪 | 建立或调整项目的 AI 协作文件结构时 | 一次性问答 | `adopted` | [foundations/persistent-context-layers.md](foundations/persistent-context-layers.md) |
| `authorization` | 生产、部署、ssh、删除、不可逆、权限、排查、"帮我查一下" | 任何触及生产或不可逆动作的请求 | 纯本地可重建沙箱 | `adopted` | [foundations/ai-authorization-boundaries.md](foundations/ai-authorization-boundaries.md) |
| `evidence` | 命令清单、表名、字段名、配置键、测试汇报、经验总结、监控判据 | 输出任何含专有名词的清单，或汇报测试结果 | 明确标注为草图的头脑风暴 | `verified` | [foundations/evidence-and-verification-discipline.md](foundations/evidence-and-verification-discipline.md) |
| `frozen-free` | 迁移、重写、换框架、换语言、拆服务、重做 UI、差分、等价性 | 基于既有系统做改造，且承诺部分行为不变 | 纯新建、无既有行为 | `verified` | [foundations/frozen-vs-free-surface.md](foundations/frozen-vs-free-surface.md) |
| `concurrency` | git commit、多仓库、worktree、并发会话、测试库、cwd、add -A | 执行 git 写操作，或同时开多个会话 | 单会话且工作区干净（仍建议遵守） | `verified` | [foundations/concurrent-sessions-and-isolation.md](foundations/concurrent-sessions-and-isolation.md) |
| `coding-principles` | 实现、功能、重构、review、可维护性、架构、文件大小 | 写或改生产代码、测试、代码结构 | 纯内容编辑 | `adopted` | [foundations/coding-principles.md](foundations/coding-principles.md) |
| `naming` | 命名、重命名、文件、目录、类、函数、API 字段、DTO、schema、数据库列 | 引入或修改业务面命名 | 只改散文错别字 | `adopted` | [foundations/code-file-naming-rules.md](foundations/code-file-naming-rules.md) |
| `decommission` | legacy 退役、下线、旧代码删除、迁移收尾 | 判断"迁移是否完成"、处置旧代码 | 未开始迁移 | `verified` | [foundations/legacy-migration-decommission-strategy.md](foundations/legacy-migration-decommission-strategy.md) |
| `incident-evidence` | 事故、故障、postmortem、根因、时间线、供应商说明 | 写或 review 因果结论、时间线、事故定论 | 不作因果声明的例行状态更新 | `verified` | [foundations/incident-analysis-evidence-discipline.md](foundations/incident-analysis-evidence-discipline.md) |
| `legacy-equivalence` | 行为等价、等价重构、性能优化、eager loading、批量化 | legacy 重构承诺可观察行为不变 | 有意的产品行为变更且已批准新契约 | `verified` | [foundations/testing/legacy-behavior-equivalence-testing.md](foundations/testing/legacy-behavior-equivalence-testing.md) |
| `legacy-blast-radius` | 共享模板、共享组件、共享 helper、框架迁移、大型重构 | 共享产物可能影响多个入口或间接消费方 | 只有一个已证明消费方的孤立改动 | `verified` | [foundations/testing/legacy-refactor-blast-radius-safety.md](foundations/testing/legacy-refactor-blast-radius-safety.md) |
| `browser-parity` | 浏览器对比、数据一致、UI 迁移、后台迁移、e2e 比对 | 比较新旧真实页面，UI 可变但业务数据须一致 | 无页面的纯代码层等价 | `verified` | [foundations/testing/legacy-browser-data-parity-testing.md](foundations/testing/legacy-browser-data-parity-testing.md) |
| `html-diff` | 纯重构、HTML 一致、差分测试、字节一致、读路径回归 | 验证纯重构后 HTML 渲染逐字节不变 | 有意的数据/UI 变更 | `verified` | [foundations/testing/refactor-html-differential-testing.md](foundations/testing/refactor-html-differential-testing.md) |
| `task-management` | 任务、优先级、待办、下一步、backlog、看板、已部署 | 新增/排序任务，或部署后同步状态 | 项目未采用 docs/tasks 系统 | `adopted` | [workflow/linear-task-management.md](workflow/linear-task-management.md) |
| `delivery-docs` | plan、spec、开发文档、范围、待确认、交付、验收 | 启动跨多天、多模块的工作，或收官交付 | 单次小改动 | `adopted` | [workflow/plan-spec-confirmations.md](workflow/plan-spec-confirmations.md) |
| `reporting` | 汇报、提问、让用户选、术语、编号、测试结果表述 | 所有面向人的输出 | Agent 间的机器可读输出 | `adopted` | [workflow/reporting-to-humans.md](workflow/reporting-to-humans.md) |
| `skill-craft` | 写 skill、slash 命令、agent 指令、skill 清理、误触发 | 新建/修改 skill，或审计 skill 使用率 | 只做过一次的事 | `adopted` | [workflow/writing-skills-for-agents.md](workflow/writing-skills-for-agents.md) |
| `query-optimization` | N+1、慢查询、eager loading、SQL 计数、分页、索引、EXPLAIN | 诊断或修改数据库查询行为 | 性能问题尚未定位到数据库 | `verified` | [backend/data/evidence-driven-query-optimization.md](backend/data/evidence-driven-query-optimization.md) |
| `health-checks` | 健康检查、可用性、监控、告警、依赖探测、业务心跳 | 设计或修改生产健康信号与告警 | 无可用性要求的本地工具 | `verified` | [devops/observability/layered-health-checks.md](devops/observability/layered-health-checks.md) |
| `production-ssh` | ssh、生产服务器、登录、只读排查 | 请求涉及登录生产环境 | 无生产环境 | `adopted` | [devops/production-ssh-access-boundary.md](devops/production-ssh-access-boundary.md) |
