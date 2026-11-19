# 安装指令（给 AI 执行）

> 你正在为用户安装一套「人 + AI 协作」基础设施。**全程用中文汇报。**
> 本文件是可执行流程，不是说明书。按顺序做，每一步做完就报一行结果。

## 执行前必读的四条纪律

1. **幂等**：所有步骤可重复执行。目标文件已存在时**不要覆盖**——比较差异，报告，问用户要不要合并。
2. **不静默覆盖**：遇到同名且内容不同的文件，停下来列出差异，等用户决定。**这是硬性要求**。
3. **不装不需要的**：Phase 2（项目层）只在用户明确指定项目时执行。
4. **验证不可跳过**：每个 Phase 末尾的验证步骤必须真跑，并如实汇报——包括没跑成功的部分。

设 `KIT` = 本套件所在目录（即本文件的上一级）。先在 shell 里定下来，后续步骤直接用：

```bash
KIT="$(cd "$(dirname install/INSTALL.md)/.." && pwd)"   # 或直接写绝对路径
echo "$KIT"
```

---

## Phase 0 · 环境探测（只读）

```bash
echo "HOME=$HOME"; ls -d ~/.claude 2>/dev/null || echo "~/.claude 不存在"
ls -d ~/.claude/skills ~/.claude/practices 2>/dev/null
ls ~/.claude/CLAUDE.md 2>/dev/null && echo "已有全局 CLAUDE.md（后面要合并而不是覆盖）"
python3 --version
```

汇报：`~/.claude` 是否存在、是否已有 practices、是否已有全局 CLAUDE.md、python3 是否可用。

若 `~/.claude` 不存在 → 说明用户可能还没跑过 Claude Code，提示先启动一次再安装，**停止**。

---

## Phase 1 · 全局层（装一次）

### 1.1 安装工程实践知识库

```bash
mkdir -p ~/.claude/practices
cp -R "$KIT"/practices/. ~/.claude/practices/
```

**若 `~/.claude/practices` 已存在且非空**：不要直接 `cp`。逐文件比较，只补缺失的；已存在且内容不同的列出来问用户。

验证：

```bash
ls ~/.claude/practices/PREFERENCE_INDEX.md && find ~/.claude/practices -name '*.md' | wc -l
```

预期：`PREFERENCE_INDEX.md` 存在，`.md` 文件约 30 个。

### 1.2 安装 skills

```bash
mkdir -p ~/.claude/skills
for d in "$KIT"/skills/*/; do
  name=$(basename "$d")
  if [ -e ~/.claude/skills/"$name" ]; then
    echo "已存在，跳过（需人工确认）: $name"
  else
    cp -R "$d" ~/.claude/skills/ && echo "已装: $name"
  fi
done
```

**skill 名字保持 `hao-*` 不变**，不要改名。

验证：

```bash
ls -d ~/.claude/skills/hao-* | wc -l          # 预期 11
bash "$KIT"/tools/check-broken-skill-links.sh  # 预期「无断链 ✅」
```

### 1.3 全局铁律（需要用户确认）

`~/.claude/CLAUDE.md` 是每次会话无条件加载的文件，**绝不能直接覆盖**。

- 若不存在：把 `$KIT/project-scaffold/CLAUDE.md` 里的「硬约束」「工作方式」「检索入口」三节作为起点写入，并**明确告诉用户里面有占位符**（如 `<测试数据库名>`）需要他填。
- 若已存在：**只追加**「检索入口」一节（若尚不存在），其余内容列给用户，由他决定要不要合并。

「检索入口」节的内容：

```markdown
## 检索入口

实现、设计、重构、review、debug、架构、文档、事故或运维工作开始前，先读
`~/.claude/practices/PREFERENCE_INDEX.md` 做路由，只读取命中的 canonical 文档。
没有命中就直接继续，不要遍历知识库。
```

### 1.4 Phase 1 验证

```bash
head -20 ~/.claude/practices/PREFERENCE_INDEX.md
ls ~/.claude/skills/ | grep '^hao-'
bash "$KIT"/tools/check-broken-skill-links.sh
```

汇报：装了几篇实践、几个 skill、CLAUDE.md 怎么处理的、断链自检结果。

---

## Phase 2 · 项目层（每个项目一次）

**先问用户目标项目的绝对路径**，没给就不要猜。设 `PROJ` = 该路径。

### 2.1 项目铁律

```bash
[ -f "$PROJ/CLAUDE.md" ] && echo "已存在，需合并" || cp "$KIT"/project-scaffold/CLAUDE.md "$PROJ/CLAUDE.md"
```

装完后**必须提醒用户**：里面的 `<测试数据库名>` 等占位符要按项目实际填写；不适用的条目直接删掉。
铁律条数保持个位数。

### 2.2 任务板

```bash
mkdir -p "$PROJ/docs/tasks"
for f in README active icebox completed; do
  [ -f "$PROJ/docs/tasks/$f.md" ] || cp "$KIT"/project-scaffold/docs/tasks/$f.md "$PROJ/docs/tasks/"
done
```

任务 ID 前缀默认 `T-`。若用户想用别的前缀（如项目缩写），改 `docs/tasks/README.md` 的「字段与取值」一节，并同步 `active.md` 的示例行。

### 2.3 文档骨架与交付模板

```bash
mkdir -p "$PROJ/docs/plans/_templates"
[ -f "$PROJ/docs/README.md" ] || cp "$KIT"/project-scaffold/docs/README.md "$PROJ/docs/"
cp -n "$KIT"/project-scaffold/docs/plans/_templates/*.md "$PROJ/docs/plans/_templates/"
```

### 2.4 项目记忆

项目记忆目录 = `~/.claude/projects/<项目绝对路径把 / 换成 ->/memory/`。

```bash
ENC=$(echo "$PROJ" | sed 's|/|-|g')
mkdir -p ~/.claude/projects/"$ENC"/memory
[ -f ~/.claude/projects/"$ENC"/memory/MEMORY.md ] || \
  cp "$KIT"/project-scaffold/memory/{MEMORY.md,example-git-multi-repo-discipline.md} ~/.claude/projects/"$ENC"/memory/
```

告诉用户：示例记忆是演示格式用的，可以随时删；**真正重要的是 `Why:` 段里写事故本身，不写抽象规则**。

### 2.5 知识库检索规则（可选）

若项目根有 `AGENTS.md` 或用户希望 Codex 等其他 agent 也遵守，运行 `/hao-dev-preferences-setup`
把检索规则以幂等 marker 形式写入项目指令文件。

### 2.6 Phase 2 验证

```bash
ls "$PROJ"/CLAUDE.md "$PROJ"/docs/tasks/active.md "$PROJ"/docs/plans/_templates/
ls ~/.claude/projects/"$ENC"/memory/
```

然后**在该项目里实跑一次只读 skill 验证链路**：

```
/hao-task-list
```

预期：能读到 `docs/tasks/active.md` 并列出 Now 区的示例行。若报「未采用 docs/tasks 系统」，说明路径不对，回查 2.2。

---

## Phase 3 · 收尾汇报（必做）

按这四段汇报，**不要省略第四段**：

```
A. 装了什么      —— 知识库 N 篇、skill M 个、项目脚手架哪几个文件
B. 需要用户手动做的 —— CLAUDE.md 里的占位符、任务 ID 前缀、要不要删示例记忆
C. 验证结果      —— 每条验证命令的实际输出（断链自检、/hao-task-list 是否成功）
D. 没做什么、为什么 —— 跳过的步骤（已存在未覆盖的文件）、失败的验证、未安装的可选项
```

最后给用户三句上手建议：

1. 先改 `CLAUDE.md`——删掉不适用的，填上占位符。铁律条数保持个位数。
2. 往 `docs/tasks/active.md` 的 Now 区写 1–3 件真事，删掉示例行。
3. **不要一次性全用上。** 从「被纠正的经验就写进记忆」这一条开始，其余按
   `reference/claude-code-transferable-practices.md` §五 的落地顺序逐步加。

---

## 卸载

见 [../MANIFEST.md](../MANIFEST.md)。
