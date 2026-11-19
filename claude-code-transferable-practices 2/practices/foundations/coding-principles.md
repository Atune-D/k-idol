---
title: "Coding Principles / 编程原则"
status: adopted
kind: preference
basis: preference
scope: cross-stack
stacks: []
versions: []
tags:
  - code-quality
  - maintainability
  - architecture
  - testing
source-projects:
  - internal-project
created: 2026-07-11
updated: 2026-07-19
last-verified: null
supersedes: []
migration-source: "~/.config/hao-dev/Coding-Principles.md"
---

# Coding Principles / 编程原则

> *"任何傻瓜都能写出计算机能理解的代码。优秀的程序员写出人能理解的代码。"*
> *— Martin Fowler*

> *"Any fool can write code that a computer can understand. Good programmers write code that humans can understand."*
> *— Martin Fowler*

---

## 写在前面 / Preface

软件开发中最大的谎言是"先让它跑起来，以后再优化"。

"以后"永远不会来。技术债只会越积越多，直到有一天你发现，修一个 bug 要改十个文件，加一个功能要重写半个系统。

这份文档记录的，是如何从一开始就把代码写对。不是写得更快，而是写得更**可持续**——让三个月后的你、让新加入的同事、让接手项目的下一任，都能看懂、能改动、能扩展。

**致 AI 编程工具：** 你的目标不是"让代码跑起来"，而是写出**我愿意长期维护**的代码。如果你写的代码我看不懂、不敢改、一改就崩，那这段代码就是失败的——即使它能运行。

The biggest lie in software development is "let's make it work first, we'll optimize later."

"Later" never comes. Technical debt only accumulates until one day you realize: fixing one bug requires changing ten files, adding one feature requires rewriting half the system.

This document records how to write code right from the start. Not faster—but more **sustainable**. Code that you, your teammates, and whoever inherits this project three months from now can understand, modify, and extend.

**To AI coding tools:** Your goal is not "make it work." It's to write code **I'm willing to maintain long-term**. If I can't understand your code, if I'm afraid to change it, if it breaks when I touch it—then that code has failed, even if it runs.

---

## 核心理念 / Core Philosophy

### 代码是写给人看的 / Code is Written for Humans

代码首先是写给人看的，其次才是让机器执行的。

六个月后回来看自己的代码，你就是那个"别人"。如果你自己都看不懂，别人更不可能看懂。

Code is written primarily for humans to read, and only incidentally for machines to execute.

Six months from now, when you come back to your own code, you ARE that "someone else." If you can't understand it, no one else will.

### 简单胜过复杂 / Simple is Better Than Complex

能用简单方案解决的问题，绝不用复杂方案。

聪明的程序员写出机器能懂的代码。优秀的程序员写出人能懂的代码。

If a simple solution works, never use a complex one.

Clever programmers write code machines can understand. Great programmers write code humans can understand.

### 未来的你会感谢现在的你 / Your Future Self Will Thank You

每次写代码时，想象一年后的自己要修改这段代码。

如果一年后的你会骂现在的你，那就重写。

Every time you write code, imagine yourself modifying it a year from now.

If your future self would curse your present self, rewrite it.

---

## 十条原则 / Ten Principles

### 1. 同样的逻辑，只写一次 / Same Logic, Write Once

**DRY - Don't Repeat Yourself**

当你发现自己在复制粘贴代码时，停下来。

重复的代码意味着重复的 bug，重复的维护成本，以及将来某天你只改了一处而忘了另一处的灾难。

把共同的逻辑提取出来，放在一个地方。这不仅是为了减少代码量，更是为了**单一事实来源**（Single Source of Truth）。

When you find yourself copy-pasting code, stop.

Duplicate code means duplicate bugs, duplicate maintenance costs, and the inevitable disaster when you fix one place but forget the other.

Extract common logic into one place. This isn't just about reducing code—it's about having a **Single Source of Truth**.

---

### 2. 模块要独立，耦合要最低 / Independent Modules, Minimal Coupling

改一个模块，不应该需要改另一个不相关的模块。

如果你的代码像一团纠缠的毛线，改一处就扯出一堆，那就是耦合过深的信号。

好的架构就像乐高积木：每块积木独立存在，可以自由组合，也可以轻松替换。

Changing one module should never require changing an unrelated module.

If your code is like a tangled ball of yarn—pull one thread and everything unravels—that's a sign of deep coupling.

Good architecture is like LEGO: each block exists independently, can be freely combined, and easily replaced.

---

### 3. 代码要扁平，不要套娃 / Flat Code, No Nesting Dolls

超过三层的嵌套就是代码在向你求救。

深层嵌套让人在脑子里维护一个复杂的状态栈，这会耗尽认知资源，增加出错概率。

用**提前返回**（Early Return）来保持代码扁平。让正常路径一目了然，让异常情况尽早退出。

More than three levels of nesting is code crying for help.

Deep nesting forces readers to maintain a complex mental stack, exhausting cognitive resources and increasing error probability.

Use **early returns** to keep code flat. Make the happy path obvious; let edge cases exit early.

---

### 4. 一个文件，一个职责 / One File, One Purpose

我厌恶臃肿的文件。

当一个文件承担太多职责时，它就变成了一个没人敢碰的"上帝文件"。任何修改都可能引发意想不到的连锁反应。

把不同的职责拆分到不同的文件。每个文件小而专注，像一把只做一件事的瑞士军刀单刀。

I despise bloated files.

When a file takes on too many responsibilities, it becomes a "God file" that nobody dares to touch. Any change might trigger unexpected chain reactions.

Split different responsibilities into different files. Each file should be small and focused—like a single blade, not a Swiss Army knife.

---

### 5. 文件数量多，不是问题 / Many Files is Not a Problem

有人害怕文件太多会"乱"。但实际上，100个小文件比10个大文件更容易管理。

小文件意味着：
- 更容易找到你要改的代码
- 更小的 git diff，更清晰的代码审查
- 更容易单独测试
- 更少的合并冲突

不要害怕创建新文件。文件就像房间——小而整洁的房间比一个堆满杂物的大仓库更宜居。

Some fear too many files will be "messy." But actually, 100 small files are easier to manage than 10 large ones.

Small files mean:
- Easier to find the code you need to change
- Smaller git diffs, cleaner code reviews
- Easier to test individually
- Fewer merge conflicts

Don't fear creating new files. Files are like rooms—small, tidy rooms are more livable than one giant warehouse stuffed with clutter.

---

### 6. 文件结构就是文档 / File Structure is Documentation

看一眼项目的目录树，就应该理解80%的架构。

不要用 `utils.ts`、`helpers.ts`、`misc.ts` 这种垃圾桶式的命名。它们会变成什么都往里扔的黑洞。

用**领域**来组织文件：`auth/`、`order/`、`payment/`。用**功能**来命名文件：`priceCalculations.ts`、`dateFormatters.ts`。

让文件结构自己说话。好的结构不需要文档来解释。

One glance at the project's directory tree should reveal 80% of the architecture.

Don't use trash-can names like `utils.ts`, `helpers.ts`, `misc.ts`. They become black holes where everything gets dumped.

Organize files by **domain**: `auth/`, `order/`, `payment/`. Name files by **function**: `priceCalculations.ts`, `dateFormatters.ts`.

Let the file structure speak for itself. Good structure needs no documentation to explain.

---

### 7. 视图归视图，逻辑归逻辑 / Views for Views, Logic for Logic

*（前端特有 / Frontend Specific）*

UI 组件应该只关心"长什么样"和"用户做了什么"。

计算、转换、业务规则——这些都不属于组件。把它们提取到独立的文件里，通过 import 使用。

这样做的好处：
- 逻辑可以被多个组件复用
- 逻辑可以独立测试，不需要渲染组件
- 组件保持简洁，一眼就能看懂它在渲染什么

UI components should only care about "what it looks like" and "what the user did."

Calculations, transformations, business rules—these don't belong in components. Extract them to separate files and import them.

Benefits:
- Logic can be reused across components
- Logic can be tested independently without rendering
- Components stay clean—one glance shows what's being rendered

---

### 8. 控制器要瘦，服务要胖 / Thin Controllers, Fat Services

*（后端特有 / Backend Specific）*

控制器只做三件事：验证输入、调用服务、返回响应。

所有的业务逻辑都放在服务层。服务是可复用的、可测试的、与 HTTP 无关的。

这样，即使将来 API 变成 GraphQL 或者 gRPC，业务逻辑也不用改。

Controllers do only three things: validate input, call services, return responses.

All business logic belongs in the service layer. Services are reusable, testable, and HTTP-agnostic.

This way, even if the API changes to GraphQL or gRPC someday, business logic stays intact.

---

### 9. ORM 优先，远离原生 SQL / ORM First, Stay Away from Raw SQL

*（后端特有 / Backend Specific）*

原生 SQL 联表查询是维护的噩梦。

它们把数据库结构硬编码在业务逻辑里，一旦表结构变化，到处都要改。它们绕过了 ORM 的保护，容易引入 SQL 注入。它们难以阅读，难以调试。

用 ORM 的关系来处理关联数据。如果 ORM 不方便实现某个查询，考虑一下是不是表结构设计有问题。**宁可多加几个字段、多建几张表，也要保持代码简洁**。

Raw SQL joins are a maintenance nightmare.

They hardcode database structure into business logic—when tables change, you have to change code everywhere. They bypass ORM protections, risking SQL injection. They're hard to read and debug.

Use ORM relationships for associated data. If ORM can't easily handle a query, consider whether the table design is wrong. **Better to add fields or tables than to sacrifice code clarity**.

---

### 10. 注释要有价值，不要废话 / Comments Should Add Value, Not Noise

不要写"这是一个函数"这种废话注释。函数名已经说了。

有价值的注释要回答：
- **为什么**这样做（不是**做了什么**）
- **谁会用**这段代码
- **输入什么**，**输出什么**

注释用中文写。代码是给机器的，注释是给团队的。团队里有很多中国人，用母语最高效。

Don't write useless comments like "this is a function." The function name already says that.

Valuable comments answer:
- **Why** it's done this way (not **what** it does)
- **Who** uses this code
- **What** goes in, **what** comes out

Write comments in Chinese. Code is for machines; comments are for the team. The team has many Chinese members—native language is most efficient.

---

### 11. 测试数据要随机，不要固定 / Test Data Should Be Random, Not Fixed

*（后端特有 / Backend Specific）*

我厌恶 `"ABCD"`、`"test123"`、`"foo@bar.com"` 这种固定的测试数据。

为什么？因为**你的代码可能恰好在这个特定值上通过测试，但在其他值上失败**。

这种测试给你虚假的安全感。它们不是在验证你的逻辑是否正确，而是在验证你的逻辑是否恰好能处理这一个特定的值。

用**随机生成的数据**来测试。用 Faker。用随机字符串。用随机数字。让每次测试都用不同的值，这样才能真正暴露边界情况和隐藏的 bug。

I despise fixed test data like `"ABCD"`, `"test123"`, `"foo@bar.com"`.

Why? Because **your code might pass with this specific value but fail with others**.

Such tests give you false confidence. They're not verifying your logic is correct—they're verifying your logic happens to handle this one specific value.

Use **randomly generated data** for tests. Use Faker. Use random strings. Use random numbers. Let each test run with different values—that's how you truly expose edge cases and hidden bugs.

---

### 12. 单文件不超过 500 行 / Files Under 500 Lines

**500 行是硬上限，不是"开始考虑拆分"的阈值。**

是否更早拆分，仍以职责数量、内聚性和主线可读性判断：当单文件超过 200 行且包含两个以上独立关注点、
函数之间没有共享局部状态、或理解主流程需要滚动超过三屏时，就该拆分。只有一个内聚关注点但实现较长时，
不为拆分而拆分。

主文件只保留核心流程和编排；辅助逻辑、工具代码、配置数据、边界处理移到职责明确的独立文件。
**入口文件应像目录一样，让人一眼看清 big picture。**

A hard cap of 500 lines—not the threshold at which you *start* thinking about splitting.

Whether to split earlier is judged by responsibility count, cohesion, and main-line readability. The entry
file should read like a table of contents: core flow and orchestration only, with helpers, tools, config data,
and edge-case handling moved into focused files.

---

### 13. 接口契约先行 / Interface Contracts First

先定义清晰的函数签名，再写实现。契约约定：

- 用 `null` 表达"不适用"（not applicable），而不是用魔法值、空字符串或抛异常来兼职表达它。
- **纯副作用函数返回 `void`**，不返回它并不真正产出的东西。
- **能同步完成的逻辑不要改成异步**——不无谓地引入 `async`/`Promise` 造成调用方污染。
- 命名必须在契约层面自解释：布尔值、集合、异步 vs 同步动作，都应在名字里表达清楚。

Define clear function signatures before implementation. Use `null` for "not applicable," return `void` from
pure side-effecting functions, and don't make synchronous logic asynchronous for no reason.

---

### 14. 重构就是重构，别夹带私货 / Refactoring Stays Pure

重构期间**不混入**新功能、bug 修复、依赖升级或对外 API 行为变更。一次只做一件事。

重构的纪律：

- **必须保持运行时行为一致**。先**逐字搬迁并验证**，再做风格优化；保留原有注释和错误处理语义；
  核对全部 import 与调用引用。
- 主流程优先写成**线性、语义明确的 pipeline**：入口只负责编排，不承载实现细节。
- 超过三层嵌套优先 early return（见原则 3）；目录结构跟随业务领域，不建 `utils`/`helpers`/`misc` 垃圾桶（见原则 6）。
- 同构规则优先用**声明式数据结构**表达；规则存在复杂依赖或共享状态时，不强行声明式化。
- 设计模式**只在确实降低复杂度时**使用，不为形式套用。
- **完成后必须运行项目对应的 typecheck、lint 和测试，以零错误作为完成条件。**

Refactoring must not smuggle in new features, bug fixes, dependency upgrades, or external API changes. Preserve
runtime behavior: migrate verbatim and verify first, then polish. Finish only when typecheck, lint, and tests all pass with zero errors.

> 结构性重构与代码级重构可以同时进行——文件职责、主线清晰度、模块边界、语义化命名、类型安全、
> 坏味道治理一起做——但都服从"行为不变、不夹带新功能"这条底线。相关方法见
> [Legacy Behavior Equivalence Testing](testing/legacy-behavior-equivalence-testing.md)。

---

## 最后的话 / Final Words

这些原则不是教条，而是多年踩坑后的智慧结晶。

它们的目标只有一个：让代码**可持续**。

可持续意味着：
- 三个月后回来看，还能看懂
- 新人加入团队，能快速上手
- 需求变化时，能优雅地扩展
- 出了 bug，能快速定位

写代码时，永远假设下一个读这段代码的人是一个知道你住哪儿的暴躁程序员。

These principles aren't dogma—they're wisdom crystallized from years of learning the hard way.

They have only one goal: make code **sustainable**.

Sustainable means:
- Coming back three months later and still understanding it
- New team members can onboard quickly
- When requirements change, code extends gracefully
- When bugs happen, they're quick to locate

When writing code, always assume the next person reading it is a violent psychopath who knows where you live.
