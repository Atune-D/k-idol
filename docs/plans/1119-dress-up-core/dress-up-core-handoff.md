# 换装核心玩法·交接说明

- **写于**：2026-11-20。计划内代码已全部提交并推送到 `main`（`f7b4820` 是第一波回合规则，它之后的一次提交包含其余全部代码和文档，见 §3）
- **读者**：接手的 Claude 会话，以及项目负责人
- **契约在哪**：[`dress-up-core-development-spec.md`](./dress-up-core-development-spec.md)（v1.4）。🔴 本文只讲"做到哪了、接下来怎么做"，与开发文档冲突时以开发文档为准
- **相关文档**：[`referee-open-questions-and-test-scenarios.md`](./referee-open-questions-and-test-scenarios.md)（回合裁判的规范空白与必测场景，代码注释里写的"audit question N""scenario N"指的就是它）

---

## 1. 一句话现状

第一阶段（主题回合）已经可以在 Roblox Studio 里从头到尾玩一轮：加入、选衣服、上台跳舞、看结果、拿到游戏币和粉丝。第二阶段也已写完：服务器部分（规则、通道、所有人看得到的大厅舞蹈和称号名牌）和手机端界面（大厅菜单、舞蹈、商店、每日奖励、兑换码、大厅造型、购买按钮）。计划里的五批代码全部完成并验收。全部代码由命令行单元测试覆盖，主目录四条命令通过。

游戏还**不能发布**：没有真实物品清单，没有建 Roblox 游戏，真实数据存储、购买、两名玩家同场都没有验证过（§7）。

## 2. 负责人定下的工作方式

这些是负责人明确说过的，接手后继续遵守：

- 🔴 **代码由 Opus 子代理写。** 主会话只做三件事：分配任务、监督进度、验收质量。主会话不亲自写代码。
- 文档（开发文档、本说明、任务板）由主会话维护。
- 代码和注释用英文。
- 提交和推送只在负责人明确要求时做。此前负责人说过可以直接推到 `main`。
- 负责人不是工程师出身。汇报用大白话，术语首次出现要解释，必须说明"没做什么、没验证什么"。
- 负责人希望尽量并行。能并行的任务每个子代理用自己的工作副本（git worktree，即同一仓库的一份独立拷贝）；负责人说"用 workflow"时才用多代理工作流。

## 3. 环境与提交状态

1. 工具：Git、Claude、Roblox Studio、Rokit。项目文件夹里运行 `rokit install` 会装好固定版本的 Rojo、Lune、StyLua、selene。新开的终端才认得这些命令；在 Claude 里跑命令前要先 `export PATH="$HOME/.rokit/bin:$PATH"`。
2. 四条命令，都应成功：

   | 用途 | 命令 | 预期 |
   |---|---|---|
   | 全部单元测试 | `lune run tests/RunAllTests.luau` | 最后一行 `N spec files, M tests: M passed, 0 failed, 0 spec file problems`（当前数字见 §8） |
   | 代码检查 | `selene src tests tools` | 0 errors, 0 warnings, 0 parse errors |
   | 格式检查 | `stylua --check src tests tools` | 无输出 |
   | 构建 | `mkdir -p build && rojo build default.project.json -o build/idolgrow.rbxlx` | Built project |

3. Studio 连接已可用（Studio 里打开 Enable Studio as MCP server）。⚠️ 同一面板里的 Data access 开关不要为正式游戏打开；是否打开由负责人决定。
4. 推送：这台电脑登录的 GitHub 账号已有仓库的写权限（2026-11-20 起），计划内代码已全部推送到 `main`。提交和推送仍然只在负责人明确要求时做。
5. 子代理的工作副本都在 `.claude/worktrees/` 下，已写进 `.gitignore`，不会被提交。可以清理，但删除前先问负责人。

## 4. 已完成并验收的部分

| 批次 | 内容 | 主要文件 |
|---|---|---|
| 1、2A、2B（此前） | 骨架、标签与评分、存档与排行榜 | `src/shared/`、`src/server/PlayerSaveDataKeeper.luau` 等 |
| 3 回合规则 | 奖励账本、回合时钟、请求限流、物品查询规则、已存造型清理、草稿协议、回合裁判、重生外观判断 | `RewardLedger`、`ThemedRoundClock`、`PlayerRequestRateLimiter`、`MarketplaceStylingItemResolver`、`StoredLobbyOutfitKeeper`、`RoundOutfitDraftKeeper`、`ThemedRoundReferee`、`CharacterSpawnAppearanceDecider` |
| 5 的规则部分 | 装饰品清单、每日内容、兑换码、每日进度与领奖、兑换、商店与装备、大厅造型与大厅舞蹈、存档快照 | `CosmeticCatalog`、`DailyQuestCatalog` 等共享模块；`DailyProgressTracker`、`PromoCodeRedeemer`、`DanceAndCosmetic*`、`SetLobbyOutfitRequestAnswerer`、`LobbyDanceCoordinator`、`PlayerSaveDataSnapshotPublisher` |
| 跨模块修复 | 快速重进同一服务器时，新会话读档在存档管理模块内排队，等旧会话结束 | `PlayerSaveDataKeeper.luau` |
| 4 接入 Roblox（服务器） | 入口脚本、通道、存储选择（未发布场景用内存假存储）、请求路由、进出顺序、角色换装、舞台 | `ServerMain.server.luau`、`ServerGameModuleAssembly`、`PlayerDataStorageSelectionRule`、`DeviceRequestChannelAnswerRouter`、`PlayerCharacterDresser`、`RobloxCharacterShowcasePresenter` |
| 4 接入 Roblox（手机端，第一阶段） | 状态栏、回合面板、衣橱与预览、草稿发送、结果、排行榜 | `src/client/`（`ClientMain.client.luau`、`RoundOutfitDraftSender`、`ThemedRoundDeviceSession`、各 `*View`） |
| 5 的服务器展示 | 大厅舞蹈对齐节拍、头顶称号与名牌、登台特效（全部代码生成） | `CharacterPresentationStepPlanner`、`RobloxCharacterOverheadCosmeticDisplay`、`RobloxStageEntranceEffectPlayer`、`src/shared/*LookCatalog` |
| 5 的手机端界面 | 大厅菜单、舞蹈面板、商店、每日奖励、兑换码、大厅造型、购买按钮（在 Studio 里不可能弹出购买窗口） | `src/client/Lobby*`、`ShopPanel*`、`DailyRewardsPanel*`、`PromoCode*`、`StylingItemOwnershipRequester`、`MarketplacePurchasePromptPermission`、`RobloxMarketplacePurchasePromptOpener` |
| Studio 工具 | 不需要 Rojo 插件就能把项目装进 Studio | `tools/SyncProjectIntoStudio.luau`；README"Loading the project into Roblox Studio" |

**验收是怎么做的**（接手后每一批照此执行）：

1. 主会话亲自运行四条命令，不采信子代理的自述。
2. 主会话自己挑关键逻辑逐一改坏，确认测试会失败，再恢复。漏网的退回原子代理补测试。脚本和各批的改坏清单在会话草稿区，不在仓库里；做法是"替换一段源码 → 跑全套测试 → 恢复并核对哈希"。
3. 能在 Studio 里看的，主会话亲自开试玩重复一部分检查，并用独立计算核对分数和奖励。
4. 检查硬约束：只有 `RobloxPlayerSaveDataStorage.luau` 和 `RobloxFanCountLeaderboardStorage.luau` 接触云存储；只有奖励账本改游戏币和粉丝（有扫描测试守着）；规则模块不直接调用 Roblox 接口。
5. 较大的模块在验收前先由 2 到 3 个独立审查者只读审查，再由 Opus 修改。

## 5. 在 Studio 里怎么跑

- 目录映射：`src/server` → `ServerScriptService.Server`，`src/client` → `StarterPlayerScripts.Client`，`src/shared` 在两边各放一份，都叫 `shared`。🔴 这是因为 Roblox 里 `../shared/X` 不能跨服务解析（开发文档 §10 v1.4）。共享模块必须无状态。
- 装载：`lune run tools/SyncProjectIntoStudio.luau` 生成一组批处理文件，逐个原样粘进 Studio 的 `execute_luau`。改动后用 `--studio-manifest` 只同步有变化的脚本。细节在 README。
- 🔴 模块能否加载要在试玩里检查，不要在编辑模式里检查：编辑模式会把一次失败的加载记住整个会话。
- 这个未发布的场景里，服务器自动改用内存假存储，启动时打印一条醒目警告"什么都不会保存"。判断条件是"在 Studio 里，且场景、游戏、版本编号全是 0"，任何一项不满足都用真实数据存储。
- 手机端把自己的状态写成界面根节点上的属性，方便检查；按键 J 加入、L 排行榜、1 到 9 选衣橱物品。细节在 README"The device"。

## 6. 给子代理的任务说明应包含

- 必读：开发文档的具体章节、`README.md`、命名规则和编码原则两份实践文档、要依赖的模块的文件头注释。
- 明确它可以碰哪些文件、不可以碰哪些；不许改 `docs/` 和实践套件，不许执行任何 git 写操作，不许删除或移动已有文件。
- 🔴 工作副本是从最后一次提交切出来的，不含未提交的代码：任务说明第一步要给出把主目录 `src/`、`tests/`、`tools/`、`data/`、`docs/`、`README.md`、`default.project.json` 拷进去的确切命令。
- 不许凭记忆写 Roblox 接口名或素材编号，要查官方文档，并在 Studio 里核实引擎的实际行为。
- 文档有歧义或疑似有错时，按最保守的理解做，并在报告里列出，不许自己悄悄选。
- 固定例子之外要加随机数据测试，失败时打印种子。每个测试都要先见过它失败一次；文件头注释承诺的每个行为都要有会失败的测试。
- 交报告前四条命令必须在整个项目上通过。
- 用 Studio 的任务：写明硬限制（只用已打开的未保存场景；不发布、不保存到云端、不上传；不碰数据存储；不弹任何购买窗口；不需要负责人动手），并且同一时间只有一个子代理用 Studio。

## 7. 没验证过的

- 两个云存储读写文件从未在 Roblox 里运行。Studio 里用的是内存假存储。
- 离开后立刻重进余额不变、两名玩家互相可见并上排行榜（开发文档 §6.3 的 1E、1F）：单个未发布场景里做不了。
- 物品在已发布的游戏里是否显示为可售、购买能否完成、40% 分成是否到账（2F）。购买按钮在 Studio 里被设计成不能弹窗，购买路径从未执行过。
- 真手机上的布局和触控。
- 两名真实玩家的同步跳舞。单人场景里只验证了节拍计算和动画定位。
- 唇妆等妆容只在外观描述里确认过，没有在图像上确认。
- 截图工具时好时坏：第一阶段界面有截图证据；第二阶段的服务器展示和手机端界面都没有截图，只读过界面内容，**没有人看过第二阶段界面的实际排版**。
- 第二阶段手机端里，主会话亲自看过的只有：菜单、商店列表、每日奖励面板、一次不存在的兑换码、购买面板的提示。从面板跳舞、领奖、用攒的币买并装备装饰品、大厅造型生效并在回合后恢复，只有子代理的报告。
- 购买按钮打开 Roblox 购买窗口的那个函数**从未被执行过**（Studio 里被两道判断挡住）。官方文档没有写明这类窗口能否从手机端脚本打开，要在已发布的测试游戏里验证。

## 8. 当前数字与剩下的事

- 主目录最近一次四条命令（2026-11-20）：179 个测试文件、2343 个测试，全部通过；代码检查、格式检查、构建通过。源文件：服务器 76 个、共享 26 个、手机端 52 个。
- 计划内的代码已全部写完并合入主目录。Studio 场景里装的是最后一批子代理的版本，与主目录只差一个不影响行为的可选参数；下次同步会对齐。
- 接下来的工作不再是写新功能，而是：负责人的决定和内容（§10），在已发布的测试游戏里验证 §7 列的项目，以及下面的待修。
- 开发文档 §10 v1.4 列了 12 项"按默认值实现、等负责人拍板"的事，以及已知弱点。
- 已知待修（都不阻塞试玩）：
  - 最后一次存档写成功但应答丢失时，会被误判为锁丢失并把玩家请出游戏（进度没丢）。
  - `PlayerSaveDataKeeper.luau`（1084 行）和 `tools/StylingItemPoolCsvCompiler.luau`（569 行）超过 500 行上限，需要单独做一次只拆分、不改行为的重构。
  - `src/server/CharacterOutfitAppearancePlanner.luau` 现在只是一行转发（规则已搬到 `src/shared`）；是否删除要负责人同意。
  - 大厅舞蹈只在开始时对齐节拍，跳几分钟后会有几十毫秒漂移。
  - 服务器没有消息告诉手机端"谁在大厅跳舞"，规范里也没有这个通道；手机端靠读取其他角色正在播放的动画来判断。
  - 没有"卸下"装饰品的通道，所以界面上没有卸下按钮，只能换成另一件。
  - 手机端为了在截图和输入工具失灵时也能做 Studio 检查，给每个按钮加了一个只在 Studio 里生效的入口：改按钮上的 `PlaytestActivationRequestCount` 属性等于点一下。Studio 之外不会接通。

## 9. 踩过的坑

- **测试工具会卡死。** 一个模块加载失败后，如果两个测试文件都加载它，Lune 0.11.1 会永远等下去。测试入口会先检查语法；带超时运行时要用独立进程组并整组终止。
- **禁止子代理用 `pkill` 这类按名字杀进程的命令。** 它会误杀别的子代理的测试。
- **不要让两个子代理同时在同一个文件夹里做"改坏代码"的检查。** 每个子代理用自己的工作副本。
- **会话草稿区是所有子代理共用的。** 有子代理的脚本被别人同名覆盖过。让每个子代理在草稿区里用自己名字的子文件夹。
- **主会话不要 `cd` 进子代理的工作副本。** 用绝对路径看；否则之后的命令会在错误的文件夹里执行。
- **工作副本缺未提交的代码。** 见 §6 的拷贝步骤。合并回主目录时，只拷贝该子代理新建或声明改过的文件，不要整目录覆盖，否则会把主目录里更新的文件盖回旧版。
- **Roblox 的相对引用不能跨服务。** 见 §5。
- **限量物品会显示"可购买"，但标价不是成交价。** 现在限量物品一律隐藏。
- **Roblox 拒收 Lune 压缩出的数据帧**，因为帧头没有内容长度；同步工具已补上。
- **电脑睡眠会打断长时间试玩。** 回合时钟会记录"阶段开始得太晚、已重新计时"的警告，这是预期行为。

## 10. 只有负责人能做的事

见开发文档 §9。目前最影响进度的：

1. （已完成，2026-11-20）GitHub 写权限已有，计划内代码已提交并推送。
2. 挑选并标注商城物品，第一阶段要 30 件，填进 `data/styling-item-pool.csv`，替换掉现在的 7 件开发样本。只选在售、允许在所有游戏出售、非限量的；鞋必须是套装。
3. 在 Roblox 上建测试用和正式用两个游戏，只给测试用的开启 Studio 数据存储访问，并在两个游戏里都打开"允许第三方销售"。之后才能验证真实存储、重进、双人、购买。
4. 对开发文档 §10 v1.4 的 12 项默认做法逐条表态。
5. 审阅草稿内容：30 个主题、47 件装饰品的名字和价格、12 个每日任务；定兑换码和有效期（清单现在是空的）。
6. 决定发布档位（开发文档 §0.3 第 18 项）。

## 11. 没有进仓库的东西

- 之前会话的对话记录。本说明和开发文档是它的替代。
- 各子代理的工作副本（`.claude/worktrees/`）和会话草稿区里的验收脚本、改坏清单。
- Studio 试玩的原始输出和截图。结论已写进开发文档 §8 和 §10。
- 这台电脑没有安装全局的实践知识库（`~/.claude/practices/`）；项目里的 `claude-code-transferable-practices 2/` 带有安装说明。本次会话直接读的是项目里的那份。
