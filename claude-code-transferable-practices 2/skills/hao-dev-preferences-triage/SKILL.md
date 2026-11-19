---
name: hao-dev-preferences-triage
description: 定期分析 `~/.claude/practices/inbox/` 的全部内容，与已沉淀的个人偏好和工程实践比较，完成去重、归类、补充、field note 转换与 canonical 沉淀。仅在用户明确调用本 skill 或明确要求 triage 该 inbox 时使用。发现任何真实矛盾时，必须暂停写入并逐条向用户确认，绝不擅自覆盖。
---

# Dev Preferences Triage

## 目标

把 inbox 中的原始记录安全地转化为结构清晰、来源可追踪的个人偏好或工程实践，同时维护每个主题只有一个 canonical source。

Triage 是高判断成本操作。先完成全量分析和冲突确认，再统一写入，避免知识库处于“部分更新、部分未确认”的中间状态。

## 固定位置

- Knowledge base：`~/.claude/practices`
- Inbox：`~/.claude/practices/inbox`
- Routing index：`~/.claude/practices/PREFERENCE_INDEX.md`

只有当用户明确提供测试目录时，才可以用该目录替代固定位置。

## 核心边界

- 个人偏好与经验性最佳实践分开判断。
- 用户的明确偏好可以成为 `kind: preference`，但不能包装成普适事实。
- 经验性实践必须保留 evidence、验证状态、适用边界和 trade-off。
- 新 inbox note 不天然比旧 canonical 更新、更准确或优先。
- 不通过整篇重写来合并一条补充；优先最小修改。
- Routing index 只保存检索 signals、适用边界、状态和 canonical path，不复制规则正文。
- 不自动 commit，不清理用户无关改动。

## Phase 1：建立全量视图

### 1. 读取治理规则

完整读取：

- 根目录 `README.md`
- 根目录 `AGENTS.md`
- 根目录 `PREFERENCE_INDEX.md`
- `inbox/README.md`
- `field-notes/README.md`
- `templates/` 下与本轮候选类型相关的模板

### 2. 检查工作树

执行 `git status --short`，记录开始前已存在的修改。不要把用户修改混入本轮，也不要要求干净工作树才能分析；只有发生无法安全区分的重叠时才停止。

### 3. 扫描内容

- 读取 `inbox/` 下全部待处理 Markdown，排除 `README.md`。
- 扫描仓库其他知识文档，区分 canonical practices、preferences、field notes、archive 和 templates。
- 对每个 inbox note 查找语义相近主题，不能只按文件名或关键词匹配。

### 4. 分类每条 note

每条 note 必须归入一种 disposition：

1. `new-canonical`：可建立新的 preference 或 practice
2. `supplement-existing`：为现有 canonical 增加证据、边界或例外
3. `duplicate`：现有内容已经完整覆盖
4. `scope-split`：表面不同，但适用于不同技术栈、版本或上下文
5. `conflict`：在相同 scope 下给出不兼容结论
6. `field-note`：有真实价值但仍是项目特例或证据不足
7. `insufficient`：缺少关键信息，继续留在 inbox

不要为了清空 inbox 而强行提升 `insufficient` 内容。

## Phase 2：识别并逐条确认冲突

### 什么算真实冲突

同时满足以下条件才是 `conflict`：

- 讨论同一个决策点
- 适用 scope、平台和版本相同或高度重叠
- 两个结论无法同时遵守
- 现有 canonical 不能仅通过增加边界说明容纳新内容

不同版本、不同风险等级或不同项目约束通常属于 `scope-split`，但必须把边界写清楚。

### 冲突处理协议

如果存在一个或多个 conflict：

1. 完成全部只读分析，但不要修改任何知识文件或移动 inbox note。
2. 按影响范围排序，每次只提出一个冲突。
3. 展示：
   - inbox note 的观点和来源
   - 现有 canonical 的观点、状态和证据
   - 两者共同 scope
   - 为什么无法同时成立
   - 采用任一方向可能造成的影响
4. 直接询问用户希望保留现有规则、采用新规则，还是为两者划分明确适用边界。
5. 等待回答。回答含糊时继续澄清当前这一条，不跳到下一条。
6. 记录决定，但仍不写入；然后再提出下一个冲突。
7. 所有冲突都得到明确答案后，才进入 Phase 3 一次性执行。

禁止批量列出多个冲突让用户一次选择，也禁止默认采用较新的 note。

如果对话中断或无法可靠恢复全部决定，重新扫描并重新确认未决冲突，不根据残缺记忆写入。

## Phase 3：生成执行计划

在写入前形成完整映射：

| Inbox note | Disposition | Target | Planned action | Index action | Conflict decision |
| --- | --- | --- | --- | --- | --- |

没有冲突时可以直接继续执行，不额外要求用户批准。存在冲突时，计划必须使用用户已逐条确认的决定。

## Phase 4：统一沉淀

### new-canonical

- 按 domain-first 原则选择目录；只有出现真实内容时才创建目录。
- 个人明确选择使用 `kind: preference` 和 `basis: preference`。
- 经验性规则根据证据使用 `draft`、`verified` 或 `adopted`，不得虚构验证。
- 使用对应模板，写清适用边界、允许例外和 provenance。

### supplement-existing

- 只修改受影响章节。
- 保留仍然准确的旧内容、证据和历史边界。
- 在 provenance 中增加 inbox note 或来源项目。

### duplicate

- 不创建第二份 canonical 文档。
- 在处理记录中指向已覆盖它的文档。

### scope-split

- 优先在同一 canonical 文档内明确适用矩阵。
- 只有两个主题已形成独立认知边界时才拆成两篇，并相互链接。

### field-note

- 使用 `templates/field-note.md`。
- 保留事实、推断、未知项和未来验证条件。

### insufficient

- 继续留在 inbox。
- 在 note 末尾增加 `Triage needs`，只列缺失信息，不替用户补答案。

### 处理原始 inbox note

已完成处理的 note 移到：

```text
archive/inbox/YYYY/
```

保留 `Raw note` 不变，只允许在 frontmatter 增加：

- `status: processed`
- `disposition`
- `processed-at`
- `canonical-target` 或 `field-note-target`

这样即使 note 尚未进入 Git 历史，也不会因 triage 丢失原始表达。`insufficient` note 不移动。

### 同步 Routing Index

完成所有 canonical 写入后，在同一轮变更中更新 `PREFERENCE_INDEX.md`：

- `new-canonical`：新增一个 routing entry。
- `supplement-existing`：当 scope、触发条件或适用边界变化时更新原 entry；仅补证据时不制造无意义 diff。
- `scope-split`：按最终 canonical 边界调整 entry；每篇 active canonical 恰好一条。
- 移动或重命名：同步更新 canonical path。
- `deprecated`：从 active routing 移除；replacement 必须拥有 entry。
- `duplicate`、`field-note`、`insufficient`：不新增 routing entry。

每个 entry 至少包含：稳定 ID、task signals、must-read 条件、skip 条件、status 和 canonical path。

Deprecated 文档必须在 frontmatter 使用 `replaced-by` 指向一个 active canonical；validator 会检查 replacement 存在且仍在 routing index 中。

允许 signals 有意重叠，因为复杂任务可能需要同时读取多个 preference；如果相同 scope 的 entry 给出互不兼容的 routing 或结论，按 conflict 协议逐条向用户确认。

Capture skill 永远不更新 index。

## Phase 5：验证

至少检查：

- `git status --short` 和本轮 diff
- 每个处理项都有唯一 disposition
- canonical topic 没有重复文件
- 所有 `draft|verified|adopted` canonical 文档在 routing index 中恰好出现一次
- routing index 中每个 canonical path 存在，status 与目标 frontmatter 一致
- deprecated 文档不在 active routing 中，且 `replaced-by` 指向 active canonical
- routing entry 没有复制 canonical 正文，signals 重叠具有明确理由
- frontmatter 字段和值合法
- 相对链接存在
- provenance 能回到归档 note 或来源项目
- 未写入 secret、真实 credential 或不必要的生产标识
- 没有修改开始前的无关用户变更

如果知识库包含可用的 Markdown、frontmatter 或链接检查命令，一并执行。

始终运行 bundled validator：

```bash
ruby ~/.claude/skills/hao-dev-preferences-triage/scripts/validate_preference_index.rb \
  ~/.claude/practices
```

如果用户为测试明确提供了替代 knowledge base 路径，将第二个参数替换为该路径。Validator 失败时，不得把 triage 报告为完成。

## 最终汇报

按以下结构汇报：

- 处理总数
- 新建 canonical
- 更新 canonical
- 转为 field notes
- 重复或 scope split
- 仍留在 inbox 及原因
- 已确认的冲突决定
- routing index 的新增、更新和移除
- 验证结果
- 未执行或无法执行的检查

## 严格禁止

- 不在冲突确认前做任何沉淀写入
- 不一次询问多个冲突
- 不静默覆盖 canonical 结论
- 不把个人偏好表述成行业强制规则
- 不为清空 inbox 编造证据或适用范围
- 不删除未进入 Git 历史的原始 note
- 不创建或更新 canonical 后遗漏 routing index
- 不把 inbox、field note、archive 或 template 写入 active routing
- 不自动 commit
