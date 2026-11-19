---
title: "Production SSH Access Requires Per-action Approval"
status: adopted
kind: preference
basis: preference
scope: operations
stacks: []
versions: []
tags:
  - ssh
  - production
  - operations
  - safety-boundary
  - remote-access
source-projects: []
created: 2026-07-19
updated: 2026-07-19
last-verified: null
supersedes: []
replaced-by: null
---

# Production SSH Access Requires Per-action Approval

> `basis: preference` —— 这是明确下达的运维安全红线，不依赖项目验证。

## Rule

未经用户每一次单独、明确的授权，**不得 SSH 连接进入任何生产服务器**。

- **read-only 也不例外**：只读查询同样需要授权，"只是看一眼"不构成豁免。
- **授权是逐次的**：一次授权只对当次那一个动作有效，不延续到下一条命令、下一次会话或"同类操作"。上一次被允许，不代表这一次也被允许。
- 需要在生产服务器上执行任何命令时，先说明**要连哪台、跑什么、为什么、影响是什么**，等用户明确同意后再执行。

## Why

- 生产服务器上的误操作难以撤销，且外部可见；一条"无害的只读命令"也可能触发意外副作用（锁、负载、状态变更、被审计系统记为异常访问）。
- 逐次授权把"是否触碰生产"的决定权始终留在用户手里，而不是交给 AI 的风险判断——AI 对某条命令是否真的只读、是否真的安全，判断可能出错。
- 与既有工程纪律一致：破坏性/对外操作默认先确认；一处上下文的批准不自动延伸到下一处。

## When to use

- 任何涉及生产环境主机的 shell / SSH 访问请求。
- 排障、核实配置、抓日志、验证部署等"看起来只读"的生产访问诉求。
- 需要在生产上做可回滚小实验（如 DB 试验 SQL）之前。

## When not to use

- 本地 / development / staging 等非生产环境——不受本红线约束（但仍遵守各自环境的安全约定）。
- 通过已授权的 CI/CD 流水线、部署脚本或运维平台进行的、不构成人工 SSH 登录的自动化操作。
- 本地测试账号的运行时操作（如 local/dev 用框架 console 重置测试账号密码），属另一套边界，见
  [Legacy Browser Data Parity Testing](../foundations/testing/legacy-browser-data-parity-testing.md) §3。

## Trade-offs

- 收益：把不可逆的生产风险的决策权牢牢留在人手里；杜绝"自作主张连生产"。
- 代价：每次生产访问多一轮确认往返，牺牲一点即时性换安全性——这是明确接受的取舍。

## Failure modes and anti-patterns

| Failure mode | 为什么会失败 | 如何识别 |
| --- | --- | --- |
| 把 read-only 当豁免 | 只读命令仍可能有副作用/被审计为异常 | "我只是查一下，不用授权吧" |
| 把一次授权当长期通行证 | 授权是逐次的，范围只限当次动作 | 用上一条命令的许可去跑下一条 |
| 用"同类操作已批准"自我放行 | 每次都要单独授权，类比不成立 | "刚才那台能连，这台应该也行" |

## Verification

- 任何生产 SSH 动作之前，对话里存在用户对**这一次具体动作**的明确同意记录。
- 找不到针对当次动作的授权时，停下来请求授权，而不是先执行再解释。

## Related practices

- [Legacy Migration Decommission Strategy](../foundations/legacy-migration-decommission-strategy.md)
- [Legacy Browser Data Parity Testing](../foundations/testing/legacy-browser-data-parity-testing.md)
