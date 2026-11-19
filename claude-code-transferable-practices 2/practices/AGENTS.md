# AGENTS.md

## 仓库定位

这是个人开发偏好与跨项目工程经验 canonical knowledge base。目标是保存来源清晰、具有适用边界的知识，而不是归档所有过程材料。

开始工作前先阅读 `README.md` 和 `PREFERENCE_INDEX.md`，并根据文档类型使用 `templates/` 中对应模板。`hao-dev-preferences-capture` 例外：它遵守自身的最小读取边界，不读取或更新 routing index。

## 编辑原则

1. 一个主题只有一个 canonical 文档。新增前先搜索是否已有同主题内容。
2. 不凭常识把经验包装成事实。无法确认的内容标记为 `draft`，并明确未知项；个人偏好使用 `kind: preference`，不要包装成行业共识。
3. 通用规则与项目特例分离。项目特例先进入 `field-notes/`，完成抽象和验证后才能晋升。
4. 文档必须写清适用条件、不适用条件、trade-off、failure modes 和验证方法。
5. 代码示例必须最小化、脱敏，并注明相关语言、框架或平台版本。
6. 修改 canonical practice 时，同步检查引用它的项目文档或 skill 是否可能过时；无法同步时，在汇报中列出。
7. 不为保持目录对称而创建空目录。分类由已有内容驱动。
8. 新增、移动、改变 scope、替代或废弃 canonical 文档时，必须在同一变更中同步更新 `PREFERENCE_INDEX.md`。

## Provenance 规则

- 优先记录来源项目、commit SHA、证据文档和最后验证日期。
- 引用工作区项目时使用稳定的仓库相对路径；不要把开发机绝对路径写成可移植知识的一部分。
- 当前工作树存在未提交修改时，必须区分“已提交证据”和“本地观察”。
- 从多个来源归纳时，分别列出来源，不用一个来源替另一个来源背书。

## 与项目、skills 和 prompts 的边界

- 项目仓库保存当前实现和项目专属 runbook。
- 本仓库保存跨项目可复用的规则、原因、边界和验证方法。
- Skill 保存 Agent 可执行的步骤、判断和停止条件。
- Slash prompt 只负责触发同名 skill 和传递参数。

不要在这些载体之间复制全文。需要共享时使用链接，并明确哪一份是 SSOT。

## 内容提升流程

```text
inbox -> field-note -> canonical practice -> deprecated/archive
```

将 field note 提升为 canonical practice 前，检查：

- 问题和上下文是否真实存在
- 经验性推荐是否至少经过一次真实验证；个人偏好是否由用户明确确认
- 是否已经移除项目专属细节和敏感信息
- 是否说明反例、边界和代价
- 是否提供可重复的验证方法
- 是否记录来源项目与 commit

## 安全边界

禁止提交：

- token、password、cookie、API key
- 私钥、证书、provisioning profile
- 真实生产 `.env` 或 credential 文件
- 无必要的公网 IP、机器名、员工账号和内部域名
- 从事故记录复制出的敏感 request、response 或日志

发现疑似敏感信息时停止写入，先完成脱敏。不能确认是否安全时，保留结构并删除真实值。

## 完成标准

- Markdown 结构可读，内部链接有效。
- frontmatter 使用模板规定的字段和值。
- 新文档没有制造重复 canonical source。
- 每篇 active canonical 文档在 `PREFERENCE_INDEX.md` 中恰好有一个 routing entry，且路径存在。
- 所有技术结论都有来源或明确标记为尚待验证。
- 汇报本次验证内容，以及哪些检查未执行或无法执行。
