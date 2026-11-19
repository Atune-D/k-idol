# hao-refactor-diff-test

重构等价性对比测试的通用引擎。命令与总体说明见 `SKILL.md`；完整设计见任一接入项目的
`docs/specs/hao-refactor-diff-test-skill-design.md`。本文件讲**如何给一个新项目接入**。

## 组成

- `SKILL.md` —— skill 指令（Claude 读它来解析命令、编排、做 add path 推断）。通用。
- `runner.py` —— 确定性对比引擎（起两版本、账号×path 矩阵、清洗、diff、三档分类、审计）。通用。
- `<项目>/tools/refactor-diff-test/*` —— 每个项目自己的配置与数据（下面详述）。

## 给新项目接入：在 `<项目>/tools/refactor-diff-test/` 建 4 类文件

### 1. `refactor-diff-test-config.json`（项目差异全在这）

```jsonc
{
  "projectCode": "my-project",
  "ports": { "old": 9001, "new": 9002 },
  "sharedDatabase": "my_dev_db",           // 仅说明用途；两版本必须连同一个库

  // migration 路径（可选）：runner 比对两 ref 间这些路径的变化，有变化→警告"非纯重构"
  "migrationPaths": ["database/migrations"],

  // 启动配方：如何把 {worktreePath} 的代码跑在 {port} 端口（{slot}=old|new）
  "serveRecipe": {
    "start": "……起服务命令，可用占位符 {worktreePath} {port} {slot}……",
    "stop":  "……停该实例命令……",
    "ready": { "url": "http://localhost:{port}/<健康检查路径>", "statusBelow": 500, "timeoutSeconds": 60 }
  },

  // 登录配方：如何登录拿 session cookie
  "loginRecipe": {
    "loginPath": "/login",
    "method": "POST",
    "fieldMap": { "username": "<登录表单用户名字段名>", "password": "<密码字段名>" },
    "extraFields": {},                     // 可选：登录表单还要带的固定字段（如 _token 由 curl cookie 处理则不填）
    "success": { "statusBelow": 400 }
  },

  // 可选：若项目实现了"符号跳转 resolver"，写它的前缀（runner 只是跟随 301，无需知道语法）
  "symbolicPrefix": "/merchant"
}
```

**serveRecipe 是通用化的关键**——runner 只负责 checkout commit 到临时 worktree、按端口调用这份配方；具体
怎么起服务（Docker / docker compose / `php artisan serve` / `npm start` / `go run` …）完全由项目决定。

### 2. `refactor-diff-test-paths.jsonl`

每行一个 JSON；`#`/空行为注释。开头一行放全局 strip 规则，之后每行一个 path（可带 per-path `strip` 与 `note`）：

```jsonl
{"global": [{"pattern": "name=\"_token\"[^>]*value=\"[^\"]*\"", "replace": "name=\"_token\"[CSRF]"}, {"pattern": "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}", "replace": "[TIME]"}]}
{"path": "/some/fixed/page"}
{"path": "/some/page-with-noise", "strip": [{"pattern": "在线\\s*\\d+\\s*分钟", "replace": "[ONLINE]"}], "note": "备注"}
```

若项目实现了符号跳转，需要 ID 的 path 可写成符号形式（如某项目的
`/merchant/order/view/:first:downloading/messages`），runner 跟随 301 自动落到真实 URL。

### 3. `refactor-diff-test-accounts.jsonl`（含明文密码，gitignore）

```jsonl
{"label": "总部管理员", "username": "hq@example.com", "password": "***"}
{"label": "门店员工", "username": "store@example.com", "password": "***"}
```

跑测试时 **账号 × path 全矩阵遍历**（覆盖不同角色权限分支）。**必须 gitignore**；仓库只提交
`refactor-diff-test-accounts.example.jsonl` 占位模板。

### 4. `refactor-diff-test-expected-diffs.jsonl`（可空，随用随加）

登记"已审阅、判定为预期内/可接受"的不一致，让正常改动不被当失败：

```jsonl
{"path": "/some/page", "account": "*", "match": "顾客尚未确认.*已取消", "reason": "本次重构顺带修的文案，属预期内"}
```

`match` 是对 diff 内容的正则，命中即判为 EXPECTED（记入审计、不阻断）。**与 strip 的区别**：strip 抹的是噪音
（根本不该比）；expected-diffs 承认的是真实但预期内的改动（保留可见、只是不当回归）。

### 5. `.gitignore`

```
refactor-diff-test-accounts.jsonl
reports/
```

## 跑一次

```
python3 <skill目录>/runner.py --project-root <项目绝对路径> --old <ref> --new <ref|WORKINGTREE>
```

- **判定与退出码**（三态，防"静默通过"）：
  - `PASS`（0）：声明的 path 全部取到样本且一致。
  - `FAIL`（1）：存在 `UNEXPECTED` / `EMPTY`（页面空白）/ 登录失败 / 账号准备失败。
  - `INCOMPLETE`（2）：有未豁免的 `NO_SAMPLE`——**声明要测却一个样本都没抓到**（多半是路由/resolver 没实现）。
    NO_SAMPLE 不是"跳过"，是"该测的没测到"，默认**不算通过**。放行方式：给该 path 标 `"optional": true`，
    或整轮加 `--allow-no-sample`。
- **覆盖率行**：每次必打印 `覆盖 X/Y 路径`，并列出零覆盖路径，防止好数字盖过没测到的目标。
- **每轮产物自包含**：一次测试 = `reports/` 下一个目录 `run-<时间戳>-<判定>/`（判定即 PASS/FAIL/INCOMPLETE，
  跑完按判定重命名，扫一眼就知道哪次成哪次败），内含：
  ```
  run-20260713-180942-PASS/
    summary.txt   本轮控制台汇总（判定 / 各档计数 / 覆盖率）
    audit.md      逐页审计（UNEXPECTED / EXPECTED / NO_SAMPLE 明细 + CONSISTENT 计数）
    MANIFEST.tsv  每页 http 状态 + 原始/清洗字节数
    html/<账号>/<path槽>.{old,new}.html   每页新旧原始 HTML 存证（old/new 相邻便于对照）
  ```
- **HTML 强制存证**：每个账号×path 的原始 HTML 都落盘（上面的 `html/`），用于肉眼核对"确实抓到真实内容"，
  任何 0 字节/空白都在 `MANIFEST.tsv` 里现形；清洗后不足 200 字节的非 404 页直接判 `EMPTY`（失败），
  堵掉"两个空白页相等 = 假通过"。
- 通常由 skill 命令 `/hao-refactor-diff-test commit <a> vs <b>` 触发，不用手敲 runner。

## 边界

只测读、只适用纯重构（否则 runner 警告）、"一致≠正确"（重构场景够用）、依赖 strip 规则质量（宁紧勿松）。
