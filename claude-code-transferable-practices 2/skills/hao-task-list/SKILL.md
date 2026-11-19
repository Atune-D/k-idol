---
name: hao-task-list
description: 展示当前项目 docs/tasks 的优先级视图（active.md 的 Now/Next/Later + 已拆分则含 icebox.md）。当用户输入 "/hao-task-list" 或问"现在有哪些任务/待办/优先级怎么排"时触发。只读，不修改任何文件。仅在项目采用 docs/tasks 文件式任务系统时适用。
---

# hao-task-list

展示 `docs/tasks/active.md` 的优先级视图。**只读，不改文件。**

## 前提：定位任务系统

从当前工作目录向上查找 `docs/tasks/active.md`。找不到 → 告知用户本项目未采用 `docs/tasks` 系统（可提示用 `docs-init` 建立），结束。

## 执行步骤

1. 读 `docs/tasks/active.md`；README 声明 Icebox 拆分为 `icebox.md` 的项目（部分项目会把 Icebox 拆成独立文件以减小上下文体积），一并读取。
2. 按分区顺序呈现：**Now → Next → Later → Icebox**。区内保持文件里的行序（**行序即优先级**，不要重排）。Icebox 条目多时（如 >15 条）默认只报条数 + 前几条，用户要全量再展开。
3. 每条给：ID、名称、状态、（有依赖时）依赖简述。**重点突出 Now 区**（当前主攻）。
4. 可选：用户要的话，附 `completed.md` 最近几条终态。
5. 不修改任何文件。

## 输出格式（示例）

```
📋 Active — 优先级视图

## Now（主攻，≤3）
- T-1 **计费模块改造** · Deployed · 双方

## Next
- T-2 定时任务迁移 Batch 1 · In Progress
- T-3 管理后台迁移 · In Progress

## Later
- T-4 预约档期表拆分 · Planned

## Icebox
- T-7 维护模式 · Backlog
```

## 注意

- 只展示不执行；细节看"详情"列的链接，本命令不展开。
- 想知道"下一步做哪个" → 引导用户用 `/hao-task-next`。
- 全程用中文。
