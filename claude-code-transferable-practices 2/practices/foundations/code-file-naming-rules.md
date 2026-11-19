---
title: "Code and File Naming Rules"
status: adopted
kind: preference
basis: preference
scope: cross-stack
stacks: []
versions: []
tags:
  - naming
  - domain-language
  - pipelines
  - database-schema
source-projects: []
created: 2026-07-11
updated: 2026-07-11
last-verified: null
supersedes: []
migration-source: "~/.config/hao-dev/Code-File-Naming-Rules.md"
---

# Code and File Naming Rules

请基于我偏好的命名风格，对本次新增功能涉及到的所有命名做一次系统检查和必要修复。

检查范围包括：

* 文件名、目录名、组件名、类名、函数名、变量名、参数名、类型名、接口名
* API 路由、请求字段、响应字段、DTO、schema、validation rule
* 数据库字段、migration、model、relationship、enum、常量
* job、queue、command、service、controller、action、hook、store、event handler
* 测试文件、测试用例名、mock 数据字段名

核心目标：

所有命名都要足够 self-explanatory。即使单独看到一个字段名、参数名、函数名或文件名，也应该能大致判断它代表什么业务含义、来自哪里、用于什么场景，而不需要翻文档或上下文猜测。

我不介意多个单词组成的长命名。优先“清晰”，然后才考虑“简短”。

命名原则：

* 优先使用业务语义命名，而不是技术实现命名。
* 名称要能直接表达“这个东西是什么”，而不是只表达“它属于什么类型”。
* 不要使用过度泛化的名称，例如 `job_id`、`data`、`item`、`info`、`value`、`result`、`payload`、`config`、`handler`、`manager`、`helper`，除非上下文已经非常明确。
* 外部系统、第三方 API、异步任务、生成流程相关字段，必须在名称里体现来源或用途。

  * 不要叫 `job_id`，如果它是外部 AI 生成任务 ID，应叫 `ai_reply_generation_job_id`、`cloudconvert_conversion_job_id` 或更符合当前业务上下文的名称。
  * 不要叫 `image_url`，如果它实际是 Etsy 商品图片，应叫 `etsy_listing_image_url`。
  * 不要叫 `status`，如果它是外部生成任务状态，应叫 `ai_reply_generation_status`、`cloudconvert_conversion_status` 或更符合当前业务上下文的名称。
  * 不要叫 `size`，如果是上传文件大小，应叫 `uploaded_file_size_bytes`。
  * 不要叫 `data`，如果是 Etsy 商品原始数据，应叫 `etsy_listing_raw_data`。
  * 不要叫 `processImage()`，如果它实际生成商品缩略图，应叫 `generateListingThumbnailImage()`。
* 同一个业务概念在前端、后端、数据库、API、测试中必须使用同一套词汇，不要混用近义词。
* 参数名不能只照搬类型名，也不要使用过短缩写；参数应该表达调用方传入的真实业务含义。
* 布尔值使用 `is`、`has`、`can`、`should`、`requires` 等前缀。
* 集合名使用复数，单个实体使用单数。
* 函数名使用明确动作，例如 `createThumbnailGenerationJob`、`syncEtsyListingImages`、`persistGeneratedPhoto`。
* 文件名、类名、函数名、字段名要遵循项目现有风格，但如果现有新增代码命名不清晰，应直接修正。
* 不要为了“优雅”而缩短命名；如果多几个词能减少理解成本，就使用多词命名。
* 不要为了重构而改动成熟且清晰的旧代码；重点处理本次新增功能相关命名，以及和新增功能强相关、会造成混淆的现有命名。

Pipeline / Workflow 命名规则：

* 如果一个主函数实际上是在编排多个连续步骤，它必须被命名为一个明确的 pipeline、workflow 或 orchestration 函数。
* 主函数名必须表达完整业务目标，而不是只叫 `processXxx()`、`handleXxx()`、`runXxx()`。
* 如果项目语言和框架更适合使用 class，应优先使用独立的 pipeline class，例如 `CreateAIReplyDraftPipeline`。
* Pipeline 的入口方法可以叫 `run()`、`execute()` 或项目现有约定名称，但 class 名必须清楚表达完整业务目标。
* Pipeline 内部的每个步骤都必须有清晰的业务语义，不能只表达技术动作。
* 不要使用 `step1()`、`step2()`、`handleNext()` 这类只表达顺序、不表达业务含义的命名。
* 如果 pipeline 内部包含多个明确步骤，可以在 pipeline class 内部的私有 step wrapper 方法中使用步骤编号，例如 `runStep03PollAIReplyGenerationJobStatusSync()`。
* 步骤编号只用于 pipeline 内部调度层，不应污染可复用的 service、repository、client、utility 函数。
* 不要使用 `Step1of3`、`Step2of5` 这类包含总步骤数的命名，因为总步骤数很容易变化，会导致命名腐烂。
* 推荐使用两位数编号，例如 `Step01`、`Step02`、`Step03`，避免超过 9 个步骤后排序混乱。
* 每个 step 方法名仍然必须包含清晰业务语义，不能只叫 `runStep01()`、`handleStep02()`、`processStep03()`。
* 真正可复用的业务函数应保持纯业务命名，例如 `queryAIReplyGenerationJobStatusSync()`，不要因为它在某个 pipeline 中是第 3 步，就命名为 `queryAIReplyGenerationJobStatusStep03()`。
* 如果 pipeline 很复杂，应建立 step enum、step constants 或 step registry，用于日志、错误追踪、测试描述和调试输出。
* 日志中应同时记录 pipeline 名称、step 编号、step 业务名称、关键业务 ID 和外部 job ID。

推荐示例：

```php
final class CreateAIReplyDraftPipeline
{
    public function run(CreateAIReplyDraftPipelineInput $input): AIReplyDraft
    {
        $context = CreateAIReplyDraftPipelineContext::fromInput($input);

        $this->runStep01CreateEmptyAIReplyDraftRecord($context);

        $this->runStep02DispatchAIReplyGenerationJobAsync($context);

        $this->runStep03PollAIReplyGenerationJobStatusSync($context);

        $this->runStep04PersistGeneratedAIReplyDraftContent($context);

        return $this->runStep05PolishAIReplyDraftForCustomerReview($context);
    }

    private function runStep01CreateEmptyAIReplyDraftRecord(
        CreateAIReplyDraftPipelineContext $context
    ): void {
        $context->draftRecord = $this->aiReplyDraftRepository
            ->createEmptyAIReplyDraftRecord($context->customerMessage);
    }

    private function runStep02DispatchAIReplyGenerationJobAsync(
        CreateAIReplyDraftPipelineContext $context
    ): void {
        $context->aiReplyGenerationJobId = $this->aiReplyGenerationService
            ->dispatchAIReplyGenerationJobAsync($context->draftRecord);
    }

    private function runStep03PollAIReplyGenerationJobStatusSync(
        CreateAIReplyDraftPipelineContext $context
    ): void {
        $context->aiReplyGenerationStatus = $this->aiReplyGenerationService
            ->queryAIReplyGenerationJobStatusSync($context->aiReplyGenerationJobId);
    }

    private function runStep04PersistGeneratedAIReplyDraftContent(
        CreateAIReplyDraftPipelineContext $context
    ): void {
        $context->generatedAIReplyDraftContent = $this->aiReplyDraftRepository
            ->persistGeneratedAIReplyDraftContent(
                $context->draftRecord,
                $context->aiReplyGenerationJobId
            );
    }

    private function runStep05PolishAIReplyDraftForCustomerReview(
        CreateAIReplyDraftPipelineContext $context
    ): AIReplyDraft {
        return $this->aiReplyPolishingService
            ->polishAIReplyDraftForCustomerReview($context->generatedAIReplyDraftContent);
    }
}
```

不推荐示例：

```php
function processDraft()
{
    handleJob();
    checkStatus();
    processResult();
}
```

不推荐示例：

```php
function createAIReplyDraftPipeline()
{
    initializeEmptyDraftRecord();
    generateAIReply();
    checkStatus();
    saveResult();
    polishResult();
}
```

更好的命名方式：

```php
final class CreateAIReplyDraftPipeline
{
    public function run(CreateAIReplyDraftPipelineInput $input): AIReplyDraft
    {
        $context = CreateAIReplyDraftPipelineContext::fromInput($input);

        $this->runStep01CreateEmptyAIReplyDraftRecord($context);
        $this->runStep02DispatchAIReplyGenerationJobAsync($context);
        $this->runStep03PollAIReplyGenerationJobStatusSync($context);
        $this->runStep04PersistGeneratedAIReplyDraftContent($context);

        return $this->runStep05PolishAIReplyDraftForCustomerReview($context);
    }
}
```


异步和同步命名规则：

* 如果一个函数会启动异步任务、投递队列、调用外部异步 API、返回 job id、task id、operation id，命名里必须体现 async 模式。
* 如果一个函数是同步执行，并且调用方容易和异步流程混淆，命名里应明确体现 sync 模式。
* 如果项目已有更清晰的约定，例如 `dispatchXxxJob()` 天然表示异步，也可以遵循项目风格，但必须保证调用方不会误解执行模式。
* 对外部异步 API，函数名必须体现“发起任务”和“查询状态”是两个不同动作。
* 不要把异步任务命名成看起来像已经完成业务结果的函数。
* 如果函数只是投递任务，不要叫 `generateXxx()`，应叫 `dispatchXxxGenerationJobAsync()`。
* 如果函数会阻塞等待结果，应在名称中体现 sync 或 wait，例如 `waitForAIReplyGenerationResultSync()`。
* 如果函数只是查询一次状态，不应命名为 `waitForXxx()`，应叫 `queryXxxStatusSync()` 或 `fetchXxxStatusSync()`。

推荐示例：

```php
$aiReplyGenerationJobId = dispatchAIReplyGenerationJobAsync($aiReplyDraftRequest);

$aiReplyGenerationStatus = queryAIReplyGenerationJobStatusSync($aiReplyGenerationJobId);

$generatedAIReplyDraftContent = fetchAIReplyGenerationResultSync($aiReplyGenerationJobId);
```

不推荐示例：

```php
$jobId = sendJob($data);

$status = getStatus($jobId);

$result = getResult($jobId);
```

更好的命名方式：

```php
$aiReplyGenerationJobId = dispatchAIReplyGenerationJobAsync($aiReplyDraftRequest);

$aiReplyGenerationStatus = queryAIReplyGenerationJobStatusSync($aiReplyGenerationJobId);

$generatedAIReplyDraftContent = fetchAIReplyGenerationResultSync($aiReplyGenerationJobId);
```

数据库和 migration 规则：

* 如果本次功能还没有发布，或者 migration 还没有被生产环境使用，字段改名应直接修改现有 migration file，不要新增 migration。
* 如果 migration 已经发布或可能被生产数据库使用，先说明风险，并询问是否要通过新的 migration rename 字段。
* 修改数据库字段时，必须同步更新 model、factory、seeder、DTO、API、测试、文档和所有引用。
* 字段名应尽量做到脱离表名也能看懂含义。例如 `cloudconvert_job_id` 比 `job_id` 更好。
* 对异步任务相关字段，数据库字段名必须体现任务来源、任务类型和字段含义。

  * 使用 `ai_reply_generation_job_id`，不要使用 `job_id`。
  * 使用 `ai_reply_generation_status`，不要使用 `status`。
  * 使用 `ai_reply_generation_completed_at`，不要使用 `completed_at`，除非所在表只服务于这个单一业务流程且不会造成歧义。
* 对外部系统返回的原始数据字段，应在字段名中体现来源和 raw 含义，例如 `etsy_listing_raw_data`、`cloudconvert_webhook_raw_payload`。
* 对金额、尺寸、时长、文件大小等字段，必须在字段名中体现单位，例如 `uploaded_file_size_bytes`、`processing_duration_seconds`、`price_amount_cents`。
* **系统 / 基础设施表统一加 `system_` 前缀**，与业务实体表区分。

  * 判据：由系统进程（后台任务 / 框架 / 运维工具）自动维护、不是业务领域实体的表——如删除恢复日志、任务运行记录、feature flag、内部审计——用 `system_` 前缀。例：`system_deleted_records`、`system_job_runs`、`system_feature_flags`。
  * `system_` 描述表的**性质 / 层级**（系统维护的基础设施），**不是访问权限**。访问控制属于授权层，不要用表名编码「谁能访问」——哪天某侧功能也要读它，名字就在说谎。
  * **不要用已被占用的领域前缀当通用标记**。例如某项目 `agent_` 已表示「agent 实体域」（`agents` / `agent_sessions` / `agent_audit_logs` = 关于 agent 的数据），不可再拿它标记「员工专用」，否则 `agent_deleted_records` 会被误读成「删除的 agent」。
  * **不要用 `dev_`**：它读作「开发 / 非生产 / 临时」，会让人以为可随手 drop。缩写 `sys_` 也不用（别为简短牺牲清晰），用全称 `system_`。

执行方式：

1. 先阅读本次新增功能相关代码，理解业务流程、异步边界、pipeline 结构和项目已有命名风格。
2. 建立一份核心业务概念词汇表，确保同一概念全链路命名一致。
3. 识别所有 pipeline、workflow、异步任务、外部 API 调用、状态查询、结果持久化相关代码，检查命名是否准确体现执行模式和业务阶段。
4. 找出所有不清晰、不一致、过度泛化、缩写不当、语义偏差的命名。
5. 直接修改代码中的命名，并同步更新所有引用。
6. 不改变业务行为。
7. 修改后运行相关类型检查、lint、测试，或至少做静态验证。
8. 最后简短总结：

   * 改了哪些命名
   * 为什么这样改
   * 是否有无法安全修改的命名
   * 是否涉及 migration 直接修改或需要新增 migration 的判断
   * 是否发现 pipeline 或 async/sync 命名边界仍然不清晰的地方

最终判断标准：

* 看到任意字段名，应该能判断它代表什么业务数据。
* 看到任意函数名，应该能判断它执行什么业务动作。
* 看到任意 async 函数，应该能判断它只是发起任务，而不是已经完成结果。
* 看到任意 sync 函数，应该能判断它是同步查询、同步等待，还是同步持久化。
* 看到任意 pipeline step，应该能判断它属于哪个 pipeline 的第几个步骤，以及这个步骤的业务目的。
* 新增命名应该让代码更像业务流程说明书，而不是让后来的维护者靠猜、靠搜、靠问、靠玄学。

---

## 数据库表命名补充规则（源自 2026-07 一次真实讨论）

### 表名结构

* 同一业务域 / 同类型的表必须使用**统一前缀**分组，让它们在 schema 列表里排在一起。例如预约域的表统一 `booking_` 前缀。
* 表名必须以**名词（复数）结尾**，不要以形容词 / 过去分词结尾。
  * ✅ `booking_occupied_slots`（结尾名词 `slots`）
  * ❌ `booking_slots_occupied`（结尾是过去分词 `occupied`）
* 结构模式：`<域前缀>_<修饰词>_<复数名词>`，例如 `booking_occupied_slots`、`booking_blocked_slots`。
* 不设"必须 N 个词"的硬限制；核心概念尽量精炼，但"清晰 > 简短"始终优先。

### 前缀分组 vs Laravel / ORM 约定

* 当"统一前缀分组"与框架的"模型名末词复数化 = 表名"约定冲突时，**优先保留前缀分组**，在模型里显式写 `protected $table` 覆盖即可（本项目模型本就普遍显式设 `$table`）。
  * 例：表 `booking_occupied_slots`，模型仍叫 `OccupiedSlot`（不叫 `BookingOccupiedSlot`），显式 `$table='booking_occupied_slots'`，关系方法 `occupiedSlots()`。

### 业务域词汇：自解释英文 vs 现有内部 / 拼音代号

* 现有代码若用**拼音 / 内部代号**指代某业务域（如某项目把预约引擎叫成拼音代号 `abc`：`AbcSche` / `AbcFlow` / `models/abc`），新表、新命名**优先用自解释的英文业务词**（如 `booking_`），而不是沿用不自解释的拼音代号——可读性 / 自解释优先。
* 这与"同概念全链路同词汇"存在张力：既有词汇尽量沿用，但当既有词汇本身不自解释时，新命名以自解释为准，并逐步把新词汇确立为该概念的标准词。

### 近义词碰撞

* 为不同但相邻的概念取名时，避免使用会和已有概念**混淆的近义词**。
  * 例：人工占位表**不叫** `booking_reservations`，因为 `reservation` 会和"真实预约(booking)"混；改用 `booking_blocked_slots`（占位）。

### 真相源表 vs 派生投影表（读模型）

* 当一张表是**真相源**（唯一权威数据、无法从别处重建）、另一张是**派生投影 / 读模型**（可从源头随时重建）时，命名可保持平行，但要靠**列名清晰区分**各自承载的量与来源。
  * 例：`booking_blocked_slots`（真相源，员工手工占位）与 `booking_occupied_slots`（读模型，占用投影）；投影表用 `booked_session_count`（真单投影）+ `blocked_session_count`（占位投影）两列显式各自来源。
* 命名不得让"派生投影"看起来像"真相源"，以免维护者误当权威数据去写。

### 字段命名（延续既有规则，本次补充单位 / 来源实例）

* 计数 / 数量必须带业务单元：`blocked_session_count`（占用的"场次"数），不叫 `weight` / `count` / `num`。
* 来源 / 角色显式化：`blocked_by_staff_user_id`（谁占的、是员工 user id），不叫 `created_by` / `user_id`。
* 时间语义化：当某时间点有特定业务含义时，用 `blocked_at`（何时占位），不叫泛化的 `created_at`。

### 本次真实案例（决策轨迹，供以后类似取舍复用）

* 需求：把"假订单"（塞进 `orders` 表、`order_plan=999` 用于占档期、阻止客户预约的行）拆成独立表。
* 迭代轨迹：`availability_blocks`（太泛）→ `staff_blocked_booking_slots`（太长）→ 加 `booking_` 前缀 + 2 词 `booking_blockouts` / `booking_occupancy` → 想更直白改 occupied/blocked，但发现结尾是形容词 → 翻转为名词结尾 `occupied_slots` / `blocked_slots` → 为同域分组再加统一前缀 → **最终定案**：
  * `booking_occupied_slots` — 读模型 / 占用投影，模型 `OccupiedSlot`，关系 `occupiedSlots()`
  * `booking_blocked_slots` — 真相源 / 员工手工占位，模型 `BlockedSlot`，关系 `blockedSlots()`
* 提炼出的通用偏好：**统一域前缀分组 + 名词（复数）结尾 + 前缀优先于 ORM 约定（显式 `$table`）+ 自解释英文优先于拼音代号 + 避免近义词碰撞 + 真相源与派生投影靠列名区分**。
