---
title: "Linear-based Project Task Management"
status: adopted
kind: preference
basis: preference
scope: project-management
stacks: []
versions: []
tags:
  - task-management
  - linear
  - workflow
  - issue-tracking
  - project-management
source-projects:
  - internal-project-b
created: 2026-07-19
updated: 2026-07-19
last-verified: null
supersedes: []
replaced-by: null
---

# Linear-based Project Task Management

> `basis: preference` —— 用户明确希望作为跨项目参考的任务管理默认做法。

## Rule

用 Linear 管理项目任务，把工作切成可交付的独立 issue，并遵守下列约定：

- **工具与可见性**：通过 Linear API / MCP 管理任务，让合伙人在同一 workspace 看到进展。
- **粒度**：把"一轮对话 / 一批开发工作"拆成若干独立 issue，**每个 issue 是一个可交付单元**。
- **默认 assignee = 用户本人**，除非明确指定他人。
- **描述用中文写、结构化分段**，用"映射 / 行为 / 测试 / 实跑结果 / 部署 / 待确认"等小标题；
  技术术语、字段名、命令保留英文原文。
- **标签体系**：Linear 默认只有 Bug / Feature / Improvement；按需补充领域标签
  （如 packaging / backend / frontend / migration / quote）。一个 issue 可挂多个领域标签。
- **依赖关系**：用 related / blocked-by 串联有依赖的 issue（如"展示" issue related to 提供数据字段的 issue）。
- **待决策事项也建成独立 issue**（状态 Todo + needs-decision 语义），把"待确认"清单写进描述，
  而不是散落在对话里。

### 状态语义（重要）

- **只有真正部署到生产，才能标记为 `Done`。**
- 仅在 local / dev 完成开发、尚未部署，**不能**标 `Done`；应停在中间态，并在描述里注明"dev 已完成，待部署"。
- 若 team 只有 Backlog / Todo / In Progress / Done / Canceled / Duplicate，没有 "In Review" / "Ready to Deploy"
  这类中间态，则"dev 完成待部署"暂用 **In Progress** + 描述标注。

## Why

- 部署 ≠ 完成：把 `Done` 严格绑定"已上线生产"，避免"dev 做完就当完事"的假完成，让状态如实反映交付进度。
- issue = 可交付单元 + 领域标签 + 依赖关系，使一批工作的边界、归类和先后顺序在 workspace 里一目了然，
  合伙人无需读对话即可掌握进度。
- 待决策独立成 issue，把决策从对话流里显式化，不被淹没。

## When to use

- 用 Linear 承载项目任务、且希望合伙人 / 协作方共享同一视图的项目。

## When not to use

- 不使用 Linear 的项目（改用该项目既有的任务系统，如文件承载的 `docs/tasks`）。
- 纯个人一次性、无需协作可见性的小事项。

## Trade-offs

- 收益：交付状态可信、协作透明、依赖清晰。
- 代价：维护 issue 结构与状态有一定开销；严格的 `Done` 定义意味着"看起来做完但没部署"的项要停在中间态。

## Open questions（尚未定夺）

- 是否引入自定义 "Ready to Deploy" 状态、或用 `ready-to-deploy` 标签来更精确表达"待部署"。
  当前倾向轻量：**用标签而非改 workflow**，但未最终拍板。

## Evidence and provenance

- 来源项目：另一个内部项目（使用 Linear 作为任务系统的实践来源）。
- 确立场景：本轮创建 FLU-7~FLU-10 共 4 条 issue；用户明确指出 FLU-7/FLU-8 仅 local dev 完成、
  未部署，故状态不能是 `Done` —— 这是"状态语义"约定的直接来源。
- 相关既有约定：Linear 新建 issue 默认指派本人；Linear Free plan 成员强制 Admin、无法降级 Member。

## Related practices

- 与文件承载的任务系统（如项目内 `docs/tasks/active.md` 的 Now/Next/Later/Icebox + "Deployed ≠ Done"）
  语义一致：都强调"部署才算完成、待部署要有独立中间态"。
