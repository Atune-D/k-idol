---
name: hao-task-add
description: 把一条任务按当前项目 docs/tasks 系统的规则，分析后合理并入任务板（active.md，或已拆分的 icebox.md）。当用户输入 "/hao-task-add <任务>" 或说"加个任务/记一条 task/建个 task：xxx"时触发。会读 docs/tasks/README.md 规则 + active.md/icebox.md 现状，拟出条目（ID、状态、分区、依赖、详情），经用户确认后写入并在 docs 仓库 commit。仅在项目采用 docs/tasks 文件式任务系统时适用。
---

# hao-task-add

把用户给的一条任务，**先分析、再按规则合理并入** 当前项目的 `docs/tasks/active.md`。不是把原话直接塞进去。

## 前提：定位任务系统

从当前工作目录向上查找 `docs/tasks/active.md` 与 `docs/tasks/README.md`（`find . -maxdepth 4 -path '*/docs/tasks/active.md'`）。

- 找到 → 继续。
- 找不到 → 告知用户本项目未采用 `docs/tasks` 系统，问要不要先按 `docs-init` 建，或改用简单清单。**不擅自新建目录结构。**

## 执行步骤

1. **读规则与现状（必读，别凭记忆）**
   - `docs/tasks/README.md`：ID 规则、状态取值、分区语义、工作流约定——**以它为准**（不同项目规则可能不同）。
   - `docs/tasks/active.md`：现有条目、各分区结构；README 声明 Icebox 已拆分的（部分项目拆成独立的 `tasks/icebox.md`），一并读取。
   - **最大 ID 必须横跨全库取**：`active.md` + `icebox.md`（如有）+ `completed.md` 一起扫（ID 永不复用，最大号可能在已归档或未承诺条目里）。

2. **分析这条任务（关键步）**
   - **类型**：跨多周、需独立 plan 文档的大工程 = Initiative；一次性事项 = Task。
   - **状态**：只有想法 → `Backlog`；已有 plan 文档 → `Planned`；已在做 → `In Progress`（取值以 README 为准）。
   - **依赖**：是否被现有条目或外部条件阻塞，如实填。
   - **分区**：**默认进 Icebox**——用户未明确承诺执行时机时，不替他排期进 Now/Next（README 工作流通常规定"新想法先进 Icebox"）。除非用户明说"现在做/优先"。**Icebox 的物理位置以项目 tasks/README.md 为准**（若项目已拆分为独立 `tasks/icebox.md`，新条目写入该文件而非 active.md）。
   - **详情**：涉及已有 plan/文档就链接；没有则留占位说明。

3. **生成条目**：ID = 全库最大序号 +1（见上，active/icebox/completed 一起扫）；按表格列填齐。

4. **展示并确认**：把拟插入的整行 + 拟放分区 + 判断理由展示给用户，请其确认（尤其分区与状态）。含混不清就问，不猜。

5. **写入**：确认后插入目标分区（默认区末尾，或用户指定位置），保留其它行不动。Icebox 条目写入拆分后的 `icebox.md`（如项目已拆分），其余分区写 `active.md`。

6. **提交**：按 README 工作流在 docs 仓库 commit（docs 通常是独立 git 仓库）。**显式** `git -C <docs 路径> add <改动文件> && git -C <docs 路径> commit`，不裸 `add -A`；message 说明新增了哪条。commit message 不加 Co-Authored-By trailer。

## 注意

- 分析要真做：归类、判状态、找依赖、拟详情——这是本 skill 的价值，不是记事本。
- 不确定分区/状态/ID 时，问用户，不擅自决定。
- 全程用中文。
