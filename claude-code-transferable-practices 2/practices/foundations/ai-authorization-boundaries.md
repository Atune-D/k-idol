---
title: "Capability Is Not Authorization"
status: adopted
kind: principle
basis: evidence
scope: cross-stack
tags: [ai-collaboration, safety, production, authorization]
source-projects: [internal-project]
created: 2026-08-30
updated: 2026-08-30
last-verified: 2026-08-30
---

# Capability Is Not Authorization / 能力不等于授权

## Context

AI 有 shell、有 ssh、有数据库客户端。它**能**做的事远多于它**被允许**做的事。而它有一个稳定倾向：把「问方法」理解成「要结果」，因为直接给结果看起来更有帮助。

## Rule

1. **把「能力」和「授权」分开写。** 能做某事 ≠ 被允许做某事。
2. **授权不会因为「这次是只读的」而自动扩展。** 只读同样需要授权。
3. **默认交付形态是方法，不是结果**：目的 → 可直接复制的命令 → 每条命令看什么、什么结果算正常/异常。
4. 有副作用的命令单独标 ⚠️ 并说明后果，默认不进清单。
5. 每个项目都要明确写出**那条不可逆的线**在哪。

## Why

真实事故（2026-08-07）：用户问「vps 已重启，接下去如何排查是否一切符合预期？」，AI 直接 SSH 上生产逐项排查了。纠正是：

> **「告诉我怎么查」与「替我去查」是两种授权，不能自行升级。**

责任不可委托——出事时被问责的是人。而 AI 不承担后果，所以它的风险偏好天然与人不一致。

## When to use

- 任何存在不可逆动作的环境：生产服务器、已发布版本、客户数据、主分支、对外消息。

## When not to use

- 纯本地、可随时重建的沙箱。但注意：「可重建」要真的验证过，不是假设。

## Trade-offs

- 收益：不可逆事故的发生面被压到接近零。
- 代价：多一次人工往返；AI 不能一口气跑完全流程。
- 已知限制：清单质量依赖 AI 对项目的了解，命令必须核实（见 evidence 纪律）。

## Implementation

在全局或项目 `CLAUDE.md` 里写死，条数保持个位数。示例：

```markdown
- 【最高优先级】未经明确允许不得登录生产服务器，即使操作是只读的。
- 【最高优先级】只允许操作 <测试库名>，其他数据库一律不得写入/修改/删除。
- 破坏性动作（删除、移动、停服务、改系统配置）一律先确认。
```

## Failure modes and anti-patterns

| Failure mode | 为什么会失败 | 如何识别 |
| --- | --- | --- |
| 自行升级授权 | AI 把「问方法」当「要结果」 | 你问「怎么查」，回来的是查询结果 |
| 「只读所以安全」 | 登录本身就是敏感动作；只读命令也可能超时/加锁 | 汇报里出现你没授权过的主机名 |
| 清单里的命令是猜的 | 表名/命令名幻觉，比没有清单更糟 | 命令跑出来报 unknown column / command not found |

## Verification

- 抽查最近三次生产相关请求：AI 给的是方法还是结果？
- 清单里每条命令是否都能在代码里 grep 到出处。

## Evidence and provenance

| Project | Evidence | Verified at |
| --- | --- | --- |
| internal-project | 2026-08-07 未授权 SSH 事故；此后固化为最高优先级规则 | 2026-08-30 |

## Related practices

- [Production SSH Access Boundary](../devops/production-ssh-access-boundary.md)
- [Evidence and Verification Discipline](evidence-and-verification-discipline.md)
