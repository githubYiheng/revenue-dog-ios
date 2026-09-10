# Changelog

语义化版本。公开 API 基线（`api-baseline/RevenueDog.public-api.txt`）有「减」或「改」= 主版本；只「增」= 次版本；无差异 = 修订号。
破坏性变更必须在对应条目里写迁移说明。tag 一经发布不可移动。

## [Unreleased]

**次版本 0.2.0：公开 API 只「增」不「减」不「改」**（基线 377 → 442 个符号：诊断切片 +1，本次 +64，diff 全是 `+` 行）。
**破坏性变更：无。** 门禁：194 单测 + 23 StoreKitTest 场景（iOS 18.5）全绿，iOS 交叉编译零告警。

### 新增

- **`Package.storeProduct` 不再恒 nil**：`offerings()` 拿到后端 offerings 后，用 StoreKit 2
  `Product.products(for:)` **一次批量**取回全部 `platform_product_identifier` 对应的商品，
  填进 `Package.storeProduct`；命中本地缓存的 offerings 也在**读取时**补齐
  （缓存里只存后端下发的那份，不冻价格）。商店查不到的商品 `storeProduct` 仍为 `nil`，
  并照旧记进诊断事件 `offerings_fetch.not_found_product_ids`（与补商品共用同一次商店查询）。
- **`StoreProduct` 补齐做定价文案要用的字段**：`subscriptionPeriod`（`SubscriptionPeriod`：
  `unit` + `value`，unit 是 struct + static 常量，不是 enum）、`introductoryOffer`
  （`IntroductoryOffer`：`type ∈ freeTrial / payAsYouGo / payUpFront / unknown`、`period`、
  `periodCount`、`displayPrice`、`isEligible`；资格走 `Product.SubscriptionInfo.isEligibleForIntroOffer`，
  `periodCount` 是 `Product.SubscriptionOffer.periodCount` 原样带出 —— `payAsYouGo` 靠它才写得出
  「$1.99/月 × 3 个月」，`freeTrial` / `payUpFront` 也如实带，不在端上归一化）、
  以及 StoreKit 2 命名的 `displayPrice`（与既有 `localizedPriceString` **同值**的计算属性别名）。
  新增一个带这两个新字段的 `init`，**旧 `init` 原样保留**。
  ⚠️ `isEligible` 是**订阅组级**且端上不可信的判定（坑 #91 / 裁决 #124）：只用于展示文案，
  计费与权益一律以服务端为准。
- **`PurchaseResult.isPending`**：Ask-to-Buy（家长同意）/ SCA（银行验证）时为 `true`，
  此刻 `transactionIdentifier == nil` 且 `userCancelled == false`。宿主**不要**在此发放权益，
  提示「等待批准」并监听 `customerInfoStream` 即可 —— 交易稍后从 `Transaction.updates` 流出，
  由 SDK 自动上报。新增带 `isPending` 的 `init`，旧 `init` 保留（默认 `false`）。
- **扣款之后上报失败的两个独立错误码**（此前两种后果共用一个裸 `.networkError`，宿主分不开）：
  - `PurchasesErrorCode.purchasePendingServerConfirmation`（901）：5xx / 网络错误 / 超时 /
    401 / 403 / 408 / 429。**交易未 finish、上下文已落盘**，SDK 会在前台恢复与下次冷启动自动重放。
    宿主提示「支付已收到，权益稍后到账」，**不要**引导用户再买一次。
  - `PurchasesErrorCode.purchaseRejectedByServer`（902）：确定性 4xx。**交易已 finish**，
    不会再有权益产生；`underlyingError` 是原始 `PurchasesError`，其 `backendCode` 带后端错误体码。
    宿主应走客服 / 退款路径，别静默吞掉。
  - `TransactionPoster` 的 finishable / retryable 划分**未变**，只是把结果映射到了新码位；
    诊断事件 `purchase_result.error_code` 随之记新码名。
- **`Configuration.with(transport:)` + 公开的 `HTTPTransport` / `HTTPTransportResponse`**：
  宿主可以在**自己的**集成测试里塞一个假后端，不连服务端跑完整条 SDK 链路。
  **仅测试用** —— 生产构建不要注入（不注入时 SDK 用内置的 `URLSession` 实现，带超时与缓存策略）。
  重试、退避、`Retry-After`、鉴权头、诊断头一律由 SDK 上层负责，实现方不要重复一遍。
- **客户端诊断事件管线**（ADR 0028，契约 `docs/plan/sdk-diagnostics.md`）。SDK 在 configure / 身份 / 购买 / 交易观察 / 收据上报 / finish 判定 / 恢复同步 / CustomerInfo 与 offerings 拉取 / HTTP 错误 / 运行时告警处记结构化事件，落本地 JSONL 队列（`<Application Support>/RevenueDog/diagnostics/`，上限 500 条 / 256 KB），攒批上报 `POST /v1/diagnostics/events`。**默认开启，宿主零接入**。不上传 token / JWS / 请求响应 body / 错误消息 / 日志文本；`http_error` 的 `path` 里 app_user_id 段替换为 `*`。
- **`Configuration.with(diagnosticsEnabled: Bool)`** —— 关掉后不记不发并清空本地队列。

### 修复

- **冷启动少发一次收据**（坑矩阵 #142）：带待重放上下文的冷启动过去要上报 **2 次** ——
  上下文重放先发一次（只有 JWS、没有交易对象 → 不能 finish），启动扫描把同一笔又发一次（这次才 finish）。
  现在重放前先看一眼 `Transaction.unfinished` **与** `Transaction.currentEntitlements` 两份快照，
  当下就看得见交易对象的上下文这一轮跳过重放、交给扫描路径（它一次上报就能把 finish 义务一起清掉），
  **同一 `transactionId` 只上报一次**（崩在 finish 之后的那种也覆盖）。
  去重用 `pendingPurchases` 现有的键，不引入新状态；两份快照里都看不见（P4 可见性滞后 / 交易已被清掉），
  或该交易在台账里已记（`currentEntitlements` 扫描本来就会跳过它）时，行为与从前完全一致。

### 破坏性

无。

### 其它行为变更

- **行为变更**：`install_id`（与本次安装同生命周期的随机标识）改为**首次 `configure` 就生成并持久化**，不再依赖宿主开启 AdServices 归因采集。影响：即使从不调 `enableAdServicesAttributionTokenCollection()`，`POST /v1/subscribers/identify` 也会带上 `install_id`。
- **行为变更**：`offerings()` 成功后会向 StoreKit 查一次商品（**每次 offerings 一次**，补 `storeProduct` 与算 `not_found_product_ids` 共用这一次）。best-effort：查不动就 `storeProduct` 留空、诊断字段省略，不影响 offerings 本身。
- **隐私清单**：`DeviceID` 与 `OtherDiagnosticData` 补 `NSPrivacyCollectedDataTypePurposeAnalytics`；未新增数据类型，未新增 Required Reason API 声明（逐条核实见 `docs/research/verify/privacy-manifest-diagnostics.md`）。
- **宿主须知**：App Store 隐私营养标签要宿主自己勾 User ID / Device ID / Diagnostics（linked，非 tracking）；`app_user_id` 不得使用邮箱等个人信息。见 README「诊断事件」。

## [0.1.1] - 2026-09-10

修订号：公开 API 基线无差异（377 符号）。**bff 直切接线必须用本版本或更高**（v0.1.0 会在鉴权失败时错误 finish 交易）。

- **修复**：`POST /v1/receipts` 返回 401/403 时不再 finish 交易。鉴权失败发生在服务端留档之前，此前的行为会把用户已付款的交易从 StoreKit 与后端两侧同时抹掉（消耗型不可恢复）。现在保留上下文，密钥修正后由前台重放补报。
- **修复**：`Purchases.defaultBaseURL` 从 `https://api.revenuedog.com`（非本项目域名）改为 `https://api.revdog.org`。公开符号不变。

## [0.1.0] - 2026-09-08

首个 tag。**尚未在生产 App 上线**，仅供双 SDK 影子期接线与真机核验。

- StoreKit 2 购买闭环：单一处理通道、finish 三铁律（200 后才 finish；确定性 4xx 也 finish；消耗型未被服务端确认绝不 finish）。
- 身份：匿名 ID / `logIn` / `logOut`，`CustomerInfo` 四种 `FetchPolicy` 与缓存代失效。
- `restorePurchases` / `syncPurchases` 全链；冷启动扫描 `Transaction.unfinished` 补报（恰好一次）。
- 订阅者属性、AdServices 归因 token、`presented_offering_identifier` 归因上行。
- 运行时权威开关、购买结果钩子、权益 diff 上报（双 SDK 共存期用）。
- 网络层：端点级重试策略、`Retry-After` 优先、故障注入测试 4 组。
- 隐私清单 `PrivacyInfo.xcprivacy`（`NSPrivacyTracking = false`，Required Reason API 仅 `CA92.1`）。
- 公开 API 基线冻结：377 个公开符号；146 单测 + 21 StoreKitTest 场景（iOS 18.5）。
