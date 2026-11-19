---
title: "Refactor HTML Differential Testing (Two-live Byte Parity)"
status: verified
kind: playbook
basis: evidence
scope: cross-stack-legacy-migrations
stacks:
  - browser
  - php
  - docker
versions: []
tags:
  - legacy
  - refactoring
  - differential-testing
  - html-parity
  - regression-safety
  - read-path
source-projects:
  - internal-project
created: 2026-07-19
updated: 2026-07-19
last-verified: 2026-07-13
supersedes: []
replaced-by: null
---

# Refactor HTML Differential Testing (Two-live Byte Parity)

## Context

对一个渲染 HTML 的应用做**纯重构**（refactoring）后，要证明"读路径没被改坏"。契约常藏在模板、helper、
默认过滤器、分页、排序、渲染时的顺带读里，单元测试覆盖不到。方法：同时跑代码的两个版本、连同一个库、
喂同一批页面，比较"清洗掉噪音后的 HTML"，逐字节一致即高置信度证明重构等价（类比 Twitter diffy / GitHub scientist）。

## Rule

本地同时起代码的两个版本（旧 baseline commit + 当前工作树），**共享同一个 local dev 数据库**，监听不同端口，
用同一批账号 × path 抓取，对**清洗后 HTML** 逐字节 diff。三态判定，全一致（除已登记的预期改动）→ PASS。

三条铁律：

1. **只测读路径、只适用纯重构**（新旧 schema 兼容，否则警告并要求放行）。
2. **"一致 ≠ 正确"**，但对纯重构场景足够强。
3. **依赖 strip 规则质量，宁紧勿松**——只抹确认会变的碎片。

## Why

- 读路径的真实契约散落在渲染层，字节级 HTML diff 能一次性兜住模板 / helper / 默认过滤 / 排序 / 分页 /
  顺带读的所有回归，是单元测试的补充。
- 旧 baseline 独立于新代码（就是旧 commit 本身），不共享新代码的假设，是可信的等价 oracle。
- 三态判定 + 覆盖率行 + HTML 强制存证，堵住"静默通过"（把没测到 / 空白页当通过）。

## When to use

- 渲染 HTML 的应用（尤其 legacy）做纯重构后，验证读路径逐字节等价。
- 契约藏在模板 / helper / 默认过滤 / 排序 / 分页里、单元测试难覆盖时。

## When not to use

- 有意的行为 / 数据 / UI 变更（不是纯重构）——新旧本就该不同，用
  [Legacy Browser Data Parity Testing](legacy-browser-data-parity-testing.md)（UI 变、比数据字段）。
- 能直接在测试里对比新旧实现、无需浏览器的代码级重构——用
  [Legacy Behavior Equivalence Testing](legacy-behavior-equivalence-testing.md)。
- 新旧 schema 不兼容（非纯重构）：共享库对比不可靠，须显式放行并谨慎解读。

## Implementation

### 通用引擎 vs 项目配置（分层，防漂移）

- **引擎（通用、不锁定项目）**：一个共享的 `hao-refactor-diff-test` 工具（命令解析 SKILL + 对比引擎 runner），
  提供 `commit <a> vs <b>` / `vs commit <old>` / `add path` / `添加账号`。
- **项目配置（在被测仓库 `<项目>/tools/refactor-diff-test/`）**：`config.json`（serve/login/account 配方 + 端口 +
  symbolicPrefix）、`paths.jsonl`（全局 strip + path 清单）、`accounts.jsonl`（gitignore）、`expected-diffs.jsonl`、
  compose 与登录 / 账号脚本、`.gitignore`。
- **防漂移铁规则**：config/paths/accounts **永远读"敲命令时所在的当前工作树"那份**，与被对比的两个 commit 无关
  （被对比的 commit 只用来把该版本 app 跑在端口上，其 `tools/` 一律忽略）。

### 双端口起法（Docker）

- 参数化 compose 复用已构建镜像，挂载"被测版本代码目录"到 web root，用唯一 project name 起多份互不冲突。
- 旧版走 `git worktree add --detach` 检出旧 commit；新版（WORKINGTREE）直接用当前工作树（含未提交改动）。
- **worktree 缺失的 gitignore 文件从主工作树挂入**：依赖目录（纯重构下新旧 lock 相同可共用）、
  含 DB 配置 + 密钥的运行时配置文件（否则重置的密码旧版认不了）。
- worktree 里 storage 只有空壳：serveRecipe.start 先 `mkdir -p` 补齐 cache/logs/sessions/views 并放开写权限，否则渲染写缓存 500。

### 测试账号：非破坏性密码重置（关键安全设计）

- 账号清单只存 **user_id**（同一 email 可能对应多个 user_id，不能用 email 定位）。
- prepare：把该 user 密码**非破坏性重置**为统一测试密码 → 返回旧哈希作还原令牌；restore：用旧哈希写回，等于没动过。
- **硬编码目标库名双重守卫**：配置库名 + 实际连接库名都必须等于允许的那个，否则拒绝写库——防配置被手误指向生产。
- 密钥（salt / DB 密码）运行时从项目配置读，**不写死、不入库**；用应用自身的哈希方案计算。
- **崩溃安全（三条硬性防护，缺一不可，血泪教训）**：
  1. 改库前先把旧哈希落盘 `.password-backup/<id>`，restore 成功再删——中途被杀也能 `recover` 一键还原。
  2. **prepare 前必须断言"当前密码 ≠ 测试哈希"**：若已相等 = 上轮残留脏态、真实原哈希已丢，**必须拒绝**
     （否则把测试哈希当原值备份、永久覆盖真实原哈希；no-op UPDATE 连 binlog 都不写、事后无从追溯）。
  3. 提供 `recover` 相位扫 `.password-backup/` 补救；全量跑前先 recover 自检。

### 符号跳转 resolver（避免在 path 清单里填死易变 ID）

- 问题：订单详情等页面需真实 code / slug / 加密 id，填死很脆弱。
- 方案：被测项目**新增一个 dev-only 独立控制器 + 独立顶层路由前缀**（与既有路由平级、零改动），把符号 URL
  `<prefix>/<entity>/:<sortby>:<code>/<tail>` 按登录用户 scope 查库取一条（`:first|:last|:rand`）、301 到真实 URL；
  无匹配 → 404（记为"无样本"）。**仅 local 环境注册，生产不启用。**
- **runner 侧关键逻辑**：resolver 只在新版存在，旧 baseline 没有 → 不能两端都请求符号 URL（旧版 404 = 假 mismatch）。
  正确做法：**先在新版跟随 301 解析出真实 URL，再用这个真实路径同时请求新旧两版**（由 config 的 `symbolicPrefix` 触发）。
- 实体→字段映射需实测确认；新增 classmap 控制器后要重跑 autoload。

### 噪音清洗（strip）vs 预期改动（expected-diffs）

- **strip = 噪音**（时间戳、CSRF / 会话令牌、资源缓存戳、每次渲染的随机 id）→ 两边都抹掉，不参与比较。
- **expected-diffs = 真实但预期内的改动**（如重构顺带修的小文案）→ 保留可见、如实记入审计、不当回归失败。
- 收敛：每跑一轮 → 看审计剩什么 diff → 噪音就加 strip、预期改动就登记 → 重跑直到只剩真 UNEXPECTED。
- **通用噪音清单（新项目默认起点）**：CSRF / 会话令牌、时间戳、资源缓存戳（`?v=`/`?t=`）、
  前端随机组件 id、WebSocket 握手参数、请求 nonce、生成的短链 / 优惠码。端口差异由引擎内置 normalize 自动抹平。

## Failure modes and anti-patterns

| Failure mode | 为什么会失败 | 如何识别 |
| --- | --- | --- |
| 把 NO_SAMPLE 当"跳过" | 声明要测却零样本 = 没测；掩盖大片未覆盖 | 审计有 NO_SAMPLE 却判 PASS，且好数字被抬前 |
| 先报"多少一致"再报覆盖 | 好数字盖过没测到的目标 | 汇报没有"覆盖 X/Y + 零覆盖清单"在前 |
| 两个空白页相等当通过 | 空/500 页无内容可比 | 清洗后 <200 字节的非 404 页未判 EMPTY |
| 符号路径两端都请求符号 URL | 旧版无 resolver → 404 假 mismatch | 旧版对符号 path 全 404 |
| strip 过松 | 把真实改动也抹掉，漏报回归 | strip 规则覆盖了非噪音内容 |
| config/paths 跟着被测 commit 走 | 不同 commit 的 tools/ 不同 → 测试内容漂移 | 读的是 worktree 里旧版的 tools/ 而非当前工作树 |
| 缺"当前密码≠测试哈希"断言 | 残留脏态把真实原哈希永久覆盖 | 重跑后某账号原密码再也还原不了 |

## Verification

- **三态判定 + 退出码**：`PASS(0)` / `FAIL(1，有 UNEXPECTED/EMPTY/登录失败/账号准备失败)` /
  `INCOMPLETE(2，有未豁免的 NO_SAMPLE)`。
- **覆盖率行每轮必打印**（覆盖 X/Y + 零覆盖清单），先于判定。
- **HTML 强制存证**：每页原始 HTML 落盘 + MANIFEST（逐页 http 状态 + 原始/清洗字节数）；清洗后 <200 字节的非 404 页判 EMPTY。
- **reports 组织**：一次测试 = 一个自包含目录 `reports/run-<时间戳>-<判定>/`（判定写目录名，一眼知成败），
  内含 summary + audit（逐页 UNEXPECTED/EXPECTED/NO_SAMPLE + CONSISTENT 计数）+ MANIFEST + `html/<账号>/<path>.{old,new}.html`。
- **汇报纪律**：先报覆盖率和最坏判定，再报好数字；绝不把 NO_SAMPLE 轻描淡写成"已知待办"。

## Evidence and provenance

| Project | Commit | Evidence | Verified at |
| --- | --- | --- | --- |
| legacy-admin-console (旧框架 4.2 / 运行时 7.4；宿主运行时 8.4，只能容器化跑旧版) | baseline `80658d4` → 工作树（orders 卡片 loader 重构）；resolver `21e613d` + 工具 `179e1ff`；docs `2186439` | 6 商户 × 14 页 = 84 格 → 80 CONSISTENT / 0 UNEXPECTED / 0 EMPTY / 4 NO_SAMPLE(已标 optional) → PASS。设计文档 `docs/specs/hao-refactor-diff-test-skill-design.md` | 2026-07-13 |

工具引擎在用户的全局 skill 目录（不在项目仓库）；本方法为已提交证据 + 本地实测观察的混合。

## Related practices

- [Legacy Behavior Equivalence Testing](legacy-behavior-equivalence-testing.md)（代码级、无浏览器）
- [Legacy Browser Data Parity Testing](legacy-browser-data-parity-testing.md)（UI 有意变更、比数据字段）
- [Legacy Refactor Blast-radius Safety](legacy-refactor-blast-radius-safety.md)（判断哪些改动需要这类测试）
- [Legacy Migration Decommission Strategy](../legacy-migration-decommission-strategy.md)
