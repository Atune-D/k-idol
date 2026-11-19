---
name: hao-refactor-diff-test
description: 重构等价性对比测试（differential testing），两种模式。HTML 模式：跑代码的两个版本（两个 commit，或当前代码 vs 某旧 commit），共享同一数据库，逐页面对比清洗后的 HTML，确认"纯重构没有改坏读路径"。backend 模式：后端代码（含读+写）新旧等价——旧逻辑转写为 SQL 作基准、新真实代码打到一次性临时库，比对实体选择集/写入行形状字节/破坏性副作用（三层）。仅在用户输入 /hao-refactor-diff-test（commit <a> vs <b> / vs commit <old> / add path / 添加账号 / backend <task>|onboard|add-task）时使用。通用、不锁定具体项目；项目差异全在项目自己的 tools/ 配置里。
---

# hao-refactor-diff-test

对"重构前后行为等价"做并行对比测试（differential testing）：同时起代码的**两个版本**、连**同一个数据库**、
喂一样的输入（同一批 URL、同一批账号），比较两边输出的 HTML；清洗掉会变碎片后若逐字一致，就有较高信心
说明重构没改坏读路径。

完整设计见项目 `docs/specs/hao-refactor-diff-test-skill-design.md`（若存在）。本文件是可执行指令。

## 命令

```
# ── HTML 模式（读路径页面对比）──
/hao-refactor-diff-test commit <hash_1> vs <hash_2>       # 对比当前项目两个 commit
/hao-refactor-diff-test vs commit <hash_old>              # 对比"当前工作代码" vs 某旧 commit
/hao-refactor-diff-test add path                          # 读最近改动，推断受影响页面，补进 paths 清单
/hao-refactor-diff-test 添加账号 <account>; 密码：<password>  # 往 accounts 清单追加一个测试账号

# ── backend 模式（后端代码读+写等价）──
/hao-refactor-diff-test backend <task>                    # 跑某迁移任务的后端等价差分（Layer 1+2[+3]）
/hao-refactor-diff-test backend onboard                   # 在当前项目搭 tools/refactor-diff-test/ 脚手架
/hao-refactor-diff-test backend add-task <task>           # 从模板追加一个待测任务 harness
```

命令解析要**宽容**：中英文混用、空格多少、全角/半角冒号（: 或 ：）、`vs`/`VS`/`对比` 都要能认。

**首词是 `backend` → 走「backend 模式」章节；否则走上面的 HTML 流程。**

## 通用引擎 vs 每项目配置（关键分层）

- **通用（本 skill 目录，所有项目共享）**：本 `SKILL.md` + 同目录 `runner.py`（对比引擎）。
- **每项目专属（`<项目>/tools/refactor-diff-test/`，随项目版本化）**：
  - `refactor-diff-test-config.json` —— 启动配方(serveRecipe) + 登录配方(loginRecipe) + 端口 + projectCode
  - `refactor-diff-test-paths.jsonl` —— path + 各自 strip 规则（含开头一行全局 strip）
  - `refactor-diff-test-accounts.jsonl` —— 测试账号（含明文密码；**gitignore**）
  - `refactor-diff-test-expected-diffs.jsonl` —— 已判定"预期内"的不一致登记表
  - `reports/` —— 每次运行一个自包含目录 `run-<时间戳>-<判定>/`（summary/audit/MANIFEST/html，gitignore）

**铁规则（防漂移）**：config / paths / accounts / expected-diffs **永远读"你敲命令时所在的工作树"里那份**，
与被对比的两个 commit 无关。被对比的 old/new commit 只 checkout 到临时 worktree、**仅用来把该版本 app 跑在
端口上**，其 `tools/` 一律忽略。runner 每次运行开头必须打印它实际用的这几个文件的绝对路径 + paths 的行数/hash。

## 处理 `commit … vs …` 和 `vs commit …`

1. **确定两个 ref**：
   - `commit <a> vs <b>` → old=<a>, new=<b>。
   - `vs commit <old>` → old=<old>, new=当前工作树（HEAD 或含未提交改动，按 runner 约定）。
2. **前置检查**：确认当前工作树存在 `tools/refactor-diff-test/refactor-diff-test-config.json`。
   没有 → 提示用户"该项目尚未接入，请先按 §onboarding 写 config"，停止。
3. **交给 runner.py 编排**（它是确定性引擎，完成下列全部）：
   ```
   python3 <skill目录>/runner.py \
     --project-root <当前工作树绝对路径> \
     --old <old_ref> --new <new_ref|WORKINGTREE>
   ```
   runner 内部依次做：迁移检测 → checkout 两版本到临时 worktree 并按 serveRecipe 起在两端口 → （可选）预热 →
   账号×path 矩阵抓取（符号 path 跟随 301 记最终真实 URL）→ 清洗 → diff → 按 expected-diffs 分三档
   （CONSISTENT / EXPECTED / UNEXPECTED）→ 产出审计文档 → 停实例、清 worktree。
   runner 最后打印**覆盖率行**和**判定横幅**：`PASS` / `INCOMPLETE` / `FAIL`，退出码 0 / 2 / 1。
4. **迁移检测警告**：runner 若报告两 ref 间有 DB migration 变化，**明确转达用户**："检测到两个版本之间有
   migration 变化，这不是纯重构，共享库对比可能不可靠"，并让用户选择是否继续（`--allow-migration-diff` 放行）。
5. **读 runner 产出的审计文档**，向用户**用大白话汇总**。汇报纪律（★踩过坑、必须遵守★）：
   - **先报覆盖率和最坏判定，再报好数字**。永远先说"覆盖 X/Y 路径、判定 PASS/INCOMPLETE/FAIL"，
     再说 CONSISTENT 多少。**绝不能**把"21 一致"抬到前面、而把"11 条没测到"轻描淡写成"已知待办"。
   - **`NO_SAMPLE` 不是"跳过"，是"声明要测的目标零覆盖"**——等于没测。只要判定是 `INCOMPLETE`
     （退出码 2），就**不算通过**，必须如实告诉用户"这轮实际只覆盖了 X/Y 条，其余没跑到、原因是……"。
   - 逐条列出 UNEXPECTED 的 (账号, 页面, diff 摘要)；给出结论——UNEXPECTED 或 INCOMPLETE 都需关注。
6. **对每个 UNEXPECTED 帮用户分诊**：判断像"噪音"（时间戳等 → 建议加 §strip 规则）还是"真实但预期内的改动"
   （→ 建议登记进 expected-diffs，附 reason）还是"疑似真回归"（→ 建议查代码）。不擅自改判，给建议让用户定。

## 处理 `add path`

目的：基于**最近的代码改动**，推断出受影响的页面，补进 `refactor-diff-test-paths.jsonl`。

1. 读最近改动：`git -C <project-root> diff`（未提交）与最近若干 commit 的 `--name-only`，聚焦
   controller / route / view / 共享 partial。
2. **推断受影响页面 URL**：把改动的 controller 方法 / view 映射到它渲染的路由；共享 partial 要追出**所有**
   引用它的入口页面（consumer）。
3. **优先用符号写法**（若项目支持符号跳转，见 config 的 `symbolicPrefix`）：需要业务对象 ID 的页面写成
   `<symbolicPrefix>/…/:first:<code>/…` 之类，让 app 自解析，避免填死 ID。项目符号方案见 config 或设计文档。
4. **追加到 paths.jsonl**（每页一行 JSON，可带 `note`）；对可能有动态碎片的页面，**提示**可能需要的 per-path
   strip 规则，但不擅自乱加。
5. 追加后向用户列出"新增了哪些 path、为什么（对应哪次改动）"。

## 处理 `添加账号 <account>; 密码：<password>`

解析出 account 与 password（容忍 `;`/`；`、`密码：`/`密码:`/`password:` 等写法），向
`refactor-diff-test-accounts.jsonl` **追加一行** `{"label": "...", "username": "<account>", "password": "<password>"}`
（label 可让用户补，或用 username 占位）。提醒该文件含明文密码、必须 gitignore，仓库只留 `.example` 模板。

## strip 规则 vs expected-diffs（别用错）

- **strip 规则**（在 paths.jsonl 里）= 这是**噪音**（时间戳、CSRF token、相对时间、资源缓存戳），根本不该参与
  比较 → 抹掉，两边都看不见。
- **expected-diffs 登记**（在 expected-diffs.jsonl 里）= 这是**真实但预期内的改动**（如重构顺带修的小文案）→
  保留可见、如实记入审计，只是**不当回归失败**。

## 给新项目接入（onboarding）

在新项目里第一次用时，需在 `<项目>/tools/refactor-diff-test/` 建：

1. `refactor-diff-test-config.json`：
   - `projectCode`、`ports:{old,new}`、`sharedDatabase`（说明用）；
   - `serveRecipe:{start,stop,ready}`：**如何把 {worktreePath} 的代码跑在 {port} 端口**（Docker / artisan serve /
     npm start …，占位符 {worktreePath} {port} {slot}）；
   - `loginRecipe:{loginPath,method,fieldMap:{username,password},success}`：如何登录拿 session cookie；
   - （可选）`symbolicPrefix`：若项目实现了符号跳转 resolver（如 `/entity/<业务键>`）。
     **⚠ 声明了 symbolicPrefix，就必须真的把 resolver 路由/控制器实现好**——否则所有符号 path 会 404、
     判定 INCOMPLETE。别只写 config、paths 却不建 resolver（曾有项目首轮就栽在这：11 条符号路径全没跑到）。
2. `refactor-diff-test-paths.jsonl`：开头一行全局 strip + 若干代表性 path。
   **全局 strip 起手默认清单**（实战收敛出的通用噪音，新项目直接抄）：CSRF/会话令牌（`name="_token"` 及
   `id='_tkey|_tsig|_token'`、JS 里的 `_tkey/_tsig/_token: '...'`）、时间戳、资源缓存戳（`?v=`/`?t=`）、
   前端随机组件 ID（如 `slimAjaxTrigger-xxxx`）、WebSocket 握手参数（`socket.io/?channel=…&ticket=…&token=…`）。
   端口差异由 runner 内置 `normalize_ports` 自动抹平，无需写规则。
3. `refactor-diff-test-accounts.example.jsonl`（模板，进库）+ 真 `accounts.jsonl`（gitignore）。
4. `.gitignore`：忽略 `refactor-diff-test-accounts.jsonl`、`reports/`、以及账号脚本的 `.password-backup/`。
5. **accountRecipe 契约（凡涉及"改密码再还原"的项目，三条硬性防护，缺一不可）**：
   - **改库前先落盘旧值**（`.password-backup/<id>`），还原成功再删——中途被杀也能 `recover` 补救；
   - **prepare 前断言"当前密码 ≠ 测试密码"**：若已等于，说明上轮残留脏态、真实原值已丢，**必须拒绝**（否则会
     把测试值当原值备份、永久覆盖真实原值；no-op UPDATE 连 binlog 都不写、事后无从追溯）；
   - **提供 `recover` 相位**：扫 `.password-backup/` 把残留旧值写回。全量跑前先跑一次 recover 自检。
   - 写库脚本**硬编码目标库名双重守卫**（配置库名 + 实连库名都必须等于允许的那个），防误伤生产。

---

# backend 模式（后端代码读+写等价）

HTML 模式测「读路径页面」；backend 模式测「后端任务的**数据库行为**」——尤其是旧代码搬到新框架/新仓库、
且**含破坏性写**（删单、归档、入队）的迁移。旧代码常是重型 legacy、无法整体起服务，故不照搬"起两套 app diff 输出"，
而用下面这套方法。**完整实战实例 + 全过程记录见首个落地项目的 `tools/refactor-diff-test/TEST-LOG.md`。**

## 为什么需要它（与单元测试的区别）

单元测试的 fixture 与断言由写被测代码的同一心智产出，**共享同一假设** → 假设错了会一起错、且照样 pass（同源谬误）。
差分测试的旧基准**独立转写自旧源码**，与新代码无共享假设，才能真正兜底。

## 核心方法：三层分解 + 一次性临时库

```
任务 = 选择谓词(选中谁)   +   行形状(写成什么)   +   副作用(删/归档做了什么)
        ↑ Layer 1 纯读         ↑ Layer 2 纯函数       ↑ Layer 3 需真执行(仅破坏性任务)
```

- **旧侧（基准）**：把旧代码的选择/写入逻辑**独立转写为 SQL / 复算字节**，不引用新代码。
- **新侧（真实代码）**：用环境变量把真实新代码重定向到一次性临时库跑：`DB_DATABASE=<tmp> php artisan <cmd>`
  （Laravel Dotenv 不覆盖已存在的 env，故 shell 前缀生效；同 host:port，仅换库名）。
- **数据**：只读源库全程只 SELECT；一次性临时库承接所有写，可随时 drop。**只拷必要子集**（巨表按谓词过滤，别全量）。

等价单位不是字符串，而是 **实体 id 集合（逐行 diff，报"仅旧/仅新"）** + **写入行的字节形状** + **副作用字段**。

## 通用引擎 vs 每项目配置（同 HTML 模式的分层哲学）

- **通用（本 skill 目录）**：`lib/backend_diff_lib.sh`（helper 库）+ `templates/`（config 与 task harness 模板）。
- **每项目专属（`<项目>/tools/refactor-diff-test/`，随项目版本化）**：
  - `refactor-diff-test-config.json` —— 只读源库连接 + 临时库前缀 + appDir + 时区 + 从旧源码钉死的关键常量
  - `tasks/<task>.sh` —— 每个迁移任务一个 harness，`source` helper 库、实例化三层比对
  - `sql/old_*.sql` —— 旧选择逻辑的独立转写（基准）
  - `TEST-LOG.md` —— 该项目的全过程记录与结论
  - 真实密码走环境变量（`passwordEnv`），不硬编码进库；`reports/`、含密文件 gitignore

helper 库提供：`eq_reset_tmp_db / eq_copy_all / eq_copy_where / eq_copy_struct / eq_apply_migration_col`
（搭临时库）、`eq_artisan`（新代码打临时库）、`eq_set_diff / eq_byte_eq / eq_dryrun_crosscheck`（三类断言）、
`eq_now_shift / eq_today / eq_yesterday`（时区安全的时间 fixture）、`eq_report`（PASS/FAIL 横幅）、`eq_drop_tmp_db`。

## 处理 `backend <task>`

1. **前置检查**：当前工作树存在 `tools/refactor-diff-test/refactor-diff-test-config.json` 与 `tasks/<task>.sh`。
   缺 config → 提示先 `backend onboard`；缺 task → 提示先 `backend add-task <task>`。
2. **摸清事实（做测试前必须先确认，写进 TEST-LOG）**：新旧代码位置、**物理表映射**、**关键常量/时区**
   （逐个从旧源码里挖出真值，别信新代码的注释）。这一步常常就地判定新版 config 假设对不对。
3. **跑 harness**：`bash tools/refactor-diff-test/tasks/<task>.sh`。它搭临时库 → 旧SQL集 vs 新真实代码集
   → Layer1/2[/3] 比对 → 打印 PASS/FAIL。
4. **读结果，向用户大白话汇总**。汇报纪律（同 HTML 模式）：**先报覆盖与最坏判定，再报好数字**；
   逐条列 FAIL 的（命题、仅旧/仅新的实体）；破坏性任务若真实数据稀疏（如 pending 只有 1 行），
   **必须说明"边界未被真实数据压到，已用合成行补"**，别把稀疏说成"已覆盖"。
5. **对每个 FAIL 分诊**：像"新旧口径确有差异（需查是否 intended）"还是"harness/fixture 自身问题"
   （如时区、迁移列缺失），给建议让用户定，不擅自改判。

## 处理 `backend onboard`

在 `<项目>/tools/refactor-diff-test/` 建：`refactor-diff-test-config.json`（抄 `templates/refactor-diff-test-config.example.json`，
填只读源库连接/临时库前缀/appDir/时区/关键常量）、`tasks/`、`sql/`、`TEST-LOG.md` 骨架、`.gitignore`
（忽略含密配置、`reports/`）。提醒：源库密码走 `passwordEnv` 环境变量。

## 处理 `backend add-task <task>`

从 `templates/task_harness.sh.template` 复制出 `tasks/<task>.sh`，把占位符（旧谓词、channel、命令、表子集、
迁移列）按该任务填实；旧选择逻辑另存 `sql/old_<task>.sql`。追加后向用户列出该 task 覆盖哪几层、旧侧 SQL 抄自哪段旧源码。

## backend 模式的坑（★实战踩过，务必遵守★）

1. **时区 fixture 陷阱（最隐蔽）**：造合成时间行**必须用应用时区的字面量**（`eq_now_shift`），
   **不能用 MySQL `NOW()`**（服务器多为 UTC，会与应用 Shanghai 存储差 8h，令边界行错位）。
2. **迁移前置**：新写路径若依赖尚未在源库执行的迁移列 → 临时库先 `eq_apply_migration_col` 补上，
   模拟"部署后"。**这本身也是一条结论：暴露了部署顺序依赖。**
3. **真实数据稀疏 → 合成边界行**：破坏性任务的阈值（如 23min）常压不到真实数据 → 合成跨界行验证，
   并明确标注 synthetic。
4. **dry-run 交叉验证**：破坏性任务不便反复真删 → 用命令自带 `--dry-run` 的 `matched=N` 计数，
   把"转写谓词"与"真实私有查询"对齐（`eq_dryrun_crosscheck`），既只读又忠于真实代码。
5. **克隆行造 fixture**：`SELECT *` 会撞主键/唯一键 → 排除 id、给唯一业务键。
6. **只读源铁规则**：源库只 SELECT，任何写只落一次性临时库；harness 用 `eq_src_mysql`/`eq_tmp_mysql` 区分，别混。

## backend 模式边界（诚实告知用户）

- "集合/字节一致 ≠ 语义绝对正确"，但对"忠于旧实现"的迁移场景足够强（且比单元测试强，因旧基准独立转写）。
- Layer 1/2 不真跑破坏性副作用；副作用等价需 Layer 3（真执行于临时库）。
- 依赖旧 SQL 转写的忠实度 → 转写必须逐句对照旧源码，并用 dry-run 计数交叉验证。

---

## 边界（HTML 模式，诚实告知用户）

- 只测**读**，不测写；只适用**纯重构**（两版本 schema 兼容，否则 runner 会警告）；"一致 ≠ 正确"（但重构场景够用）；
  依赖 strip 规则质量（宁紧勿松，只抹确认会变的碎片）。
